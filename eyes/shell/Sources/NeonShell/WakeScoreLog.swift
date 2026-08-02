import Foundation

// Every wake score worth looking at, appended to a file that survives
// restarts. The event log in the page is DOM-only and dies with the app, so
// "I think I saw a 0.5 once" was as much evidence as we could gather about
// how the model behaves in the actual kitchen. Threshold tuning needs a
// distribution, not an anecdote.
//
// Held-out eval clips are a poor guide to the live threshold: room reverb,
// distance and the AEC-processed mic path all sit between the speaker and
// the model, and they cost real score (offline positives 0.97+ have been
// reported live around 0.5). This file is the measurement of that gap.
final class WakeScoreLog {
    static let shared = WakeScoreLog()

    private let queue = DispatchQueue(label: "neon.wakelog")
    private let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/neon/wake-scores.log")
    /// Below this, scores are ordinary speech (measured: ≤0.009 across a
    /// 30-sentence battery) and only add noise.
    static let floor: Float = 0.05
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private init() {
        // Keep the tail; this runs 24/7 and nobody will ever prune it.
        queue.async {
            guard let size = try? FileManager.default
                .attributesOfItem(atPath: self.path.path)[.size] as? Int,
                  size > 1_000_000,
                  let text = try? String(contentsOf: self.path, encoding: .utf8)
            else { return }
            try? String(text.suffix(200_000)).write(to: self.path, atomically: true,
                                                    encoding: .utf8)
        }
    }

    /// `outcome` is WAKE (fired), held (over the bar but inside the refractory
    /// window after a fire) or miss (under the bar) — only "miss" lines are
    /// evidence about the threshold.
    func record(model: String, score: Float, outcome: String, threshold: Float) {
        guard score >= Self.floor else { return }
        let line = String(format: "%@\t%.3f\t%@\tthr %.2f\t%@\n",
                          stamp.string(from: Date()), score,
                          outcome, threshold, model)
        queue.async {
            let fm = FileManager.default
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: self.path) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                fm.createFile(atPath: self.path.path, contents: data)
            }
        }
    }
}
