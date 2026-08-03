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
// Automatic checks are on, installs are not: Neon restarting into a new build
// unannounced while someone is mid-sentence is exactly the wrong behaviour for
// something that lives in a room. She notices an update and waits to be told.
final class Updater {
    static let shared = Updater()

    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static var buildVersion: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

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
                                             updaterDelegate: nil,
                                             userDriverDelegate: nil)
        c.updater.automaticallyChecksForUpdates = true
        // Installs stay manual: Neon restarting into a new build unannounced
        // while somebody is mid-sentence is exactly the wrong behaviour for
        // something that lives in a room.
        c.updater.automaticallyDownloadsUpdates = false
        return c
    }()

    private init() {}

    /// Sparkle raises its own windows, which land behind the kiosk unless the
    /// shell steps aside first — `onNeedsScreen` is set in main.swift.
    var onNeedsScreen: (String) -> Void = { _ in }

    func checkForUpdates() {
        guard let controller else { return }
        onNeedsScreen("software update window")
        controller.checkForUpdates(nil)
    }
    #else
    private init() {}
    var isSupported: Bool { false }
    var onNeedsScreen: (String) -> Void = { _ in }
    func checkForUpdates() {
        NSLog("Neon: built without Sparkle — no update checking")
    }
    #endif
}
