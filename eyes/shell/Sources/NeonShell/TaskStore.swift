import Foundation

// Neon's hands: background work she starts, watches, and reports back on —
// agent tasks (Claude Code in a sandbox), landing next.
//
// The kitchen timer deliberately does NOT live here; it is `KitchenTimer`.
// It was a task producer for exactly one kitchen test, which was enough:
// the timer fired, Neon woke up, and announced "quick check is done". A
// timer going off wants to be obvious in the room and easy to silence, not
// to start a conversation. Work that produces a *result* is what belongs
// here — the announce channel is worth a session when there's something to
// say.
//
// Completion is a *push*: onFinished fires and the shell decides how to say
// it out loud (see AppDelegate.announce). Nothing polls.

enum TaskKind: String, Codable {
    case agent
}

enum TaskStatus: String, Codable {
    case running, done, failed, cancelled
}

struct NeonTask: Codable, Identifiable {
    var id: String
    var kind: TaskKind
    var title: String          // 2-4 words; this is what the UI shows
    var status: TaskStatus
    var createdAt: Date
    var finishedAt: Date?
    var detail: String?        // what it's doing now, or the result when done
    /// Announced to the room yet? Survives restarts so a completion can't be
    /// lost to a crash — or repeated after one.
    var announced: Bool = false

    var isActive: Bool { status == .running }

    /// On screen: running, or finished recently enough that someone walking
    /// past still wants to see it. The store keeps results far longer than
    /// this — "what did that chips task say?" is a fair question an hour
    /// later, even though the left edge should be a picture of *now*.
    var onScreen: Bool {
        isActive || Date().timeIntervalSince(finishedAt ?? .distantPast) < 120
    }

    /// How the model should hear about this when it finishes.
    var completionNote: String {
        let outcome = status == .done ? "finished" : status.rawValue
        return "[Background task \"\(title)\" \(outcome). "
            + "Result: \(detail ?? "no output")]"
    }
}

final class TaskStore {
    static let shared = TaskStore()

    /// Fires when a task reaches a terminal state and wants announcing.
    var onFinished: (NeonTask) -> Void = { _ in }
    /// Fires whenever the list changes, for the UI.
    var onChanged: ([NeonTask]) -> Void = { _ in }

    /// Nick's cap. Deliberately low: five things running in a kitchen is
    /// already more than anyone can hold in their head.
    static let maxActive = 5

    private(set) var tasks: [NeonTask] = []
    private let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/neon/tasks.json")
    private var nextNumber = 1

    private init() {
        load()
    }

    var active: [NeonTask] { tasks.filter(\.isActive) }

    // MARK: - Creating

    /// Registers a task the agent runner is about to start. Returns nil if
    /// we're at the cap.
    @discardableResult
    func add(title: String) -> NeonTask? {
        guard active.count < Self.maxActive else { return nil }
        let task = NeonTask(id: newID(), kind: .agent, title: title,
                            status: .running, createdAt: Date())
        tasks.append(task)
        changed()
        return task
    }

    /// The live one-line "what is it doing right now", from the agent's
    /// streamed tool use.
    func note(id: String, activity: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].isActive
        else { return }
        tasks[i].detail = activity
        changed()
    }

    func cancel(id: String) -> Bool {
        guard let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].isActive
        else { return false }
        tasks[i].status = .cancelled
        tasks[i].finishedAt = Date()
        tasks[i].announced = true      // cancelling is not news; she just did it
        changed()
        return true
    }

    /// Marks a task finished and hands it to the announce channel.
    func finish(id: String, status: TaskStatus, detail: String?) {
        guard let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].isActive
        else { return }
        tasks[i].status = status
        tasks[i].finishedAt = Date()
        if let detail { tasks[i].detail = detail }
        let task = tasks[i]
        changed()
        onFinished(task)
    }

    func markAnnounced(id: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].announced = true
        save()
    }

    /// Forget finished work after a day. Screen lifetime is `onScreen`; this
    /// is only about the store growing without bound.
    ///
    /// It used to prune two minutes after announcement, which quietly deleted
    /// the result too — and required `announced`, so anything started outside
    /// a voice session (the test harness) was kept forever. Both halves were
    /// wrong in opposite directions.
    func prune() {
        let cutoff = Date().addingTimeInterval(-86_400)
        let before = tasks.count
        tasks.removeAll { t in
            !t.isActive && (t.finishedAt ?? .distantPast) < cutoff
        }
        if tasks.count != before { changed() }
    }

    // MARK: - Describing (for the model)

    func summary() -> String {
        guard !tasks.isEmpty else { return "Nothing running." }
        return tasks.map { t in
            var line = "\(t.id): \(t.title) — \(t.status.rawValue)"
            if let d = t.detail {
                line += " — \(d)"
            }
            return line
        }.joined(separator: "\n")
    }

    func describe(id: String) -> String {
        guard let t = tasks.first(where: { $0.id == id }) else {
            return "No task with id \(id)."
        }
        return summary().split(separator: "\n")
            .first { $0.hasPrefix("\(t.id):") }.map(String.init) ?? t.title
    }

    private func newID() -> String {
        defer { nextNumber += 1 }
        return "t\(nextNumber)"
    }

    // MARK: - Persistence

    private func changed() {
        save()
        onChanged(tasks)
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(tasks) else { return }
        try? data.write(to: path)
    }

    private func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: path),
              let stored = try? dec.decode([NeonTask].self, from: data) else { return }
        tasks = stored
        nextNumber = (tasks.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
        // Nothing survives a relaunch: an agent task is a child process and
        // died with us. Stamp finishedAt as well as the status — without it
        // the task looked infinitely old and was pruned before anyone could
        // see that it had been interrupted at all. Left announced, since
        // waking the room to report a task killed by a rebuild is noise.
        for i in tasks.indices where tasks[i].isActive {
            tasks[i].status = .failed
            tasks[i].detail = "interrupted by a restart"
            tasks[i].finishedAt = Date()
            tasks[i].announced = true
        }
    }
}
