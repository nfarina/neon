import Foundation

// The calendars this Mac already syncs, readable in the same breath as the
// question. This is the plugin the background-task experiment was really
// asking for: "what's on today" is a two-second question, and any answer that
// arrives a minute later is the wrong answer no matter how good it is.
//
// Read-only by construction — see CalendarBridge for why there is no write
// path at all rather than an instruction not to use one.
final class CalendarPlugin: NeonPlugin {
    static let shared = CalendarPlugin()
    private init() {}

    let id = "calendar"
    let title = "Calendar"
    let blurb = """
        Lets Neon read the calendars this Mac syncs, so she can answer what's on \
        today, what's coming up, and when something is. She can't change anything.
        """
    let defaultEnabled = false
    let permission: PluginPermission? = .calendar

    /// A fortnight is about where "what's coming up" stops being a question
    /// anyone wants read aloud, and the cap keeps a vague request from
    /// returning a year of school events.
    private let maxDays = 14

    /// Enough for "when is it", not so many that she reads out a list.
    private let maxHits = 12

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "check_calendar",
                description: """
                    Look at the household calendar. Use it for anything about the \
                    day or the week — what's on, whether someone is free, what's \
                    next, what time something starts. Answer from what comes back \
                    rather than guessing, and read it the way a person would ("Alex \
                    has tennis at four") instead of listing fields.
                    """,
                params: [
                    ToolParam("days", .number,
                              "How many days from today. 1 is today alone, 2 includes tomorrow, 7 is the week. Defaults to 1.",
                              required: false),
                ]),
            ToolSpec(
                name: "search_calendar",
                description: """
                    Find an event by name when you don't know which day it's on — \
                    "when's the recital", "did we book the dentist". Searches roughly \
                    a month back and a year ahead by title and location.
                    """,
                params: [
                    ToolParam("query", .string,
                              "A word or two you'd expect in the event's title — a name, a place"),
                ]),
        ]
    }

    let promptFragment = """
        You can read the household calendar with check_calendar and \
        search_calendar. It is the family's real schedule, so check it rather \
        than guessing whenever the answer depends on what's actually on — and \
        check it before saying someone is free. You can only read it: if \
        someone wants something added, moved or cancelled, say plainly that you \
        can't change the calendar yet.
        """

    func handle(tool: String, args: [String: Any], context: PluginContext,
                reply: @escaping PluginReply) {
        switch tool {
        case "check_calendar":
            // Gemini sends whole numbers as Double; OpenAI can send a string.
            let raw = (args["days"] as? Double)
                ?? (args["days"] as? Int).map(Double.init)
                ?? (args["days"] as? String).flatMap(Double.init)
                ?? 1
            let days = min(maxDays, max(1, Int(raw)))
            let events = CalendarBridge.events(days: days)
            context.trace("calendar", "\(days)d — \(events.count) event\(events.count == 1 ? "" : "s")")
            reply(CalendarBridge.spoken(
                events,
                emptyMessage: days == 1
                    ? "Nothing on the calendar today."
                    : "Nothing on the calendar for the next \(days) days."))


        case "search_calendar":
            let query = (args["query"] as? String) ?? ""
            let back = 30
            let hits = CalendarBridge.search(query, back: back)
            context.trace("calendar", "search \"\(query)\" — \(hits.count) hit\(hits.count == 1 ? "" : "s")")

            // "When's the recital" is a question about the future, but a
            // weekly fixture matches dozens of times and the recent past fills
            // the whole budget with lessons that already happened. So upcoming
            // events get the room first, and the past only fills what's left.
            let today = Calendar.current.startOfDay(for: Date())
            let (past, ahead) = hits.reduce(into: ([CalendarBridge.Event](),
                                                   [CalendarBridge.Event]())) {
                ($1.end ?? $1.start ?? .distantPast) < today ? $0.0.append($1) : $0.1.append($1)
            }
            let kept = (ahead.prefix(maxHits)
                        + past.suffix(max(0, maxHits - ahead.count)))
                .sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }

            // `from` is the search window's own start, not today: a hit from
            // last week should be dated last week, not called ongoing.
            var answer = CalendarBridge.spoken(
                kept,
                from: Calendar.current.date(byAdding: .day, value: -back, to: Date()) ?? Date(),
                emptyMessage: "Nothing on the calendar matching \"\(query)\".")
            // Never let a truncated list be read as the whole answer — "there
            // are three" when there are thirty-eight is worse than a rough
            // number.
            if hits.count > kept.count {
                answer += "\n\n(\(hits.count) matches in all; these are the nearest "
                    + "\(kept.count) — it looks like a repeating event.)"
            }
            reply(answer)

        default:
            reply("Unknown calendar tool.")
        }
    }
}
