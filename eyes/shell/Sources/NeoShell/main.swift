import AppKit
import WebKit

// Neo kiosk shell: a borderless fullscreen window hosting the eyes web page,
// plus the wake-word listener. Esc quits; W triggers a wake for testing.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var wakeListener: WakeWordListener?
    private var keyMonitor: Any?

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
            default:
                return event
            }
        }

        let listener = WakeWordListener()
        listener.onWake = { [weak self] in self?.triggerWake() }
        listener.start()
        wakeListener = listener
    }

    private func triggerWake() {
        webView.evaluateJavaScript("window.neo && neo.wake()")
    }

    private func loadEyes() {
        // Bundled resource first (production: inside Neo.app)
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
