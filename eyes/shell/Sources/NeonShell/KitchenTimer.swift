import AVFoundation
import Foundation

// The kitchen timer: one at a time, first-class, and deliberately not a
// "task".
//
// It started life as a task producer, and the first real use showed why that
// was wrong — the timer fired, Neon woke up, and announced "quick check is
// done". A timer going off does not need a conversation: it needs to be
// obvious in the room and easy to silence. So it rings on its own, holds that
// state until someone stops it, and never opens a session to say so.
//
// Ringing ends three ways: space, a click anywhere, or telling Neon to stop —
// which is the only path that costs a session, and only because someone chose
// to talk instead of reaching over.
final class KitchenTimer {
    static let shared = KitchenTimer()

    /// State changed — relabel the on-screen pill.
    var onChanged: (KitchenTimer) -> Void = { _ in }
    /// Started ringing, or stopped. The shell uses this for the cursor and
    /// to keep the panel awake.
    var onRingChanged: (Bool) -> Void = { _ in }

    private(set) var label = ""
    private(set) var dueAt: Date?
    private(set) var ringing = false

    private var timer: Timer?
    private var chimeTimer: Timer?
    private let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/neon/timer.json")

    private init() { restore() }

    var isActive: Bool { dueAt != nil || ringing }
    var remaining: TimeInterval { max(0, dueAt?.timeIntervalSinceNow ?? 0) }

    // MARK: - Control

    /// Replaces any existing timer — there is only ever one.
    func start(label: String, seconds: TimeInterval) {
        stop(silent: true)
        self.label = label
        dueAt = Date().addingTimeInterval(seconds)
        timer = Timer.scheduledTimer(withTimeInterval: max(0.1, seconds),
                                     repeats: false) { [weak self] _ in
            self?.ring()
        }
        save()
        onChanged(self)
    }

    @discardableResult
    func stop(silent: Bool = false) -> Bool {
        let wasSomething = isActive
        timer?.invalidate(); timer = nil
        chimeTimer?.invalidate(); chimeTimer = nil
        let wasRinging = ringing
        ringing = false
        dueAt = nil
        label = ""
        try? FileManager.default.removeItem(at: path)
        if !silent {
            onChanged(self)
            if wasRinging { onRingChanged(false) }
        }
        return wasSomething
    }

    /// What the model should hear when it asks.
    func status() -> String {
        if ringing { return "The \"\(label)\" timer is going off right now." }
        guard dueAt != nil else { return "No timer set." }
        let left = Int(remaining)
        let time = left >= 60
            ? "\(left / 60) minute\(left / 60 == 1 ? "" : "s")"
                + (left % 60 > 0 ? " \(left % 60) seconds" : "")
            : "\(left) seconds"
        return "\"\(label)\" — \(time) left."
    }

    private func ring() {
        ringing = true
        dueAt = nil
        save()
        onChanged(self)
        onRingChanged(true)
        chime()
        // Keep chiming until someone deals with it. A timer that dings once
        // from another room may as well not have gone off.
        chimeTimer = Timer.scheduledTimer(withTimeInterval: 2.4, repeats: true) { [weak self] _ in
            self?.chime()
        }
    }

    // MARK: - Sound

    /// A two-tone chime, synthesized rather than shipped as an asset, played
    /// through AudioHub so echo cancellation subtracts it from the mic — Neon
    /// must still hear "stop" over her own alarm.
    private func chime() {
        let hub = AudioHub.shared
        hub.ensurePlayer()
        let rate = 24000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let notes: [(freq: Double, start: Double, len: Double)] = [
            (880, 0.0, 0.28), (1174.7, 0.22, 0.42),
        ]
        let total = 0.7
        let frames = AVAudioFrameCount(rate * total)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let out = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { out[i] = 0 }
        for note in notes {
            let start = Int(note.start * rate)
            let len = Int(note.len * rate)
            for i in 0..<len where start + i < Int(frames) {
                let t = Double(i) / rate
                let envelope = exp(-t * 6.5)          // struck-bell decay
                out[start + i] += Float(sin(2 * .pi * note.freq * t) * envelope * 0.22)
            }
        }
        hub.player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    // MARK: - Persistence

    private func save() {
        var obj: [String: Any] = ["label": label, "ringing": ringing]
        if let dueAt { obj["dueAt"] = dueAt.timeIntervalSince1970 }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? data.write(to: path)
    }

    /// A timer whose moment passed while the app was quit still matters to
    /// whoever set it — restore it straight into the ringing state rather
    /// than pretending it never happened.
    private func restore() {
        guard let data = try? Data(contentsOf: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        label = obj["label"] as? String ?? "timer"
        let wasRinging = obj["ringing"] as? Bool ?? false
        let due = (obj["dueAt"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
        // Defer: the audio hub and the web page aren't up yet at init time.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            if wasRinging || (due.map { $0 <= Date() } ?? false) {
                self.ring()
            } else if let due {
                self.start(label: self.label, seconds: due.timeIntervalSinceNow)
            }
        }
    }
}
