import Foundation
import OnnxRuntimeBindings

// Who is talking. A speaker-embedding model (3D-Speaker CAM++, 192 dims) turns
// a few seconds of speech into a vector; enrolled voices are the mean of a
// person's clips, and a live utterance is whoever it's nearest to — if it's
// near enough to anyone at all.
//
// The model lives in ~/.config/neon/voiceid/ rather than the app bundle: it is
// a 27 MB third-party download, not a build artifact, and it must NOT go in
// wake/models — OpenWakeListener treats every .onnx there that isn't a feature
// extractor as a candidate wake model.
//
// Voiceprints are biometric data about a family including two children. They
// live in ~/.config/neon/voices.json, outside the repo, same rule as the
// household profile.
struct VoiceProfile: Codable {
    var name: String
    var embedding: [Float]     // mean of enrolled clips, L2-normalised
    var clips: Int
    var updated: Date
}

final class VoiceID {
    static let shared = VoiceID()

    private var env: ORTEnv?
    private var session: ORTSession?
    private(set) var profiles: [VoiceProfile] = []

    /// Cosine similarity below which an utterance is "someone else". Starting
    /// point from the CAM++ literature; tune against the real family, since
    /// far-field kitchen audio scores lower than the clean speech these
    /// thresholds are usually quoted for.
    static var threshold: Float = {
        ProcessInfo.processInfo.environment["NEON_VOICEID_THRESHOLD"]
            .flatMap(Float.init) ?? 0.55
    }()

    private static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/neon/voiceid")
    private static let profilePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/neon/voices.json")

    private init() { loadProfiles() }

    var isAvailable: Bool { session != nil || load() }

    @discardableResult
    func load() -> Bool {
        guard session == nil else { return true }
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.dir,
                                                                  includingPropertiesForKeys: nil)) ?? []
        guard let model = files.first(where: { $0.pathExtension == "onnx" }) else {
            dbg("voiceid: no model in \(Self.dir.path)")
            return false
        }
        do {
            let env = try ORTEnv(loggingLevel: .warning)
            self.env = env
            session = try ORTSession(env: env, modelPath: model.path, sessionOptions: nil)
            dbg("voiceid: loaded \(model.lastPathComponent)")
            return true
        } catch {
            dbg("voiceid: load failed: \(error)")
            return false
        }
    }

    // MARK: - Embedding

    /// 192-dim L2-normalised embedding for int16-range mono 16 kHz samples.
    /// Needs about a second of speech to mean anything.
    func embed(_ samples: [Float]) -> [Float]? {
        guard isAvailable, let session else { return nil }
        let feats = Fbank.features(samples)
        guard feats.count >= 30 else { return nil }   // < 0.3 s carries nothing
        let flat = feats.flatMap { $0 }
        do {
            let data = NSMutableData(bytes: flat, length: flat.count * 4)
            let value = try ORTValue(
                tensorData: data, elementType: .float,
                shape: [1, NSNumber(value: feats.count), NSNumber(value: Fbank.melBins)])
            let inName = try session.inputNames()[0]
            let outName = try session.outputNames()[0]
            let out = try session.run(withInputs: [inName: value],
                                      outputNames: [outName], runOptions: nil)
            guard let tensor = out[outName] else { return nil }
            let raw = try tensor.tensorData() as Data
            var vec = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            normalise(&vec)
            return vec
        } catch {
            dbg("voiceid: inference failed: \(error)")
            return nil
        }
    }

    private func normalise(_ v: inout [Float]) {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return }
        for i in v.indices { v[i] /= norm }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    // MARK: - Enrolment

    /// Averages clips into one voiceprint. Re-enrolling replaces rather than
    /// blends — children's voices drift, and a stale half is worse than none.
    @discardableResult
    func enrol(name: String, clips: [[Float]]) -> VoiceProfile? {
        let vectors = clips.compactMap { embed($0) }
        guard !vectors.isEmpty else { return nil }
        var mean = [Float](repeating: 0, count: vectors[0].count)
        for v in vectors {
            for i in v.indices { mean[i] += v[i] }
        }
        for i in mean.indices { mean[i] /= Float(vectors.count) }
        normalise(&mean)
        let profile = VoiceProfile(name: name, embedding: mean,
                                   clips: vectors.count, updated: Date())
        profiles.removeAll { $0.name.lowercased() == name.lowercased() }
        profiles.append(profile)
        saveProfiles()
        return profile
    }

    func forget(name: String) {
        profiles.removeAll { $0.name.lowercased() == name.lowercased() }
        saveProfiles()
    }

    // MARK: - Identification

    /// Nearest enrolled voice, or nil when nobody is close enough. Also returns
    /// the runner-up margin: a confident match is not just similar, it is
    /// *more* similar than the next candidate, which matters in a house with
    /// twins.
    func identify(_ samples: [Float]) -> (name: String, score: Float, margin: Float)? {
        guard let vec = embed(samples), !profiles.isEmpty else { return nil }
        let ranked = profiles
            .map { ($0.name, Self.cosine(vec, $0.embedding)) }
            .sorted { $0.1 > $1.1 }
        guard let best = ranked.first, best.1 >= Self.threshold else { return nil }
        let margin = ranked.count > 1 ? best.1 - ranked[1].1 : best.1
        return (best.0, best.1, margin)
    }

    /// A hedged description for the model. Never asserts — speaker ID is a
    /// guess from a few seconds of far-field audio, and Neon confidently
    /// calling someone by the wrong name is worse than her not knowing.
    /// When the top two are close (the twins, most likely), it says so rather
    /// than picking.
    func describe(_ samples: [Float]) -> String? {
        guard let vec = embed(samples), !profiles.isEmpty else { return nil }
        let ranked = profiles
            .map { ($0.name, Self.cosine(vec, $0.embedding)) }
            .sorted { $0.1 > $1.1 }
        guard let best = ranked.first, best.1 >= Self.threshold else {
            return "doesn't sound like anyone you know"
        }
        if ranked.count > 1, best.1 - ranked[1].1 < 0.06 {
            return "sounds like \(best.0) or \(ranked[1].0) — too close to tell"
        }
        return "sounds like \(best.0)"
    }

    // MARK: - Persistence

    private func saveProfiles() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(profiles) else { return }
        try? data.write(to: Self.profilePath)
    }

    private func loadProfiles() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: Self.profilePath),
              let stored = try? dec.decode([VoiceProfile].self, from: data) else { return }
        profiles = stored
    }
}

// MARK: - Enrolment from the live microphone

extension VoiceID {
    /// `NEON_VOICEID_RECORD=Sam` — capture straight from Neon's own mic and
    /// enrol. Recording through the real microphone, at the distance people
    /// actually stand, matters more than clip length: an embedding built from
    /// a phone held to the mouth will not match the far-field, echo-cancelled
    /// audio this thing hears all day.
    static func recordAndEnrol(name: String, seconds: TimeInterval = 12) {
        let id = VoiceID.shared
        guard id.isAvailable else {
            print("no model in ~/.config/neon/voiceid/ — see docs/voices.md"); return
        }
        let hub = AudioHub.shared
        hub.startIfNeeded()
        AudioRing.shared.start()
        guard hub.tapFormat != nil else { print("microphone unavailable"); return }

        print("\nRecording \(Int(seconds))s for \(name).")
        print("Stand where you normally stand and talk naturally — read this, or")
        print("just describe your day. Starting in 3…")
        Thread.sleep(forTimeInterval: 1); print("2…")
        Thread.sleep(forTimeInterval: 1); print("1…")
        Thread.sleep(forTimeInterval: 1); print("go.")

        let start = Date()
        let deadline = start.addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let left = Int(deadline.timeIntervalSinceNow) + 1
            print("  \(left)s ", terminator: "")
            fflush(stdout)
        }
        print("\ndone.")

        let pcm = AudioRing.shared.audio(since: start, cap: seconds + 2)
        let samples: [Float] = pcm.withUnsafeBytes {
            $0.bindMemory(to: Int16.self).map { Float($0) }
        }
        guard samples.count > 16000 else { print("heard almost nothing — try again"); return }
        // Enrol from thirds as separate clips: averaging several embeddings is
        // steadier than one long one, and it costs nothing here.
        let third = samples.count / 3
        let clips = [Array(samples[0..<third]),
                     Array(samples[third..<(2 * third)]),
                     Array(samples[(2 * third)...])]
        guard let profile = id.enrol(name: name, clips: clips) else {
            print("could not build a voiceprint from that audio"); return
        }
        print("enrolled \(profile.name) (\(profile.clips) segments, \(samples.count / 16000)s)")
        if id.profiles.count > 1 {
            print("\nsimilarity to the others — lower is better:")
            for other in id.profiles where other.name != profile.name {
                print(String(format: "  %-10@ %+.3f", other.name as NSString,
                             cosine(profile.embedding, other.embedding)))
            }
        }
    }
}

// MARK: - Offline separability check

extension VoiceID {
    /// Scores every WAV in a directory against every enrolled voice and prints
    /// the matrix. The number that matters is not "did it pick the right
    /// person" but how far ahead the right person is: a 0.02 margin is a coin
    /// flip in a noisier room.
    static func voiceMatrix(dir: String) {
        let id = VoiceID.shared
        guard id.isAvailable else { print("no model in ~/.config/neon/voiceid/"); return }
        guard !id.profiles.isEmpty else { print("no enrolled voices"); return }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".wav") }.sorted()
        guard !files.isEmpty else { print("no .wav files in \(dir)"); return }

        let names = id.profiles.map(\.name)
        print("threshold \(String(format: "%.2f", threshold))   clip → " + names.joined(separator: "  "))
        var correct = 0, total = 0, margins: [Float] = []
        for file in files {
            guard let samples = WavFile.samples(at: "\(dir)/\(file)"),
                  let vec = id.embed(samples) else { print("  \(file): unreadable"); continue }
            let scores = id.profiles.map { (p: VoiceProfile) in (p.name, cosine(vec, p.embedding)) }
            let ranked = scores.sorted { $0.1 > $1.1 }
            let cells = scores.map { String(format: "%+.3f", $0.1) }.joined(separator: "  ")
            // Convention for the harness: a clip named nick-3.wav belongs to nick.
            let truth = file.split(separator: "-").first.map(String.init)?.lowercased()
            let picked = ranked[0].1 >= threshold ? ranked[0].0 : "(unknown)"
            let hit = truth != nil && picked.lowercased() == truth
            if truth != nil {
                total += 1
                if hit { correct += 1 }
            }
            let margin = ranked.count > 1 ? ranked[0].1 - ranked[1].1 : ranked[0].1
            margins.append(margin)
            print(String(format: "  %-22@ %@   → %@ %@ (margin %.3f)",
                         file as NSString, cells, picked, hit ? "✓" : (truth == nil ? " " : "✗"),
                         margin))
        }
        if total > 0 {
            let avgMargin = margins.reduce(0, +) / Float(margins.count)
            print(String(format: "\n%d/%d correct, mean margin %.3f, worst %.3f",
                         correct, total, avgMargin, margins.min() ?? 0))
        }
    }
}

// MARK: - WAV helper (enrolment and the offline harness both read files)

enum WavFile {
    /// 16 kHz mono int16 WAV → int16-range floats, which is what every stage
    /// of this pipeline speaks.
    static func samples(at path: String) -> [Float]? {
        guard let data = FileManager.default.contents(atPath: path),
              let range = data.range(of: Data("data".utf8)) else { return nil }
        let start = data.index(range.upperBound, offsetBy: 4)
        guard start < data.endIndex else { return nil }
        let pcm = data.subdata(in: start..<data.endIndex)
        return pcm.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { Float($0) } }
    }
}
