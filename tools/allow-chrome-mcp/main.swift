import Cocoa
import ApplicationServices

// Auto-dismisses two Chrome annoyances that come with DevTools MCP debugging
// of a running browser (--autoConnect):
//
//   1. The "Allow remote debugging?" consent dialog — clicks Allow, but only
//      when the dialog text mentions debugging/DevTools, so Chrome's other
//      Allow-style prompts (camera, mic, notifications) are never touched.
//   2. The "Chrome is being controlled by automated test software" banner —
//      clicks its X. The close button is searched only within the banner's
//      own container, never the whole window (tabs have Close buttons too).

let chromeBundleIDs: Set<String> = [
    "com.google.Chrome",
    "com.google.Chrome.beta",
    "com.google.Chrome.dev",
    "com.google.Chrome.canary",
    "org.chromium.Chromium",
]

let debugKeywords = ["debug", "devtools"]
let allowButtonTitle = "allow"
let bannerMarker = "controlled by automated test software"
let pollInterval: TimeInterval = 1.0
let maxDepth = 15
let maxNodesPerWindow = 3000

let dryRun = CommandLine.arguments.contains("--dry-run")
let verbose = CommandLine.arguments.contains("--verbose") || dryRun

let timestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func log(_ message: String) {
    print("[\(timestampFormatter.string(from: Date()))] \(message)")
    fflush(stdout)
}

func copyAttr(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value
}

func elementAttr(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = copyAttr(element, attribute),
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func textOf(_ element: AXUIElement) -> String {
    var parts: [String] = []
    for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
        if let s = copyAttr(element, attribute) as? String, !s.isEmpty {
            parts.append(s)
        }
    }
    return parts.joined(separator: " ")
}

enum PressResult {
    case pressed
    case stale
    case failed(AXError)
}

func press(_ button: AXUIElement) -> PressResult {
    let error = AXUIElementPerformAction(button, kAXPressAction as CFString)
    switch error {
    case .success:
        return .pressed
    case .invalidUIElement, .cannotComplete:
        // The element vanished between scan and press (e.g. a stacked
        // duplicate dialog already dismissed by the previous press).
        return .stale
    default:
        return .failed(error)
    }
}

struct WindowScan {
    var texts: [String] = []
    var allowButtons: [AXUIElement] = []
    var bannerMarkers: [AXUIElement] = []
    var nodesVisited = 0
}

func collect(_ element: AXUIElement, depth: Int, into scan: inout WindowScan) {
    scan.nodesVisited += 1
    if depth > maxDepth || scan.nodesVisited > maxNodesPerWindow { return }

    let role = copyAttr(element, kAXRoleAttribute) as? String ?? ""
    // Skip web page content entirely — everything we care about is native
    // Chrome UI, and web content trees are enormous.
    if role == "AXWebArea" { return }

    let text = textOf(element)
    if !text.isEmpty {
        scan.texts.append(text)
        if text.lowercased().contains(bannerMarker) {
            scan.bannerMarkers.append(element)
        }
    }

    if role == kAXButtonRole as String {
        if text.lowercased() == allowButtonTitle {
            scan.allowButtons.append(element)
        }
        return
    }

    if let children = copyAttr(element, kAXChildrenAttribute) as? [AXUIElement] {
        for child in children {
            collect(child, depth: depth + 1, into: &scan)
        }
    }
}

func findCloseButton(in root: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if depth > 6 { return nil }
    let role = copyAttr(root, kAXRoleAttribute) as? String ?? ""
    if role == "AXWebArea" { return nil }
    if role == kAXButtonRole as String {
        return textOf(root).lowercased().contains("close") ? root : nil
    }
    if let children = copyAttr(root, kAXChildrenAttribute) as? [AXUIElement] {
        for child in children {
            if let found = findCloseButton(in: child, depth: depth + 1) {
                return found
            }
        }
    }
    return nil
}

// Climb from the banner's text element to the smallest enclosing container
// that also holds the close button. Capped at a few levels so the search can
// never widen to the whole window (where tab Close buttons live).
func closeButtonForBanner(marker: AXUIElement) -> AXUIElement? {
    var container = marker
    for _ in 0..<3 {
        guard let parent = elementAttr(container, kAXParentAttribute) else { return nil }
        container = parent
        if let button = findCloseButton(in: container) {
            return button
        }
    }
    return nil
}

func handleAllowDialog(_ scan: WindowScan, appName: String) -> Bool {
    guard !scan.allowButtons.isEmpty else { return false }

    let matchedTexts = scan.texts.filter { text in
        let lower = text.lowercased()
        return debugKeywords.contains { lower.contains($0) }
    }
    guard !matchedTexts.isEmpty else {
        if verbose {
            log("Ignoring Allow button in \(appName) — no debug keyword nearby.")
        }
        return false
    }

    if dryRun {
        log("[dry run] Would click Allow in \(appName). Matched text: \(matchedTexts.joined(separator: " | "))")
        return true
    }

    for button in scan.allowButtons {
        switch press(button) {
        case .pressed:
            log("Clicked Allow in \(appName). Matched text: \(matchedTexts.joined(separator: " | "))")
            return true
        case .stale:
            continue
        case .failed(let error):
            log("Failed to click Allow in \(appName) (AXError \(error.rawValue))")
        }
    }
    return false
}

func handleBanner(_ scan: WindowScan, appName: String) {
    for marker in scan.bannerMarkers {
        guard let closeButton = closeButtonForBanner(marker: marker) else {
            if verbose {
                log("Found automation banner in \(appName) but no close button nearby.")
            }
            continue
        }
        if dryRun {
            log("[dry run] Would close automation banner in \(appName).")
            continue
        }
        switch press(closeButton) {
        case .pressed:
            log("Closed automation banner in \(appName).")
            return
        case .stale:
            continue
        case .failed(let error):
            log("Failed to close automation banner in \(appName) (AXError \(error.rawValue))")
        }
    }
}

func inspect(window: AXUIElement, appName: String) {
    var scan = WindowScan()
    collect(window, depth: 0, into: &scan)

    // If we just clicked Allow, the tree has changed; deal with any banner
    // on the next poll.
    if handleAllowDialog(scan, appName: appName) { return }
    handleBanner(scan, appName: appName)
}

func scanOnce() {
    // NSRunningApplication is queried fresh each scan; NSWorkspace's
    // runningApplications array only updates via run-loop notifications and
    // went permanently stale when Chrome restarted.
    for bundleID in chromeBundleIDs {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            guard let windows = copyAttr(axApp, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for window in windows {
                inspect(window: window, appName: app.localizedName ?? bundleID)
            }
        }
    }
}

// Prompt for Accessibility permission if we don't have it yet, then wait for
// the user to grant it rather than exiting (launchd would just respawn us).
let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
if !AXIsProcessTrustedWithOptions(promptOptions) {
    log("Waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility)...")
    while !AXIsProcessTrusted() {
        Thread.sleep(forTimeInterval: 2.0)
    }
    log("Accessibility permission granted.")
}

log("Watching for Chrome debugging dialogs and automation banners\(dryRun ? " (dry run)" : "")...")
// Drive scans from the main run loop (not a sleep loop) so AppKit can
// process app-lifecycle notifications between scans.
let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
    autoreleasepool {
        scanOnce()
    }
}
timer.tolerance = 0.2
RunLoop.main.run()
