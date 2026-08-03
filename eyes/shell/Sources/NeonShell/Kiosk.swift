import AppKit

// Kitchen-appliance lockdown. The machine Neon runs on stays logged into
// Nick's account so the rest of the assistant can reach his personal data, so
// a fullscreen window on top is not enough on its own: the casual ways off it
// (Cmd-Tab, Cmd-Q, force-quit, the power-button dialog) have to be closed too.
// The deliberate way out is a chord nobody discovers by leaning on Esc.

enum Kiosk {
    /// The machine that runs Neon is the machine she is developed on, so
    /// there has to be a way to build and debug without locking process
    /// switching out of the session. NEON_DEV=1 leaves everything reachable
    /// and keeps Esc as the quit key.
    static let enabled = ProcessInfo.processInfo.environment["NEON_DEV"] != "1"

    /// Apple's kiosk set. The combination matters rather than the individual
    /// flags: the disable options are only legal alongside a hidden Dock, and
    /// AppKit throws on an invalid mix instead of ignoring the bad parts.
    static var options: NSApplication.PresentationOptions {
        var opts: NSApplication.PresentationOptions = [.hideDock, .hideMenuBar]
        guard enabled else { return opts }
        opts.insert(.disableProcessSwitching)    // Cmd-Tab, Mission Control
        opts.insert(.disableForceQuit)           // Cmd-Opt-Esc
        opts.insert(.disableSessionTermination)  // power-button dialog
        opts.insert(.disableHideApplication)     // Cmd-H
        return opts
    }

    /// Presentation options only hold while Neon is the active app and are
    /// dropped when anything else takes over, so they get reapplied on every
    /// activation rather than set once at launch.
    static func apply() {
        NSApp.presentationOptions = options
    }

    /// Ctrl-Opt-Cmd-Q — the way out. Two-handed enough that a guest poking at
    /// the keyboard will not find it, muscle-memory enough for Nick.
    static func isQuitChord(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 12 else { return false }  // q
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return mods == [.control, .option, .command]
    }

    /// Cmd-, — settings, because that is where a Mac user's hand goes. The
    /// bare comma works too (main.swift's key monitor); a kiosk with no menu
    /// bar has plenty of spare single keys, and reaching for a modifier at a
    /// kitchen counter is a nuisance.
    static func isSettingsChord(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 43 else { return false }  // ,
        return event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command]
    }

    /// Ctrl-Opt-Cmd-H — step aside without quitting. macOS permission prompts
    /// (location, mic, screen recording) and Chrome's debugging consent all
    /// appear *behind* a fullscreen kiosk window that has disabled process
    /// switching and app hiding, which makes them impossible to answer: the
    /// system is waiting on a click nobody can deliver. This drops the
    /// lockdown for a moment so the dialog can be dealt with.
    static func isStepAsideChord(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 4 else { return false }  // h
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return mods == [.control, .option, .command]
    }
}
