import Foundation

// The kitchen timer, as a plugin. On by default: a kitchen assistant that
// can't set a timer is missing the thing people actually walk over and ask
// for. It is a plugin anyway because "on by default" and "not optional" are
// different claims, and somebody running Neon on a desk rather than a counter
// should be able to switch it off.
//
// The mechanism is all in KitchenTimer.swift — one timer, it rings itself, and
// Neon is not in the loop when it goes off (docs/tasks.md explains why). This
// file is only the surface the model sees.
final class TimerPlugin: NeonPlugin {
    static let shared = TimerPlugin()
    private init() {}

    let id = "timer"
    let title = "Kitchen timer"
    let blurb = "Set, check and stop one timer. It rings on screen by itself."
    let defaultEnabled = true

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "set_timer",
                description: """
                    Set the kitchen timer. There is only one, so this replaces any \
                    timer already running. It rings by itself on screen when it's \
                    up — you are not involved and shouldn't promise to tell them; \
                    just confirm it briefly ("five minutes, going"). Only pass a \
                    label if they actually said what it's for ("pasta", "tea") — \
                    never invent one, and leave it out for a plain "set a timer \
                    for five minutes".
                    """,
                params: [
                    ToolParam("label", .string,
                              "Optional. Only what they said it's for — \"pasta\", \"tea\". Omit if they didn't say.",
                              required: false),
                    ToolParam("seconds", .number, "How long from now, in seconds"),
                ]),
            ToolSpec(
                name: "check_timer",
                description: "How much time is left on the kitchen timer, or whether it's ringing now."),
            ToolSpec(
                name: "stop_timer",
                description: """
                    Stop the kitchen timer — silences it if it's ringing, cancels \
                    it if it's still counting down. Call this whenever someone says \
                    to stop, cancel, or turn it off while it's going, even if they \
                    don't use the word "timer".
                    """),
        ]
    }

    let promptFragment = """
        There is one kitchen timer, and it rings by itself on screen — you are \
        not the alarm. Set it, check it, and stop it when asked. If someone says \
        "stop", "turn it off" or similar while it's ringing, that's what they \
        mean: call stop_timer first, then say something short.
        """

    func handle(tool: String, args: [String: Any], context: PluginContext,
                reply: @escaping PluginReply) {
        switch tool {
        case "set_timer":
            // No label is the normal case — the clock alone is the UI.
            let label = (args["label"] as? String) ?? ""
            let seconds = (args["seconds"] as? Double) ?? 60
            let replaced = KitchenTimer.shared.isActive
            KitchenTimer.shared.start(label: label, seconds: seconds)
            context.trace("timer", "set \"\(label)\" \(Int(seconds))s"
                + (replaced ? " (replaced the previous one)" : ""))
            reply(replaced
                  ? "Timer set, replacing the one that was running. It rings on its own."
                  : "Timer set. It rings on its own — you don't need to watch it.")

        case "check_timer":
            let status = KitchenTimer.shared.status()
            context.trace("timer", "check — \(status)")
            reply(status)

        case "stop_timer":
            let stopped = KitchenTimer.shared.stop()
            context.trace("timer", stopped ? "stopped" : "stop — nothing running")
            reply(stopped ? "Stopped." : "There's no timer running.")

        default:
            reply("Unknown timer tool.")
        }
    }
}
