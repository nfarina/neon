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
// Enrolled voices live in PersonStore (~/.config/neon/people.json) alongside
// faces — one record per person, since both answer the same question. This
// class owns the model and the embedding, not the identities.
final class VoiceID {
    static let shared = VoiceID()

    private var env: ORTEnv?
    private var session: ORTSession?

    /// Enrolled voices live in PersonStore now — one record per person, voice
    /// and face together, since they answer the same question.
    var profiles: [Person] { PersonStore.shared.people.filter { $0.voice != nil } }

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
    private init() {}

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

    /// 192-dim L2-normalized embedding for int16-range mono 16 kHz samples.
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
            normalize(&vec)
            return vec
        } catch {
            dbg("voiceid: inference failed: \(error)")
            return nil
        }
    }

    private func normalize(_ v: inout [Float]) {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return }
        for i in v.indices { v[i] /= norm }
    }

    // MARK: - Identification

    /// Nearest enrolled voice, or nil when nobody is close enough. Also returns
    /// the runner-up margin: a confident match is not just similar, it is
    /// *more* similar than the next candidate, which matters in a house with
    /// twins.
    func identify(_ samples: [Float]) -> PersonStore.Match? {
        guard let vec = embed(samples) else { return nil }
        return PersonStore.shared.matchVoice(vec, threshold: Self.threshold)
    }

    /// A hedged description for the model. Never asserts — speaker ID is a
    /// guess from a few seconds of far-field audio, and Neon confidently
    /// calling someone by the wrong name is worse than her not knowing.
    /// When the top two are close (the twins, most likely), it says so rather
    /// than picking.
    /// `phrase` is nil when nobody matches; `detail` always carries the
    /// numbers, since "no match" is exactly what you want to see in the log.
    func describe(_ samples: [Float]) -> (phrase: String?, detail: String)? {
        guard !profiles.isEmpty, let vec = embed(samples) else { return nil }
        let match = PersonStore.shared.matchVoice(vec, threshold: Self.threshold)
        return (PersonStore.phrase(match, verb: "sound"), PersonStore.detail(match))
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
            let scores = id.profiles.compactMap { p -> (String, Float)? in
                guard let v = p.voice else { return nil }
                return (p.name, PersonStore.cosine(vec, v))
            }
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

// MARK: - WAV helper (enrollment and the offline harness both read files)

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
