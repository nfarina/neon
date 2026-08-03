import EventKit
import Foundation

// Read-only EventKit access to the calendars this Mac already syncs, which is
// where the family's real schedule lives — iCloud, not Google. The Google
// connector the task agent can reach shows a partial mirror (four calendars
// against iCloud's seven), so anything asked aloud about "our week" has to
// come from here or it will be quietly wrong.
//
// EventKit rather than AppleScript. Both need the same TCC grant, but Apple
// Events would mean launching Calendar.app on a kiosk to answer a question,
// and iterating events through its scripting dictionary takes seconds to
// minutes where this takes milliseconds.
//
// TCC attaches to the responsible process, not the command. Task runs are
// Neon -> zsh -> claude -> this binary, so the grant lands on Neon.app, which
// is why the usage description lives in build.sh's Info.plist heredoc (edit it
// there — the app's copy is regenerated on every build) and why the stable
// signing identity matters: ad-hoc signing would reset the grant per build.
//
// There is deliberately no write path. Neon's boundaries say nothing leaves
// the house, and an absent capability is a stronger guarantee than an
// instruction not to use one.
enum CalendarBridge {

    /// Mirrors LocationProvider: true when a system dialog is about to appear
    /// and the kiosk needs to yield the screen, false once it is answered.
    static var onAwaitingPermission: (Bool) -> Void = { _ in }

    /// The request has to be retained until its completion fires; a store that
    /// goes out of scope takes the pending prompt with it.
    private static var primingStore: EKEventStore?

    /// Ask for Calendars at launch, while somebody may still be standing at
    /// the machine. Asking lazily — the first time a task actually wants the
    /// calendar — puts the prompt behind a fullscreen kiosk window that has
    /// disabled process switching and app hiding, so the system ends up
    /// waiting on a click nobody can deliver and the task times out at exit 2.
    ///
    /// EventKit only raises a dialog from .notDetermined, so the screen is
    /// yielded when a prompt is genuinely coming and not on every launch.
    static func primeAccess() {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return }

        onAwaitingPermission(true)
        let store = EKEventStore()
        primingStore = store
        let answered: (Bool, Error?) -> Void = { _, _ in
            DispatchQueue.main.async {
                onAwaitingPermission(false)
                primingStore = nil
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: answered)
        } else {
            store.requestAccess(to: .event, completion: answered)
        }
    }

    /// Prints the next `days` days of events as JSON on stdout and exits.
    /// Exit codes: 0 printed, 1 access denied, 2 no answer from TCC.
    static func dump(days: Int) -> Never {
        let store = EKEventStore()
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        var failure: Error?

        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { ok, err in
                granted = ok; failure = err; sem.signal()
            }
        } else {
            store.requestAccess(to: .event) { ok, err in
                granted = ok; failure = err; sem.signal()
            }
        }

        // First run raises a dialog on the kitchen screen. A task waiting
        // forever on a prompt nobody is standing in front of is worse than a
        // task that fails and says so.
        if sem.wait(timeout: .now() + 30) == .timedOut {
            FileHandle.standardError.write(Data(
                "calendar: no response to the access request (a prompt may be waiting on screen)\n".utf8))
            exit(2)
        }
        guard granted else {
            let why = failure?.localizedDescription ?? "not granted"
            FileHandle.standardError.write(Data(
                "calendar: no access to Calendars (\(why)). Grant Neon under System Settings > Privacy & Security > Calendars.\n".utf8))
            exit(1)
        }

        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: max(1, days), to: start) ?? start

        // Local time, explicitly. The calendars disagree about their own zones
        // — Family reads as UTC where the rest are Pacific — so formatting in
        // whatever a calendar defaults to lands all-day events a day out.
        let stamp = ISO8601DateFormatter()
        stamp.timeZone = TimeZone.current
        stamp.formatOptions = [.withInternetDateTime]
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = TimeZone.current

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            .map { e -> [String: Any] in
                var row: [String: Any] = [
                    "calendar": e.calendar?.title ?? "?",
                    "account": e.calendar?.source.title ?? "?",
                    "title": e.title ?? "(untitled)",
                    "allDay": e.isAllDay,
                ]
                // An all-day event has no meaningful clock time, and printing
                // one invites it being read aloud as "at 5pm".
                if let s = e.startDate { row["start"] = e.isAllDay ? day.string(from: s) : stamp.string(from: s) }
                if let f = e.endDate { row["end"] = e.isAllDay ? day.string(from: f) : stamp.string(from: f) }
                if let loc = e.location, !loc.isEmpty { row["location"] = loc }
                return row
            }

        let payload: [String: Any] = [
            "from": day.string(from: start),
            "to": day.string(from: end),
            "timeZone": TimeZone.current.identifier,
            "count": events.count,
            "events": events,
        ]
        if let json = try? JSONSerialization.data(withJSONObject: payload,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(json)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        exit(0)
    }

    /// Calendar names and which account each comes from, no event contents.
    /// Enough to answer "can you see my calendar" without reading anyone's day.
    static func listCalendars() -> Never {
        let store = EKEventStore()
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { ok, _ in granted = ok; sem.signal() }
        } else {
            store.requestAccess(to: .event) { ok, _ in granted = ok; sem.signal() }
        }
        if sem.wait(timeout: .now() + 30) == .timedOut { exit(2) }
        guard granted else { exit(1) }

        for c in store.calendars(for: .event).sorted(by: { $0.source.title < $1.source.title }) {
            print("\(c.source.title)\t\(c.title)")
        }
        exit(0)
    }
}
