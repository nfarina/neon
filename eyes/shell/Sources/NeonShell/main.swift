import AppKit
import WebKit

// Neon kiosk shell: a borderless fullscreen window hosting the eyes web page,
// plus the wake-word listener. Esc quits; W triggers a wake for testing.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var wakeListener: WakeWordListener?
    private var voiceSession: VoiceSession?
    private var keyMonitor: Any?
    private var debugVisible = false
    private var statsTimer: Timer?
    private var wakeHeard = ""  // latest wake-listener transcript, for the overlay
    private var providerName = ProcessInfo.processInfo.environment["NEON_PROVIDER"]
        ?? UserDefaults.standard.string(forKey: "neon.voiceProvider") ?? "gemini"

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let screen = NSScreen.main else { fatalError("no screen") }

        webView = WKWebView(frame: screen.frame, configuration: WKWebViewConfiguration())
        webView.isInspectable = true  // allow Safari Web Inspector while developing

        window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.backgroundColor = .black
        window.contentView = webView

        loadEyes()

        window.makeKeyAndOrderFront(nil)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        NSApp.activate(ignoringOtherApps: true)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case 53:  // esc
                NSApp.terminate(nil)
                return nil
            case 13:  // w — manual wake, for testing without the mic
                self?.triggerWake()
                return nil
            case 1:   // s — end the voice session early
                self?.voiceSession?.close(reason: "manual")
                return nil
            case 2:   // d — toggle the debug overlay
                self?.toggleDebugOverlay()
                return nil
            case 14:  // e — cycle voice engine (takes effect next session)
                self?.cycleEngine()
                return nil
            default:
                return event
            }
        }

        let listener = WakeWordListener()
        listener.onWake = { [weak self] command in self?.triggerWake(command: command) }
        listener.onTranscript = { [weak self] text in self?.wakeHeard = text }
        listener.start()
        wakeListener = listener

        // Debug hook: NEON_AUTOWAKE=1 starts a voice session shortly after
        // launch, so the full audio path is testable without speaking.
        if ProcessInfo.processInfo.environment["NEON_AUTOWAKE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.triggerWake()
            }
        }
    }

    private func triggerWake(command: String? = nil) {
        webView.evaluateJavaScript("window.neon && neon.wake()")
        startVoiceSession(command: command)
    }

    private func toggleDebugOverlay() {
        debugVisible.toggle()
        webView.evaluateJavaScript("window.neon && neon.debug(\(debugVisible))")
        statsTimer?.invalidate()
        statsTimer = nil
        if debugVisible {
            pushStats()
            statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.pushStats()
            }
        }
    }

    private func cycleEngine() {
        let idx = engineNames.firstIndex(of: providerName) ?? 0
        providerName = engineNames[(idx + 1) % engineNames.count]
        UserDefaults.standard.set(providerName, forKey: "neon.voiceProvider")
        NSLog("Neon: voice engine -> \(providerName) (next session)")
        pushStats()
    }

    private func pushStats() {
        let pairs: [[String]]
        if let session = voiceSession {
            pairs = session.statsPairs()
        } else {
            pairs = [
                ["engine", "\(providerName) (idle)"],
                ["lifetime", String(format: "$%.3f", UsageStore.shared.total)],
                ["mac hears", String(wakeHeard.suffix(70))],
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: pairs) {
            let json = String(decoding: data, as: UTF8.self)
            webView.evaluateJavaScript("window.neon && neon.stats(\(json))")
        }
    }

    private func startVoiceSession(command: String? = nil) {
        guard voiceSession == nil else { return }
        NSLog("Neon: starting voice session")
        wakeListener?.stop()  // hand the microphone to the conversation
        webView.evaluateJavaScript("window.neon && neon.hold(true)")
        let session = VoiceSession(engine: makeEngine(providerName), firstUtterance: command)
        session.onAmplitude = { [weak self] amp in
            self?.webView.evaluateJavaScript("window.neon && neon.speaking(\(amp))")
        }
        session.onClosed = { [weak self] reason in
            guard let self else { return }
            NSLog("Neon: voice session ended (\(reason))")
            self.voiceSession = nil
            self.webView.evaluateJavaScript("window.neon && neon.hold(false)")
            if reason == "tool" {
                // The model put itself to sleep — eyes close right away;
                // the slow dozing-off animation is reserved for idle silence.
                self.webView.evaluateJavaScript("window.neon && neon.sleep()")
            }
            self.wakeListener?.start()  // take the microphone back
        }
        voiceSession = session
        session.start()
    }

    private func loadEyes() {
        // Bundled resource first (production: inside Neon.app)
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            return
        }
        // Dev fallback: walk up from cwd looking for the web page
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<5 {
            for rel in ["web/index.html", "eyes/web/index.html"] {
                let candidate = dir.appendingPathComponent(rel)
                if fm.fileExists(atPath: candidate.path) {
                    webView.loadFileURL(candidate, allowingReadAccessTo: candidate.deletingLastPathComponent())
                    return
                }
            }
            dir.deleteLastPathComponent()
        }
        webView.loadHTMLString("<body style='background:#000;color:#fff'><h1>index.html not found</h1></body>", baseURL: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
