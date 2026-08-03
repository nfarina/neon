import Foundation

// Handing work to Claude Code in the background. Off by default, and shelved
// as of 2026-08-03 for a reason worth writing down rather than rediscovering:
//
// It works, and it is still the wrong shape for a kitchen. Asked to check
// today's calendar, Neon starts the task and says so — and then there is a
// minute of nothing. She is asleep, the room is silent, whoever asked is stood
// there, and a full minute later she wakes up and answers a question everyone
// has stopped caring about. The latency isn't a bug to tune; a subprocess that
// boots a coding agent is simply not a conversational turn. Real-time answers
// have to come from tools that return in the same breath, which is what the
// calendar plugin is.
//
// The code stays because the async-work idea is still right for work that is
// genuinely long ("look into flights for October and tell me later"), and
// because it is the honest test of the plugin system: something enabled here
// that ships off. TaskStore, TaskRunner, the announce channel and the left-edge
// list are all still live — nothing reaches the model unless this is on.
//
// See docs/tasks.md for the runner, the agent's home, and the safety story
// (bash is enabled; the boundaries are trust, not enforcement). Read that
// before turning this on for anyone but yourself.
final class TasksPlugin: NeonPlugin {
    static let shared = TasksPlugin()
    private init() {}

    let id = "tasks"
    let title = "Background tasks (Claude Code)"
    let blurb = """
        Hands longer work to Claude Code and announces the result when it lands. \
        Slow — expect a minute or more of silence — and the agent it starts has \
        a shell with your own access. Off unless you know you want it.
        """
    let defaultEnabled = false

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "start_task",
                description: """
                    Hand work to Claude Code, which runs in the background while you \
                    carry on talking: research, comparisons, anything that takes \
                    longer than a sentence or needs the web. You'll be told when it \
                    finishes and can say so then. Give the full request in \
                    `instructions` — Claude can't ask you anything once it starts, so \
                    include everything it needs, including who it's for and any \
                    preference you know about. Don't use it for things you can just \
                    answer, and don't use it for anything someone is standing there \
                    waiting on — it takes minutes, not seconds.
                    """,
                params: [
                    ToolParam("title", .string,
                              "2-4 words for the screen — \"recipe ideas\", \"racket prices\""),
                    ToolParam("instructions", .string, "The complete request, self-contained"),
                ]),
            ToolSpec(
                name: "list_tasks",
                description: """
                    What background tasks are running, what each one is doing right \
                    now, and what any finished ones came back with.
                    """),
            ToolSpec(
                name: "check_task",
                description: "Detail on one task by id — its current activity, or its result if it's done.",
                params: [ToolParam("id", .string)]),
            ToolSpec(
                name: "cancel_task",
                description: "Stop a running background task by id.",
                params: [ToolParam("id", .string)]),
        ]
    }

    let promptFragment = """
        For work that genuinely takes minutes — research, comparisons, looking \
        several things up — hand it to Claude Code with start_task and carry on \
        talking; you'll be told when it lands. Never use it for something someone \
        is waiting on in the room: if you can't answer in this conversation, say \
        so. The family knows Claude is what's behind it, so "have Claude look \
        into that" is a normal thing for them to say and you can mention it \
        naturally. But when a result comes back, just say the answer — nobody \
        needs "Claude says". Whatever you pass as instructions is all it gets: it \
        can't ask you anything once it starts.
        """

    func handle(tool: String, args: [String: Any], context: PluginContext,
                reply: @escaping PluginReply) {
        switch tool {
        case "start_task":
            let title = (args["title"] as? String) ?? "task"
            let instructions = (args["instructions"] as? String) ?? ""
            switch TaskRunner.shared.start(title: title, instructions: instructions,
                                           requester: context.requester) {
            case .success(let task):
                context.trace("task", "\(task.id) started: \(title)")
                reply("Started as \(task.id). You'll be told when it's done — "
                      + "don't promise to watch it.")
            case .failure(let refusal):
                context.trace("task", "start refused: \(refusal.reason)")
                reply(refusal.reason)
            }

        case "list_tasks":
            context.trace("task", "list")
            reply(TaskStore.shared.summary())

        case "check_task":
            let taskID = (args["id"] as? String) ?? ""
            context.trace("task", "check \(taskID)")
            reply(TaskStore.shared.describe(id: taskID))

        case "cancel_task":
            let taskID = (args["id"] as? String) ?? ""
            TaskRunner.shared.cancel(id: taskID)
            let ok = TaskStore.shared.cancel(id: taskID)
            context.trace("task", "cancel \(taskID) — \(ok ? "cancelled" : "not running")")
            reply(ok ? "Stopped \(taskID)." : "Nothing running with id \(taskID).")

        default:
            reply("Unknown task tool.")
        }
    }
}
