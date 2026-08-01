import AppKit
import Darwin
import IOKit.pwr_mgt

// Owns the kitchen display: keeps it lit and unlocked while Neon runs, and
// takes the backlight down to an ember when she goes into deep sleep.
//
// Everything here is scoped to the process. `pmset displaysleep 0` would
// leave the machine changed after Neon exits; a power assertion goes away
// with her, so the MacBook behaves normally the moment she is not running.

final class DisplayKeeper {

    // MARK: - keeping the screen alive

    private var awakeToken: NSObjectProtocol?
    private var activityTimer: Timer?

    func start() {
        guard awakeToken == nil else { return }
        awakeToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled],
            reason: "Neon is an always-on ambient display")

        // The assertion covers display and system sleep, but the screen saver
        // and the login-window lock run off the HID idle clock, which power
        // assertions do not touch. Declaring user activity is what
        // `caffeinate -u` does; on a period well under any plausible screen
        // saver delay it keeps the idle clock from ever reaching the lock.
        declareUserActivity()
        activityTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.declareUserActivity()
        }
    }

    private func declareUserActivity() {
        var id = IOPMAssertionID(0)
        IOPMAssertionDeclareUserActivity("Neon ambient display" as CFString,
                                        kIOPMUserActiveLocal, &id)
    }

    // MARK: - backlight

    // The internal panel's backlight is only reachable through DisplayServices,
    // which is private — the public IOKit brightness API stopped working on
    // Apple silicon. Resolved by hand at runtime so a macOS that drops the
    // symbols degrades to render-only dimming instead of failing to launch.
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let ptr = dlsym(handle, name) else { return nil }
        return unsafeBitCast(ptr, to: type)
    }

    private static let getBrightness = symbol("DisplayServicesGetBrightness", as: GetBrightness.self)
    private static let setBrightness = symbol("DisplayServicesSetBrightness", as: SetBrightness.self)

    /// Whether the backlight is actually ours to move. The eyes ask this to
    /// decide how far to fade their own rendering: with the panel down at a
    /// few percent, fading the pixels as hard as well would erase them.
    private(set) lazy var controlsBacklight: Bool =
        DisplayKeeper.setBrightness != nil && readBrightness() != nil

    private func readBrightness() -> Float? {
        guard let get = DisplayKeeper.getBrightness else { return nil }
        var level: Float = 0
        guard get(CGMainDisplayID(), &level) == 0 else { return nil }
        return level
    }

    private func writeBrightness(_ level: Float) {
        guard let set = DisplayKeeper.setBrightness else { return }
        _ = set(CGMainDisplayID(), max(0, min(1, level)))
    }

    private var fadeTimer: Timer?
    private var restoreLevel: Float?  // brightness to come back to, if we dimmed
    private var lastWritten: Float?   // what we last set, to notice manual changes

    /// Fade the panel down, remembering where it was.
    func dim(to target: Float, over duration: TimeInterval) {
        guard controlsBacklight else { return }
        if restoreLevel == nil { restoreLevel = readBrightness() }
        fade(to: target, over: duration)
    }

    /// Come back up to wherever the panel was before deep sleep.
    func restore(over duration: TimeInterval) {
        guard let target = restoreLevel else { return }
        restoreLevel = nil
        // If Nick reached for the brightness keys while she was dimmed, that
        // is the setting he wants — don't stomp it on the way back up.
        if let written = lastWritten, let current = readBrightness(),
           abs(current - written) > 0.05 {
            fadeTimer?.invalidate()
            fadeTimer = nil
            return
        }
        fade(to: target, over: duration)
    }

    /// Put the brightness back in one step, for the way out (quit, SIGINT).
    /// A dimmed panel left behind by a crash is fixable with the brightness
    /// keys, but it should not be the normal exit.
    func restoreImmediately() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        if let target = restoreLevel {
            writeBrightness(target)
            restoreLevel = nil
        }
    }

    private func fade(to target: Float, over duration: TimeInterval) {
        fadeTimer?.invalidate()
        fadeTimer = nil
        guard let start = readBrightness() else { return }
        guard duration > 0 else {
            writeBrightness(target)
            lastWritten = target
            return
        }
        let step = 1.0 / 30.0
        var elapsed = 0.0
        fadeTimer = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            elapsed += step
            let t = Float(min(1, elapsed / duration))
            let level = start + (target - start) * t
            self.writeBrightness(level)
            self.lastWritten = level
            if t >= 1 {
                timer.invalidate()
                self.fadeTimer = nil
            }
        }
    }
}
