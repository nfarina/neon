import Foundation

// The people Neon knows, and how she recognizes them.
//
// One record per person holding both modalities, because they answer the same
// question and fail in different conditions: voice works in the dark and
// across the room, faces work when someone is silent or when two voices are
// too alike. Identical twins are the case that motivated the second signal —
// Sam and Alex may be hard to tell apart by voice and easy by face.
//
// Biometric data about two children. It lives in ~/.config/neon/people.json,
// outside the repo, and the enrollment *images* are discarded once embeddings
// are computed — there is no reason to keep a face library on disk.
struct Person: Codable {
    var name: String
    /// 192-dim CAM++ speaker embedding, L2-normalized.
    var voice: [Float]?
    /// 512-dim ArcFace embeddings, one per enrollment frame kept.
    var faces: [[Float]]
    var voiceUpdated: Date?
    var facesUpdated: Date?

    var modalities: String {
        var m: [String] = []
        if voice != nil { m.append("voice") }
        if !faces.isEmpty { m.append("\(faces.count) faces") }
        return m.isEmpty ? "nothing enrolled" : m.joined(separator: " + ")
    }
}

final class PersonStore {
    static let shared = PersonStore()

    private(set) var people: [Person] = []
    private let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/neon/people.json")
    private let legacyVoices = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/neon/voices.json")

    private init() { load() }

    func person(named name: String) -> Person? {
        people.first { $0.name.lowercased() == name.lowercased() }
    }

    func setVoice(_ embedding: [Float], for name: String) {
        update(name) { $0.voice = embedding; $0.voiceUpdated = Date() }
    }

    /// Replaces rather than appends: faces and voices both drift (children
    /// fastest), and half a stale identity is worse than none.
    func setFaces(_ embeddings: [[Float]], for name: String) {
        update(name) { $0.faces = embeddings; $0.facesUpdated = Date() }
    }

    func forget(name: String) {
        people.removeAll { $0.name.lowercased() == name.lowercased() }
        save()
    }

    private func update(_ name: String, _ change: (inout Person) -> Void) {
        if let i = people.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            change(&people[i])
        } else {
            var p = Person(name: name, voice: nil, faces: [])
            change(&p)
            people.append(p)
        }
        save()
    }

    // MARK: - Matching

    /// Best match by cosine similarity, with the runner-up margin — a
    /// confident answer is not merely similar, it is *more* similar than the
    /// next candidate, which is the whole question in a house with twins.
    struct Match {
        let name: String
        let score: Float
        let margin: Float
        /// True when the top two are close enough that picking one is a guess.
        var ambiguous: Bool { margin < 0.06 }
        let runnerUp: String?
    }

    func matchVoice(_ embedding: [Float], threshold: Float) -> Match? {
        let scored = people.compactMap { p -> (String, Float)? in
            guard let v = p.voice else { return nil }
            return (p.name, PersonStore.cosine(embedding, v))
        }
        return best(scored, threshold: threshold)
    }

    /// Faces score against the *best* enrolled frame for each person: pose and
    /// lighting vary far more than a face does, so the nearest frame is a
    /// better answer than the average of several.
    func matchFace(_ embedding: [Float], threshold: Float) -> Match? {
        let scored = people.compactMap { p -> (String, Float)? in
            guard !p.faces.isEmpty else { return nil }
            let best = p.faces.map { PersonStore.cosine(embedding, $0) }.max() ?? 0
            return (p.name, best)
        }
        return best(scored, threshold: threshold)
    }

    private func best(_ scored: [(String, Float)], threshold: Float) -> Match? {
        let ranked = scored.sorted { $0.1 > $1.1 }
        guard let top = ranked.first, top.1 >= threshold else { return nil }
        let margin = ranked.count > 1 ? top.1 - ranked[1].1 : top.1
        return Match(name: top.0, score: top.1, margin: margin,
                     runnerUp: ranked.count > 1 ? ranked[1].0 : nil)
    }

    /// The hedge Neon hears. Never an assertion: this is a guess from a few
    /// seconds of far-field audio or one camera frame, and being confidently
    /// wrong about a name is worse than not knowing.
    static func phrase(_ match: Match?, verb: String) -> String {
        guard let match else { return "doesn't \(verb) like anyone you know" }
        if match.ambiguous, let other = match.runnerUp {
            return "\(verb)s like \(match.name) or \(other) — too close to tell"
        }
        return "\(verb)s like \(match.name)"
    }

    /// The same judgment with its numbers, for the event log and overlay —
    /// "sounds like Nick" is what she gets, this is what you get when you want
    /// to know whether to trust it.
    static func detail(_ match: Match?) -> String {
        guard let match else { return "no match" }
        return String(format: "%@ %.2f, margin %.2f%@", match.name, match.score,
                      match.margin, match.ambiguous ? " (ambiguous)" : "")
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    // MARK: - Persistence

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(people) else { return }
        try? data.write(to: path)
    }

    private func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: path),
           let stored = try? dec.decode([Person].self, from: data) {
            people = stored
            return
        }
        // Migrate voices.json from before faces existed.
        struct LegacyVoice: Codable {
            var name: String; var embedding: [Float]; var clips: Int; var updated: Date
        }
        if let data = try? Data(contentsOf: legacyVoices),
           let old = try? dec.decode([LegacyVoice].self, from: data) {
            people = old.map {
                Person(name: $0.name, voice: $0.embedding, faces: [],
                       voiceUpdated: $0.updated, facesUpdated: nil)
            }
            save()
            dbg("people: migrated \(people.count) voice profile(s) from voices.json")
        }
    }
}
