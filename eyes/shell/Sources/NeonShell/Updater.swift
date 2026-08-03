import Foundation

#if canImport(Sparkle)
import Sparkle
#endif

// Shipping updates to a machine bolted to a kitchen wall.
//
// Sparkle, because Nick already runs it elsewhere (see ../RAMBLR) and because
// the alternative for a kiosk is somebody standing at the counter with a
// terminal. The feed is an appcast on GitHub Pages; releases are built,
// notarized and published by tools/release.sh.
//
// The whole thing is behind `canImport` so the shell still builds without the
// dependency — which matters more than it sounds, because the wake-model
// pipeline and the offline harnesses get run from checkouts where pulling a
// UI framework to score a WAV file would be silly. Without Sparkle the
// settings panel shows the version and no update button.
//
// ## Unattended updates
//
// Checking is always automatic. *Installing* is a setting, off by default,
// because an update means a relaunch and a relaunch in the middle of a
// sentence is exactly the wrong behaviour for something that lives in a room.
//
// Switched on, the interesting part is not downloading — Sparkle does that —
// but choosing the moment. Sparkle's default is "install when the app next
// quits", and Neon never quits: she is a kitchen appliance that runs for
// months. So the delegate intercepts that, holds the installation block, and
// the shell fires it when the room is genuinely empty: deep asleep, no
// session, no timer counting down, nobody in settings. She updates herself in
// the small hours and is back before anyone notices.
final class Updater: NSObject {
    static let shared = Updater()

    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static var buildVersion: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// Sparkle raises its own windows, which land behind the kiosk unless the
    /// shell steps aside first — set in main.swift.
    var onNeedsScreen: (String) -> Void = { _ in }

    /// A line for the on-screen event log.
    var log: (String, String) -> Void = { _, _ in }

    /// Whether right now is a moment Neon can disappear and come back without
    /// anybody minding. Supplied by the shell, which is the only thing that
    /// knows. Deliberately a closure rather than a flag: it has to be true at
    /// the instant of installing, not at the instant of downloading.
    var isQuiet: () -> Bool = { false }

    #if canImport(Sparkle)
    /// False in a build with no feed configured — a fresh clone, or anyone
    /// running from source, since build.sh only writes SUFeedURL once
    /// tools/sparkle-config.sh has a public key in it. Offering to check for
    /// updates that can never arrive is worse than not offering.
    let isSupported = Bundle.main.infoDictionary?["SUFeedURL"] != nil

    /// Built on first use, and only when there is a feed. Constructing the
    /// controller *starts* Sparkle, and starting it without a feed logs an
    /// error on every launch of every checkout that hasn't been set up to
    /// publish — including the offline harnesses, which have no business
    /// touching an update framework at all.
    private lazy var controller: SPUStandardUpdaterController? = {
        guard isSupported else { return nil }
        let c = SPUStandardUpdaterController(startingUpdater: true,
                                             updaterDelegate: self,
                                             userDriverDelegate: nil)
        c.updater.automaticallyChecksForUpdates = true
        return c
    }()

    /// Download and install without being asked. Sparkle persists this itself,
    /// so it survives restarts without any storage of ours.
    var installsAutomatically: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            controller?.updater.automaticallyDownloadsUpdates = newValue
            log("session", "automatic updates \(newValue ? "on" : "off")")
            // Turning it off mid-flight shouldn't leave a loaded gun: a block
            // captured earlier would still relaunch her at 3am.
            if !newValue { pendingInstall = nil }
        }
    }

    /// Held from the delegate callback until the kitchen is quiet.
    private var pendingInstall: (() -> Void)?

    var hasUpdateWaiting: Bool { pendingInstall != nil }

    private override init() { super.init() }

    func checkForUpdates() {
        guard let controller else { return }
        onNeedsScreen("software update window")
        controller.checkForUpdates(nil)
    }

    /// Called from the shell's idle sweep. Cheap, and a no-op almost always.
    func installIfQuiet() {
        guard let install = pendingInstall, isQuiet() else { return }
        pendingInstall = nil
        log("session", "installing update — restarting")
        NSLog("Neon: installing downloaded update and relaunching")
        install()
    }
    #else
    let isSupported = false
    var installsAutomatically: Bool {
        get { false }
        set { _ = newValue }
    }
    var hasUpdateWaiting: Bool { false }
    private override init() { super.init() }
    func checkForUpdates() {
        NSLog("Neon: built without Sparkle — no update checking")
    }
    func installIfQuiet() {}
    #endif
}

#if canImport(Sparkle)
extension Updater: SPUUpdaterDelegate {
    /// Sparkle has an update downloaded and wants to install it when the app
    /// quits. Neon doesn't quit, so returning true takes ownership of the
    /// timing and keeps the block for `installIfQuiet`.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        pendingInstall = immediateInstallationBlock
        log("session", "update \(item.displayVersionString) ready — "
            + "installing next time the kitchen is quiet")
        NSLog("Neon: update \(item.displayVersionString) downloaded, waiting for a quiet moment")
        return true
    }
}
#endif
