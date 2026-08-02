// Contact sheet of the eyes' expressions, rendered without Chrome.
//
//   swift eyes/shot.swift out.png [emote ...]
//
// Loads web/index.html in an offscreen WKWebView, drives each emote through
// the same window.neon API the shell uses, snapshots it at the frame where
// the expression peaks, and tiles the results into one PNG. Written because
// the chrome-devtools MCP needs an approval dialog that a fullscreen kiosk
// window sits on top of — and because checking nine expressions one
// screenshot at a time is nine round trips.
//
// The window is on screen (faint, floating) on purpose: macOS throttles
// requestAnimationFrame in occluded windows, which stalls the animation and
// snapshots the wrong frame.
import AppKit
import WebKit

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "eyes-contact-sheet.png"
let names = args.count > 2 ? Array(args[2...])
    : ["happy", "laugh", "surprised", "wink", "sad", "confused", "eyeroll", "excited", "love"]

// When each expression is at its most characteristic, in seconds after firing.
let peak: [String: Double] = [
    "happy": 0.5, "laugh": 0.30, "surprised": 0.22, "wink": 0.30, "sad": 1.30,
    "confused": 0.80, "eyeroll": 0.55, "excited": 0.14, "love": 0.95,
]

let shotW = 900.0, shotH = 520.0

final class Harness: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let window: NSWindow
    var shots: [(String, NSImage)] = []

    override init() {
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: shotW, height: shotH),
                        configuration: WKWebViewConfiguration())
        window = NSWindow(contentRect: web.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
        super.init()
        window.contentView = web
        window.level = .floating
        window.alphaValue = 0.02   // present for the compositor, invisible to the room
        window.orderFrontRegardless()
        web.navigationDelegate = self
    }

    func load(_ url: URL) {
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func webView(_ web: WKWebView, didFinish nav: WKNavigation!) {
        Task { await self.run() }
    }

    private func js(_ src: String) async {
        _ = try? await web.evaluateJavaScript(src)
    }

    private func sleep(_ s: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
    }

    private func snapshot() async -> NSImage? {
        await withCheckedContinuation { cont in
            web.takeSnapshot(with: nil) { image, _ in cont.resume(returning: image) }
        }
    }

    func run() async {
        await sleep(1.0)   // let the page settle into its asleep state
        for name in names {
            await js("window.neon.wake()")
            await sleep(2.0)   // the wake animation ends ~1.85 s in
            await js("window.neon.emote('\(name)')")
            await sleep(peak[name] ?? 0.4)
            if let img = await snapshot() { shots.append((name, img)) }
            await js("window.neon.sleep()")
            await sleep(0.5)
        }
        write()
        exit(0)
    }

    private func write() {
        let cols = 3
        let rows = Int(ceil(Double(shots.count) / Double(cols)))
        let cw = shotW, chh = shotH + 26   // room for a caption strip
        let sheet = NSImage(size: NSSize(width: cw * Double(cols), height: chh * Double(rows)))
        sheet.lockFocus()
        NSColor.black.setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (i, (name, img)) in shots.enumerated() {
            let col = i % cols, row = rows - 1 - i / cols   // top-left first
            let x = Double(col) * cw, y = Double(row) * chh
            img.draw(in: NSRect(x: x, y: y + 26, width: cw, height: shotH))
            let label = NSAttributedString(string: name, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor(calibratedRed: 0.5, green: 0.85, blue: 0.95, alpha: 1),
            ])
            label.draw(at: NSPoint(x: x + 14, y: y + 5))
        }
        sheet.unlockFocus()
        guard let tiff = sheet.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("failed to encode PNG"); return
        }
        try? png.write(to: URL(fileURLWithPath: outPath))
        print("wrote \(outPath) — \(shots.count) expressions")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no dock icon, no stealing focus
let harness = Harness()

var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
var page: URL?
for _ in 0..<5 {
    for rel in ["eyes/web/index.html", "web/index.html"] {
        let c = dir.appendingPathComponent(rel)
        if FileManager.default.fileExists(atPath: c.path) { page = c; break }
    }
    if page != nil { break }
    dir.deleteLastPathComponent()
}
guard let page else { print("index.html not found"); exit(1) }
harness.load(page)
app.run()
