import CoreLocation
import Foundation

// Where and when Neon is, injected into every session's system prompt.
//
// Without this she has no idea what city she's in ("which city are you in?"
// in reply to "what's the weather") and no idea what day it is — a model's
// training cutoff is not today, and a kitchen assistant is asked about today
// constantly.
//
// City-level only. The coordinates never leave this process: they're reverse
// geocoded here and only the place name goes into the prompt, because "what's
// the weather" needs a city, not a house.
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    private let manager = CLLocationManager()
    /// Cached across launches so the first session after a restart still knows
    /// where it is — a fix plus reverse geocode takes seconds, and the wake
    /// that starts a session may come before it lands.
    private var place: String? {
        get { UserDefaults.standard.string(forKey: "neon.place") }
        set { UserDefaults.standard.set(newValue, forKey: "neon.place") }
    }

    private override init() {
        super.init()
        manager.delegate = self
        // A kitchen does not move. Kilometre accuracy is plenty and asks the
        // system for the cheapest possible fix.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()   // fix requested in the callback
        case .authorized, .authorizedAlways:
            manager.requestLocation()
        default:
            dbg("location: denied or restricted; falling back to the profile file")
        }
    }

    /// Human-readable state for the debug overlay. `dbg()` goes to stderr,
    /// which is invisible when the app is launched with `open` — and a
    /// permission that never got granted looks exactly like a bug otherwise.
    func status() -> String {
        let auth: String
        switch manager.authorizationStatus {
        case .notDetermined: auth = "not asked yet"
        case .restricted: auth = "restricted"
        case .denied: auth = "denied — System Settings > Privacy > Location Services"
        case .authorized, .authorizedAlways: auth = "authorized"
        @unknown default: auth = "unknown"
        }
        return "\(place ?? "no fix") · \(auth)"
    }

    /// The line handed to the model, or nil if we know neither where nor when
    /// (we always know when, so this is nil only in the impossible case).
    func promptLine() -> String? {
        let now = Date()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US")
        fmt.dateFormat = "EEEE, MMMM d, yyyy, h:mm a"
        let zone = TimeZone.current.localizedName(for: .generic, locale: Locale(identifier: "en_US"))
            ?? TimeZone.current.identifier
        var line = "Right now it is \(fmt.string(from: now)) (\(zone))."
        if let place {
            line += " You are currently in \(place) — assume it for anything "
                + "local (weather, sunset, sports, nearby places) without asking "
                + "which city, and don't say it back unless it's the point."
        }
        return line
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus == .authorized || m.authorizationStatus == .authorizedAlways {
            m.requestLocation()
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] marks, error in
            guard let mark = marks?.first else {
                dbg("location: reverse geocode failed: \(error?.localizedDescription ?? "no result")")
                return
            }
            // City + state reads naturally and is all a weather lookup needs.
            let parts = [mark.locality, mark.administrativeArea].compactMap { $0 }
            guard !parts.isEmpty else { return }
            let name = parts.joined(separator: ", ")
            if name != self?.place {
                dbg("location: \(name)")
            }
            self?.place = name
        }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        dbg("location: fix failed: \(error.localizedDescription)")
    }
}
