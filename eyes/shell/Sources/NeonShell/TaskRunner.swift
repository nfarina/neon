import Foundation

// Neon's hands: `claude -p` in a project folder of its own.
//
// Not the Agent SDK — that is Node/Python only, so using it would mean a
// sidecar process and an IPC protocol to reach a subprocess Swift can spawn
// directly. `--output-format stream-json` gives the same events over stdout:
// init, tool_use as it happens, and a final result with cost and duration.
//
// The agent lives in ~/Code/neon-agent with a CLAUDE.md that tells it what it
// is (see agent/CLAUDE.md in this repo, which is copied there on first run).
// Each task gets tasks/<id>/ as its working directory, which also means the
// home CLAUDE.md is picked up automatically — Claude Code walks up from cwd.
// Knowledge accumulates in the home folder the ordinary way, across tasks.
final class TaskRunner {
    static let shared = TaskRunner()

    private var processes: [String: Process] = [:]

    static let home = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Code/neon-agent")

    /// No --model: whatever `claude` is configured to use wins, which is
    /// Opus 5. Tasks run against Nick's subscription rather than an API key,
    /// so the model choice is about capability, not cost. NEON_TASK_MODEL
    /// overrides for a deliberate experiment.
    private static var model: String? {
        ProcessInfo.processInfo.environment["NEON_TASK_MODEL"]
    }

    /// The full set, Bash included — Nick's call: don't constrain the agent.
    /// Note this means --add-dir no longer bounds what a task can reach; the
    /// boundaries in agent/CLAUDE.md are the real limit, and they are
    /// instructions rather than a sandbox. NEON_TASK_BASH=0 removes it.
    private static var tools: [String] {
        var t = ["Read", "Write", "Edit", "Glob", "Grep", "WebSearch", "WebFetch", "TodoWrite"]
        if ProcessInfo.processInfo.environment["NEON_TASK_BASH"] != "0" { t.append("Bash") }
        return t
    }

    /// True when an API key is in play; absent one, `claude` is authenticated
    /// against the Claude subscription in the Keychain.
    private static var billedToAPI: Bool {
        ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil
    }

    // MARK: - Starting

    /// Why a task couldn't start, phrased as something Neon can say aloud.
    struct Refusal: Error { let reason: String }

    /// Returns the task, or a sentence explaining why not (which Neon says).
    func start(title: String, instructions: String, requester: String?) -> Result<NeonTask, Refusal> {
        guard which("claude") != nil else {
            return .failure(Refusal(reason: "The claude command isn't on my PATH, so I can't start tasks."))
        }
        guard let task = TaskStore.shared.add(title: title) else {
            return .failure(Refusal(reason: "There are already \(TaskStore.maxActive) tasks running."))
        }
        seedHomeIfNeeded()
        let dir = Self.home.appendingPathComponent("tasks/\(task.id)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var prompt = instructions
        if let requester {
            prompt = "Requested by: \(requester).\n\n\(instructions)"
        }
        // The transcript is kept beside the scratch files: when a task comes
        // back wrong, the stream is the only record of why.
        let logURL = dir.appendingPathComponent("stream.jsonl")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.currentDirectoryURL = dir
        var args = ["-p", prompt,
                    "--output-format", "stream-json", "--verbose",
                    "--add-dir", Self.home.path,
                    // cwd is tasks/<id>/, and settings discovery does not walk
                    // up the way CLAUDE.md discovery does — so the agent home's
                    // permission rules have to be named outright. Without this
                    // every connector call (calendar, mail, drive) comes back
                    // "you haven't granted it yet" and the task quietly fails.
                    "--settings", Self.home.appendingPathComponent(".claude/settings.json").path,
                    "--allowedTools"] + Self.tools
                 + ["--permission-mode", "acceptEdits", "--max-turns", "40"]
        if let model = Self.model { args += ["--model", model] }
        // Through a login shell so PATH matches Nick's terminal; claude is
        // installed per-user, not in /usr/bin.
        process.arguments = ["-lc", (["claude"] + args).map(shellQuote).joined(separator: " ")]

        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        // Without this, claude waits 3 s for stdin before every run.
        process.standardInput = FileHandle.nullDevice

        var buffer = Data()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            try? log?.write(contentsOf: chunk)
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                self?.handle(line: line, task: task.id)
            }
        }
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                try? log?.close()
                self?.processes[task.id] = nil
                // A result event already finished it in the normal case; this
                // catches crashes, timeouts and non-zero exits.
                if TaskStore.shared.tasks.first(where: { $0.id == task.id })?.isActive == true {
                    TaskStore.shared.finish(id: task.id, status: .failed,
                                            detail: "stopped unexpectedly (exit \(proc.terminationStatus))")
                }
            }
        }

        do {
            try process.run()
            processes[task.id] = process
            TaskStore.shared.note(id: task.id, activity: "starting")
            return .success(task)
        } catch {
            TaskStore.shared.finish(id: task.id, status: .failed, detail: error.localizedDescription)
            return .failure(Refusal(reason: "I couldn't start that: \(error.localizedDescription)"))
        }
    }

    func cancel(id: String) {
        processes[id]?.terminate()
        processes[id] = nil
    }

    // MARK: - Stream

    private func handle(line: Data, task id: String) {
        guard !line.isEmpty,
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        else { return }
        switch obj["type"] as? String {
        case "assistant":
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            for part in content where part["type"] as? String == "tool_use" {
                let name = part["name"] as? String ?? "working"
                DispatchQueue.main.async {
                    TaskStore.shared.note(id: id, activity: Self.activity(for: name, part))
                }
            }
        case "result":
            let text = (obj["result"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let failed = (obj["subtype"] as? String) != "success" || (obj["is_error"] as? Bool == true)
            let cost = obj["total_cost_usd"] as? Double ?? 0
            DispatchQueue.main.async {
                TaskStore.shared.finish(
                    id: id, status: failed ? .failed : .done,
                    detail: text.isEmpty ? "finished with nothing to say" : text)
                UsageStore.shared.record(engine: Self.billedToAPI ? "claude-task"
                                                                  : "claude-task (plan)",
                                         cost: cost, billed: Self.billedToAPI)
            }
        case "rate_limit_event":
            // Subscription work can be throttled; a task that stalls here
            // otherwise looks like a hang with no explanation.
            let info = obj["rate_limit_info"] as? [String: Any]
            let status = info?["status"] as? String ?? "unknown"
            if status != "allowed" {
                DispatchQueue.main.async {
                    TaskStore.shared.note(id: id, activity: "waiting on rate limit (\(status))")
                }
            }
        default:
            break   // system init, tool results
        }
    }

    /// A human phrase for the task row — "searching the web" reads better on a
    /// kitchen display than "WebSearch".
    private static func activity(for tool: String, _ part: [String: Any]) -> String {
        switch tool {
        case "WebSearch": return "searching the web"
        case "WebFetch": return "reading a page"
        case "Read", "Glob", "Grep": return "reading files"
        case "Write", "Edit": return "writing notes"
        case "Bash": return "running a command"
        case "TodoWrite": return "planning"
        default: return tool.lowercased()
        }
    }

    // MARK: - Home

    /// Copies the seed CLAUDE.md out of the app bundle the first time. After
    /// that the agent owns it — it is told to keep the file current, and
    /// overwriting would delete what it learned.
    private func seedHomeIfNeeded() {
        let fm = FileManager.default
        let claudeMD = Self.home.appendingPathComponent("CLAUDE.md")
        try? fm.createDirectory(at: Self.home.appendingPathComponent("tasks"),
                                withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: claudeMD.path) else { return }
        guard let seed = Self.seedURL(),
              var text = try? String(contentsOf: seed, encoding: .utf8) else {
            dbg("taskrunner: no seed CLAUDE.md found")
            return
        }
        // The seed in the repo describes the job, not the family. Who actually
        // lives here comes from ~/.config/neon/profile.md — the same file the
        // voice session reads, and the same reason: household facts are not
        // source code, and this repo is public.
        let profilePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/neon/profile.md")
        if let profile = try? String(contentsOf: profilePath, encoding: .utf8),
           !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = text.replacingOccurrences(
                of: "## Who you're working for\n",
                with: "## Who you're working for\n\n\(profile)\n")
        }
        try? text.write(to: claudeMD, atomically: true, encoding: .utf8)
        dbg("taskrunner: seeded \(claudeMD.path)")
    }

    /// Bundle first, then a walk up from cwd — the offline harnesses run the
    /// bare binary out of .build, where Bundle.main is not the app. Without
    /// the fallback a test task runs with no instructions at all, which looks
    /// like success and isn't. (Same idiom as loadEyes().)
    private static func seedURL() -> URL? {
        if let url = Bundle.main.url(forResource: "agent-CLAUDE", withExtension: "md") {
            return url
        }
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<5 {
            let candidate = dir.appendingPathComponent("agent/CLAUDE.md")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    private func which(_ command: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v \(command)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
