import Foundation

// Neon's hands: deferred work she starts, watches, and reports back on.
//
// Two kinds of producer share one lifecycle and one announce channel:
//   - timers/reminders, which are a fire date and nothing more
//   - agent tasks (Claude Code in a sandbox), added next
//
// The split matters. "Set a timer for five minutes" through an agent would
// park a model process to watch a clock — expensive, unreliable, and gone on
// restart. A stored fire date costs nothing and survives relaunching.
//
// Completion is a *push*: onFinished fires and the shell decides how to say
// it out loud (see AppDelegate.announce). Nothing polls.

enum TaskKind: String, Codable {
    case timer
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
    var dueAt: Date?           // timers only
    var finishedAt: Date?
    var detail: String?        // what it's doing now, or the result when done
    /// Announced to the room yet? Survives restarts so a completion can't be
    /// lost to a crash — or repeated after one.
    var announced: Bool = false

    var isActive: Bool { status == .running }

    /// How the model should hear about this when it finishes.
    var completionNote: String {
        switch kind {
        case .timer:
            return "[Your timer \"\(title)\" just went off.]"
        case .agent:
            let outcome = status == .done ? "finished" : status.rawValue
            return "[Background task \"\(title)\" \(outcome). "
                + "Result: \(detail ?? "no output")]"
        }
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
    private var timers: [String: Timer] = [:]
    private let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/neon/tasks.json")
    private var nextNumber = 1

    private init() {
        load()
    }

    var active: [NeonTask] { tasks.filter(\.isActive) }

    // MARK: - Creating

    /// Returns the new task, or nil if we're at the cap.
    @discardableResult
    func addTimer(title: String, seconds: TimeInterval) -> NeonTask? {
        guard active.count < Self.maxActive else { return nil }
        let task = NeonTask(id: newID(), kind: .timer, title: title,
                            status: .running, createdAt: Date(),
                            dueAt: Date().addingTimeInterval(seconds))
        tasks.append(task)
        schedule(task)
        changed()
        return task
    }

    func cancel(id: String) -> Bool {
        guard let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].isActive
        else { return false }
        timers[id]?.invalidate()
        timers[id] = nil
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

    /// Drop finished tasks once they've been announced and had their moment on
    /// screen, so the list stays a picture of *now*.
    func prune() {
        let cutoff = Date().addingTimeInterval(-120)
        let before = tasks.count
        tasks.removeAll { t in
            !t.isActive && t.announced && (t.finishedAt ?? .distantPast) < cutoff
        }
        if tasks.count != before { changed() }
    }

    // MARK: - Describing (for the model)

    func summary() -> String {
        guard !tasks.isEmpty else { return "Nothing running." }
        return tasks.map { t in
            var line = "\(t.id): \(t.title) — \(t.status.rawValue)"
            if t.status == .running, let due = t.dueAt {
                let left = Int(due.timeIntervalSinceNow)
                line += left > 0 ? ", \(left / 60)m \(left % 60)s left" : ", due now"
            } else if let d = t.detail {
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

    // MARK: - Scheduling

    private func schedule(_ task: NeonTask) {
        guard let due = task.dueAt else { return }
        let id = task.id
        // A timer whose moment passed while the app was quit still deserves to
        // fire — someone is waiting on it — just immediately rather than late.
        let delay = max(0.1, due.timeIntervalSinceNow)
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.finish(id: id, status: .done, detail: nil)
        }
        timers[id] = timer
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
        // Re-arm anything that was still running when we last exited.
        for task in tasks where task.isActive {
            schedule(task)
        }
    }
}
