import AppKit
import WebKit

// The settings panel's half of the bridge.
//
// Until now the shell talked to the page and the page never answered:
// evaluateJavaScript in one direction, nothing coming back. A settings screen
// needs the other direction, so this installs a WKScriptMessageHandler and the
// page posts `{action: …}` objects to it.
//
// Everything the panel shows is assembled here into one state object and
// pushed whole. Diffing UI state across a bridge is how you end up with a
// checkbox that disagrees with the file on disk; the panel is small enough
// that re-rendering all of it on every change costs nothing and can't drift.
//
// Opening settings puts Neon to sleep: the session closes, the wake listener
// stops, and the eyes shut. Nobody wants to be overheard by the thing whose
// microphone settings they are reading, and a wake mid-edit would be absurd.
final class SettingsBridge: NSObject, WKScriptMessageHandler {

    /// The name the page posts to: `webkit.messageHandlers.neon.postMessage(…)`.
    static let handlerName = "neon"

    private(set) var isOpen = false

    /// Evaluate a line of JavaScript in the eyes page.
    var evaluate: (String) -> Void = { _ in }
    /// Entering or leaving settings — the shell sleeps Neon, shows the cursor
    /// and stops the wake listener.
    var onOpenChanged: (Bool) -> Void = { _ in }
    /// Yield the screen so a macOS permission dialog can be answered.
    var onNeedsScreen: (String) -> Void = { _ in }
    /// A line for the event log.
    var log: (String, String) -> Void = { _, _ in }

    private let profilePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/neon/profile.md")

    private var enrollment: EnrollmentSession?

    override init() {
        super.init()
        PluginRegistry.shared.onChanged = { [weak self] in self?.push() }
    }

    // MARK: - Open / close

    func open() {
        guard !isOpen else { return }
        isOpen = true
        log("session", "settings opened")
        onOpenChanged(true)
        // The page answers with `ready`, which is what triggers the first
        // push. Pushing here instead would land before the panel exists to
        // draw it, and would miss a reload.
        evaluate("window.neon && neon.settingsOpen(true)")
    }

    func close() {
        guard isOpen else { return }
        // A sitting left running would keep the camera on behind a panel
        // nobody is looking at.
        enrollment?.cancel()
        enrollment = nil
        isOpen = false
        log("session", "settings closed")
        evaluate("window.neon && neon.settingsOpen(false)")
        onOpenChanged(false)
    }

    func toggle() { isOpen ? close() : open() }

    // MARK: - Incoming

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {
        case "ready":
            push()

        case "close":
            close()

        case "plugin":
            guard let id = body["id"] as? String, let on = body["on"] as? Bool else { return }
            PluginRegistry.shared.setEnabled(id, on)
            log("session", "plugin \(id) → \(on ? "on" : "off")")
            // setEnabled fires onChanged, which pushes.

        case "permission":
            guard let id = body["id"] as? String,
                  let permission = PluginRegistry.shared.plugin(id: id)?.permission else { return }
            requestPermission(permission, for: id)

        case "profile":
            guard let text = body["text"] as? String else { return }
            saveProfile(text)

        case "enroll":
            guard let name = body["name"] as? String else { return }
            startEnrollment(name: name)

        case "enrollCancel":
            enrollment?.cancel()
            enrollment = nil

        case "forget":
            guard let name = body["name"] as? String else { return }
            PersonStore.shared.forget(name: name)
            log("who", "forgot \(name)")
            push()

        case "checkUpdates":
            Updater.shared.checkForUpdates()

        case "autoUpdate":
            guard let on = body["on"] as? Bool else { return }
            Updater.shared.installsAutomatically = on
            push()

        case "quit":
            NSApp.terminate(nil)

        default:
            NSLog("Neon settings: unknown action \(action)")
        }
    }

    // MARK: - Actions

    private func requestPermission(_ permission: PluginPermission, for id: String) {
        // Already denied: macOS will not ask twice, so opening the dialog
        // would silently do nothing and look broken. Say where the switch is
        // instead.
        guard permission.status == .notDetermined else {
            push()
            return
        }
        onNeedsScreen("\(id) permission dialog")
        permission.request { [weak self] granted in
            self?.log("session", "\(id) permission → \(granted ? "granted" : "refused")")
            self?.push()
        }
    }

    private func saveProfile(_ text: String) {
        let dir = profilePath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: profilePath, atomically: true, encoding: .utf8)
        log("session", "household profile saved (\(text.count) chars)")
        push()
    }

    private func loadProfile() -> String {
        (try? String(contentsOf: profilePath, encoding: .utf8)) ?? ""
    }

    private func startEnrollment(name: String) {
        guard enrollment == nil else { return }
        let session = EnrollmentSession()
        enrollment = session
        session.onProgress = { [weak self] p in
            self?.pushEnrollment([
                "running": p.phase != .finished && p.phase != .failed,
                "phase": p.phase.rawValue,
                "message": p.message,
                "remaining": p.remaining,
                "captured": p.captured,
            ])
        }
        session.onPreview = { [weak self] b64 in
            self?.pushEnrollment(["preview": b64])
        }
        session.onFinished = { [weak self] ok, report in
            guard let self else { return }
            self.enrollment = nil
            self.log("who", "enrolled \(name): \(ok ? "ok" : "failed")")
            self.pushEnrollment([
                "running": false, "phase": ok ? "finished" : "failed",
                "message": ok ? "Enrolled \(name)." : report,
                "report": report, "remaining": 0, "captured": 0,
            ])
            self.push()
        }
        log("who", "enrolling \(name)")
        session.start(name: name, wantsPreview: true)
    }

    // MARK: - Outgoing

    func push() {
        guard isOpen else { return }
        send("neon.settings", stateObject())
    }

    /// Everything the panel draws, in one object. Split out from `push` so
    /// `NEON_SETTINGS_TEST=1` can print it without a window, a microphone or a
    /// kiosk — the same trick TaskStore and KitchenTimer use to be checkable
    /// without anybody having to talk to Neon.
    func stateObject() -> [String: Any] {
        var state: [String: Any] = [
            "version": Updater.shortVersion,
            "build": Updater.buildVersion,
            "updatesSupported": Updater.shared.isSupported,
            "autoUpdate": Updater.shared.installsAutomatically,
            "updateWaiting": Updater.shared.hasUpdateWaiting,
            "profile": loadProfile(),
        ]

        state["plugins"] = PluginRegistry.shared.all.map { plugin -> [String: Any] in
            var row: [String: Any] = [
                "id": plugin.id, "title": plugin.title, "blurb": plugin.blurb,
                "on": PluginRegistry.shared.isEnabled(plugin.id),
            ]
            if let permission = plugin.permission {
                let status = permission.status
                row["permission"] = [
                    "status": status.rawValue,
                    "hint": status == .denied ? permission.settingsHint : "",
                ]
            }
            return row
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, yyyy"
        state["people"] = PersonStore.shared.people.map { p -> [String: Any] in
            var row: [String: Any] = [
                "name": p.name, "voice": p.voice != nil, "faces": p.faces.count,
            ]
            let updated = [p.voiceUpdated, p.facesUpdated].compactMap { $0 }.max()
            if let updated { row["updated"] = fmt.string(from: updated) }
            return row
        }
        state["faceModel"] = FaceID.shared.isAvailable
        state["voiceModel"] = VoiceID.shared.isAvailable

        // Which calendars she can actually see. "Can you read my calendar" is
        // the first thing anyone wants confirmed after clicking Allow, and a
        // list of names answers it without reading anybody's day.
        if PluginRegistry.shared.isEnabled(CalendarPlugin.shared.id) {
            state["calendars"] = CalendarBridge.calendarNames().map {
                ["account": $0.account, "title": $0.title]
            }
        }

        return state
    }

    private func pushEnrollment(_ obj: [String: Any]) {
        send("neon.enrollment", obj)
    }

    private func send(_ function: String, _ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluate("window.neon && \(function)(\(json))")
    }
}
