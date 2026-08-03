import EventKit
import Foundation

// Read-only EventKit access to the calendars this Mac already syncs, which is
// where the family's real schedule lives — iCloud, not Google.
//
// EventKit rather than AppleScript. Both need the same TCC grant, but Apple
// Events would mean launching Calendar.app on a kiosk to answer a question,
// and iterating events through its scripting dictionary takes seconds to
// minutes where this takes milliseconds. Milliseconds is the whole point: a
// question asked out loud has to be answered in the same breath, which is
// exactly what the background-task version of this could never do.
//
// TCC attaches to the responsible process, not the command, so the usage
// description lives in build.sh's Info.plist heredoc (edit it there — the app's
// copy is regenerated on every build) and the stable signing identity matters:
// ad-hoc signing would reset the grant per build.
//
// There is deliberately no write path. Neon's boundaries say nothing leaves
// the house, and an absent capability is a stronger guarantee than an
// instruction not to use one.
enum CalendarBridge {

    /// Mirrors LocationProvider: true when a system dialog is about to appear
    /// and the kiosk needs to yield the screen, false once it is answered.
    static var onAwaitingPermission: (Bool) -> Void = { _ in }

    // MARK: - Permission

    static var permissionStatus: PluginPermission.Status {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .fullAccess, .authorized: return .granted
        case .writeOnly: return .denied   // no read access is no use to us
        default: return .denied
        }
    }

    /// The request has to be retained until its completion fires; a store that
    /// goes out of scope takes the pending prompt with it.
    private static var requestStore: EKEventStore?

    /// Raise the Calendars dialog. Asked from the settings panel, on a click,
    /// while somebody is standing at the machine — which is the only moment it
    /// can be answered. Asking lazily, the first time a tool wants the
    /// calendar, puts the prompt behind a fullscreen kiosk window that has
    /// disabled process switching and app hiding, so the system ends up waiting
    /// on a click nobody can deliver.
    ///
    /// macOS only raises a dialog from .notDetermined. After a denial this
    /// completes immediately with false and the caller shows the hint about
    /// System Settings, because there is no second chance to ask.
    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        let asking = permissionStatus == .notDetermined
        if asking { onAwaitingPermission(true) }

        let store = EKEventStore()
        requestStore = store
        let answered: (Bool, Error?) -> Void = { granted, _ in
            DispatchQueue.main.async {
                if asking { onAwaitingPermission(false) }
                requestStore = nil
                // A fresh grant is invisible to a store created before it.
                if granted { shared = EKEventStore() }
                done(granted)
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: answered)
        } else {
            store.requestAccess(to: .event, completion: answered)
        }
    }

    // MARK: - Reading

    /// One long-lived store. EventKit expects to be asked repeatedly through
    /// the same object; building one per query is the documented way to make
    /// queries slow.
    private static var shared = EKEventStore()

    struct Event {
        let title: String
        let start: Date?
        let end: Date?
        let allDay: Bool
        let location: String?
        let calendar: String
        let account: String
    }

    /// Events from the start of today through `days` days. `days == 1` is
    /// today alone.
    static func events(days: Int) -> [Event] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: max(1, days), to: start) ?? start
        return events(from: start, to: end)
    }

    static func events(from start: Date, to end: Date) -> [Event] {
        guard permissionStatus == .granted else { return [] }
        let predicate = shared.predicateForEvents(withStart: start, end: end, calendars: nil)
        return shared.events(matching: predicate)
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            .map {
                Event(title: $0.title ?? "(untitled)", start: $0.startDate, end: $0.endDate,
                      allDay: $0.isAllDay, location: $0.location?.isEmpty == false ? $0.location : nil,
                      calendar: $0.calendar?.title ?? "?",
                      account: $0.calendar?.source.title ?? "?")
            }
    }

    /// Title/location match over a window around today. EventKit has no text
    /// predicate for events (only for reminders), so this is a fetch and
    /// filter — fine over a year of a household's calendars, and the only way
    /// to answer "when is Alex's recital".
    static func search(_ query: String, back: Int = 30, ahead: Int = 365) -> [Event] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -back, to: today) ?? today
        let end = cal.date(byAdding: .day, value: ahead, to: today) ?? today
        let needle = trimmed.lowercased()
        return events(from: start, to: end).filter {
            $0.title.lowercased().contains(needle)
                || ($0.location?.lowercased().contains(needle) ?? false)
        }
    }

    /// Calendar names and which account each comes from, no event contents.
    static func calendarNames() -> [(account: String, title: String)] {
        guard permissionStatus == .granted else { return [] }
        return shared.calendars(for: .event)
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
            .map { (account: $0.source.title, title: $0.title) }
    }

    // MARK: - Rendering for speech

    /// Events grouped by day, in the shape someone would read them out. The
    /// consumer is a voice model, so this is plain lines rather than JSON:
    /// every token of punctuation it doesn't have to parse is a token it
    /// doesn't spend, and "9:00 AM Standup" is unambiguous where a timestamp
    /// invites being read aloud digit by digit.
    ///
    /// Local time, explicitly. The calendars disagree about their own zones —
    /// Family reads as UTC where the rest are Pacific — so formatting in
    /// whatever a calendar defaults to lands all-day events a day out.
    /// A location as you'd say it, not as the calendar stores it.
    ///
    /// Calendar entries routinely hold a venue and then a full postal address
    /// separated by a newline — "The Tennis Club\n1 Example Street, Anytown,
    /// OR 97000, United States". Printed whole it wrecks the one-line-per-event
    /// shape, and read aloud it is a street address nobody asked for. The first
    /// line is the venue, which is the entire useful part.
    private static func shortLocation(_ raw: String) -> String? {
        let first = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        let clean = first.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return nil }
        return clean.count > 60 ? String(clean.prefix(57)) + "…" : clean
    }

    /// `from` is the first day the question was about — today for
    /// `check_calendar`, the start of the search window for `search_calendar`.
    /// It is needed because a multi-day event comes back stamped with the day
    /// it *began*, which for something already under way is weeks in the past:
    /// "Sunday July 12 — houseguest in town" is a strange answer to "what's on
    /// today". Anything that started earlier is filed under the first day being
    /// asked about and described as ongoing rather than starting.
    static func spoken(_ events: [Event], from: Date = Date(),
                       emptyMessage: String) -> String {
        guard !events.isEmpty else { return emptyMessage }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let firstDay = cal.startOfDay(for: from)
        let dayName = DateFormatter()
        dayName.dateFormat = "EEEE MMMM d"
        dayName.timeZone = .current
        let clock = DateFormatter()
        clock.dateFormat = "h:mm a"
        clock.timeZone = .current

        var lines: [String] = []
        var lastDay: Date?
        for e in events {
            let started = cal.startOfDay(for: e.start ?? Date())
            let ongoing = started < firstDay
            let day = max(started, firstDay)
            if day != lastDay {
                lastDay = day
                let offset = cal.dateComponents([.day], from: today, to: day).day ?? 0
                let label = switch offset {
                case 0: "Today, \(dayName.string(from: day))"
                case 1: "Tomorrow, \(dayName.string(from: day))"
                case -1: "Yesterday, \(dayName.string(from: day))"
                default: dayName.string(from: day)
                }
                lines.append(lines.isEmpty ? label : "\n\(label)")
            }
            // An all-day event has no meaningful clock time, and printing one
            // invites it being read aloud as "at 5pm".
            var line = "  " + (ongoing ? "ongoing"
                               : e.allDay ? "all day"
                               : clock.string(from: e.start ?? Date()))
            line += "  \(e.title)"
            if let loc = e.location.flatMap(shortLocation) { line += " — \(loc)" }
            line += "  [\(e.calendar)]"
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Command-line entry points

    // Kept for testing and for anything outside the app that wants the same
    // view: NEON_CALENDAR_DAYS=7 prints a week as JSON, NEON_CALENDAR_LIST=1
    // prints the calendar names. These run the request inline because there is
    // no kiosk in the way when you invoke the binary from a terminal.

    private static func requireAccessOrExit() {
        guard permissionStatus != .granted else { return }
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        requestAccess { ok in granted = ok; sem.signal() }
        // First run raises a dialog. A command waiting forever on a prompt
        // nobody is standing in front of is worse than one that fails and says
        // so.
        while sem.wait(timeout: .now() + 0.1) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if Date().timeIntervalSince(commandStart) > 30 {
                FileHandle.standardError.write(Data(
                    "calendar: no response to the access request (a prompt may be waiting on screen)\n".utf8))
                exit(2)
            }
        }
        guard granted else {
            FileHandle.standardError.write(Data(
                "calendar: no access to Calendars. Grant Neon under System Settings > Privacy & Security > Calendars.\n".utf8))
            exit(1)
        }
    }

    private static let commandStart = Date()

    /// Prints the next `days` days of events as JSON on stdout and exits.
    /// Exit codes: 0 printed, 1 access denied, 2 no answer from TCC.
    static func dump(days: Int) -> Never {
        requireAccessOrExit()

        let stamp = ISO8601DateFormatter()
        stamp.timeZone = .current
        stamp.formatOptions = [.withInternetDateTime]
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = .current

        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: max(1, days), to: start) ?? start
        let rows = events(days: days).map { e -> [String: Any] in
            var row: [String: Any] = [
                "calendar": e.calendar, "account": e.account,
                "title": e.title, "allDay": e.allDay,
            ]
            if let s = e.start { row["start"] = e.allDay ? day.string(from: s) : stamp.string(from: s) }
            if let f = e.end { row["end"] = e.allDay ? day.string(from: f) : stamp.string(from: f) }
            if let loc = e.location { row["location"] = loc }
            return row
        }
        let payload: [String: Any] = [
            "from": day.string(from: start), "to": day.string(from: end),
            "timeZone": TimeZone.current.identifier,
            "count": rows.count, "events": rows,
        ]
        if let json = try? JSONSerialization.data(withJSONObject: payload,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(json)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        exit(0)
    }

    static func listCalendars() -> Never {
        requireAccessOrExit()
        for c in calendarNames() { print("\(c.account)\t\(c.title)") }
        exit(0)
    }
}
