import Foundation

// Durable memory: facts Neon decides are worth keeping, separate from the
// rolling transcript.
//
// She already had two kinds of memory and neither did this job. The household
// profile is hand-written by Nick and she can't add to it. The conversation
// log replays the last ~2.5k characters of raw transcript, so "Alex's lesson
// moved to Thursdays" survives about a day and then scrolls away forever.
// This is the third kind: small, deliberate, written by her, kept indefinitely.
//
// One JSONL line per memory so it stays greppable, hand-editable, and trivial
// to append to. Search is keyword scoring rather than embeddings — no model
// call, no network, and at kitchen scale (hundreds of memories, not millions)
// the difference isn't worth a dependency.
struct Memory: Codable {
    var id: String
    var text: String
    var at: Date
    var uses: Int = 0
    var lastUsed: Date?
    /// "neon" when she wrote it live, "dream" when compaction did.
    var source: String = "neon"
}

final class MemoryStore {
    static let shared = MemoryStore()

    private(set) var memories: [Memory] = []
    private let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/neon/memories.jsonl")
    private let iso = ISO8601DateFormatter()

    private var loadedStamp: Date?

    private init() { load() }

    /// Pick up a memories.jsonl rewritten behind our back — the nightly
    /// "dreaming" routine consolidates the file from outside this process, and
    /// without this the in-RAM copy would silently overwrite its work on the
    /// next save. Called at the start of every session, which is cheap: the
    /// file is a few kilobytes and sessions are minutes apart.
    func reloadIfChanged() {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate])
            .flatMap { $0 as? Date }
        guard let stamp, stamp != loadedStamp else { return }
        let before = memories.count
        load()
        dbg("memory: reloaded from disk (\(before) → \(memories.count))")
    }

    // MARK: - Writing

    /// Returns nil if this is effectively a duplicate — repeating a fact
    /// should sharpen the existing memory, not stack another copy of it.
    @discardableResult
    func remember(_ text: String, source: String = "neon") -> Memory? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 2 else { return nil }
        if let i = memories.firstIndex(where: { similarity($0.text, clean) > 0.6 }) {
            // Keep the longer phrasing: it usually carries the newer detail.
            if clean.count > memories[i].text.count { memories[i].text = clean }
            memories[i].at = Date()
            save()
            return nil
        }
        let memory = Memory(id: "m\(nextNumber())", text: clean, at: Date(), source: source)
        memories.append(memory)
        save()
        return memory
    }

    func forget(id: String) -> Bool {
        let before = memories.count
        memories.removeAll { $0.id == id }
        if memories.count != before { save(); return true }
        return false
    }

    /// Wholesale replacement, for the dreaming pass.
    func replaceAll(_ new: [Memory]) {
        memories = new
        save()
    }

    // MARK: - Reading

    /// Best matches for a query, most relevant first.
    func search(_ query: String, limit: Int = 5) -> [Memory] {
        let terms = tokens(query)
        guard !terms.isEmpty else { return [] }
        let scored = memories.map { (m: Memory) -> (Memory, Double) in
            (m, score(m, terms: terms))
        }.filter { $0.1 > 0 }
         .sorted { $0.1 > $1.1 }
        let hits = Array(scored.prefix(limit)).map(\.0)
        // Remember what got used: it's the only signal we have about which
        // memories earn their place, and dreaming reads it.
        for hit in hits {
            if let i = memories.firstIndex(where: { $0.id == hit.id }) {
                memories[i].uses += 1
                memories[i].lastUsed = Date()
            }
        }
        if !hits.isEmpty { save() }
        return hits
    }

    /// The handful worth putting in front of her at the start of every session,
    /// without being asked. Recent and often-used win.
    func digest(maxChars: Int = 700) -> String? {
        guard !memories.isEmpty else { return nil }
        let ranked = memories.sorted { a, b in
            salience(a) > salience(b)
        }
        var lines: [String] = []
        var used = 0
        for m in ranked {
            let line = "- \(m.text)"
            if used + line.count > maxChars { break }
            lines.append(line)
            used += line.count
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func salience(_ m: Memory) -> Double {
        let ageDays = Date().timeIntervalSince(m.at) / 86400
        let recency = 1.0 / (1.0 + ageDays / 30)     // half-weight at a month
        return recency + Double(m.uses) * 0.15
    }

    // MARK: - Scoring

    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "is", "are", "was", "were", "be",
        "to", "of", "in", "on", "at", "for", "with", "my", "our", "i", "we",
        "you", "it", "that", "this", "do", "does", "did", "what", "when",
        "where", "who", "how", "me", "us", "about", "his", "her", "their",
    ]

    private func tokens(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !Self.stopwords.contains($0) }
            // Crude stemming: kitchen text is short, and "lessons" should hit
            // a memory that says "lesson".
            .map { $0.hasSuffix("s") && $0.count > 4 ? String($0.dropLast()) : $0 }
    }

    /// Rare words say more about relevance than common ones, so weight each
    /// term by how few memories contain it.
    private func score(_ m: Memory, terms: [String]) -> Double {
        let memTokens = Set(tokens(m.text))
        guard !memTokens.isEmpty else { return 0 }
        var total = 0.0
        for term in Set(terms) where memTokens.contains(term) {
            let containing = memories.reduce(0) { $0 + (tokens($1.text).contains(term) ? 1 : 0) }
            let idf = log(Double(memories.count + 1) / Double(containing + 1)) + 1
            total += idf
        }
        guard total > 0 else { return 0 }
        return total + salience(m) * 0.3
    }

    private func similarity(_ a: String, _ b: String) -> Double {
        let x = Set(tokens(a)), y = Set(tokens(b))
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count))
    }

    // MARK: - Persistence

    private func nextNumber() -> Int {
        (memories.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let lines = memories.compactMap { m -> String? in
            guard let data = try? enc.encode(m) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true,
                                                          encoding: .utf8)
        loadedStamp = (try? FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate])
            .flatMap { $0 as? Date }
    }

    private func load() {
        loadedStamp = (try? FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate])
            .flatMap { $0 as? Date }
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        memories = text.split(separator: "\n").compactMap { line in
            try? dec.decode(Memory.self, from: Data(line.utf8))
        }
    }
}
