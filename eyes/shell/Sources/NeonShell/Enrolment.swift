import Foundation

// One sitting per person: look at the camera, then talk. Both modalities land
// in the same record, and the report at the end is per-modality — which is the
// point of doing them together. Whether Sam and Alex separate by face, by
// voice, or only by both at once is a question you can only answer by seeing
// the two numbers side by side.
//
// Enrolment images are never written to disk. The embeddings are computed from
// frames in memory and the frames are dropped; there is no reason to keep a
// library of photographs of somebody's children.
enum Enrolment {
    static func run(name: String, faceSeconds: TimeInterval = 8,
                    voiceSeconds: TimeInterval = 12) {
        print("\nEnrolling \(name).\n")

        let faces = enrolFaces(name: name, seconds: faceSeconds)
        let voice = enrolVoice(name: name, seconds: voiceSeconds)

        guard faces || voice else {
            print("\nNothing enrolled — no camera and no microphone.")
            return
        }
        report(name: name)
    }

    /// `NEON_FACEID_TEST=1` — no enrolment, just proof the chain works.
    /// Frame-to-frame similarity for one person is the real check: detection,
    /// landmarks, alignment and embedding all have to be right for the same
    /// face to land in the same place twice. Broken alignment still produces
    /// 512 confident-looking numbers, but they scatter.
    static func faceCheck(seconds: TimeInterval = 6) {
        guard FaceID.shared.isAvailable else {
            print("no model in ~/.config/neon/faceid/"); return
        }
        print("Look at the camera for \(Int(seconds))s…")
        let camera = CameraFeed()
        var found: [(Float, [Float])] = []
        var frames = 0
        let lock = NSLock()
        camera.onFrame = { b64 in
            lock.lock(); frames += 1; lock.unlock()
            guard let image = FaceID.image(fromBase64JPEG: b64),
                  let face = FaceID.shared.faces(in: image).max(by: { $0.area < $1.area })
            else { return }
            lock.lock(); found.append((face.quality, face.embedding)); lock.unlock()
        }
        camera.start()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        camera.stop()

        print("\nframes: \(frames), faces detected: \(found.count)")
        guard found.count >= 2 else {
            print("not enough faces — more light, or sit closer.")
            return
        }
        let q = found.map(\.0)
        print(String(format: "capture quality: min %.2f mean %.2f max %.2f",
                     q.min()!, q.reduce(0, +) / Float(q.count), q.max()!))
        var sims: [Float] = []
        for i in 0..<found.count {
            for j in (i + 1)..<found.count {
                sims.append(PersonStore.cosine(found[i].1, found[j].1))
            }
        }
        let mean = sims.reduce(0, +) / Float(sims.count)
        print(String(format: "same-face similarity across frames: min %.3f mean %.3f max %.3f",
                     sims.min()!, mean, sims.max()!))
        print(mean > 0.75
              ? "\nHealthy — the same face lands in the same place. Alignment is right."
              : "\nToo scattered for one person; alignment or landmarks are off.")
    }

    // MARK: - Faces

    private static func enrolFaces(name: String, seconds: TimeInterval) -> Bool {
        guard FaceID.shared.isAvailable else {
            print("skipping faces: no model in ~/.config/neon/faceid/")
            return false
        }
        print("Faces: look at the camera for \(Int(seconds))s. Move your head a")
        print("little — a few angles beat one perfect shot. Starting…")

        let camera = CameraFeed()
        var best: [(quality: Float, embedding: [Float])] = []
        let lock = NSLock()
        camera.onFrame = { b64 in
            guard let image = FaceID.image(fromBase64JPEG: b64) else { return }
            // Largest face in frame: whoever is being enrolled is nearest.
            guard let face = FaceID.shared.faces(in: image)
                .max(by: { $0.area < $1.area }) else { return }
            lock.lock()
            best.append((face.quality, face.embedding))
            lock.unlock()
        }
        camera.start()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            lock.lock(); let n = best.count; lock.unlock()
            print("  \(Int(deadline.timeIntervalSinceNow) + 1)s — \(n) frames  ", terminator: "")
            fflush(stdout)
        }
        camera.stop()
        print()

        lock.lock()
        // Keep the best handful by Vision's own capture-quality score: blinks
        // and motion blur baked into an identity cost accuracy for months.
        let keep = Array(best.sorted { $0.quality > $1.quality }.prefix(6))
        lock.unlock()
        guard keep.count >= 2 else {
            print("faces: only \(keep.count) usable frame(s) — no face enrolled.")
            return false
        }
        PersonStore.shared.setFaces(keep.map(\.embedding), for: name)
        let q = keep.map { String(format: "%.2f", $0.quality) }.joined(separator: " ")
        print("faces: kept \(keep.count) of \(best.count) frames (quality \(q))")
        return true
    }

    // MARK: - Voice

    private static func enrolVoice(name: String, seconds: TimeInterval) -> Bool {
        guard VoiceID.shared.isAvailable else {
            print("skipping voice: no model in ~/.config/neon/voiceid/")
            return false
        }
        let hub = AudioHub.shared
        hub.startIfNeeded()
        AudioRing.shared.start()
        guard hub.tapFormat != nil else {
            print("skipping voice: microphone unavailable")
            return false
        }
        print("\nVoice: talk naturally for \(Int(seconds))s, standing where you")
        print("normally stand. Read this, describe your day, anything.")
        for n in [3, 2, 1] { print("  \(n)…"); Thread.sleep(forTimeInterval: 1) }
        print("  go.")

        let start = Date()
        let deadline = start.addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            print("  \(Int(deadline.timeIntervalSinceNow) + 1)s  ", terminator: "")
            fflush(stdout)
        }
        print()

        let pcm = AudioRing.shared.audio(since: start, cap: seconds + 2)
        let samples: [Float] = pcm.withUnsafeBytes {
            $0.bindMemory(to: Int16.self).map { Float($0) }
        }
        guard samples.count > 16000 else {
            print("voice: heard almost nothing — not enrolled.")
            return false
        }
        // Thirds averaged: steadier than one long window, free to compute.
        let third = samples.count / 3
        let clips = [Array(samples[0..<third]),
                     Array(samples[third..<(2 * third)]),
                     Array(samples[(2 * third)...])]
        let vectors = clips.compactMap { VoiceID.shared.embed($0) }
        guard !vectors.isEmpty else {
            print("voice: couldn't build a voiceprint from that audio.")
            return false
        }
        var mean = [Float](repeating: 0, count: vectors[0].count)
        for v in vectors { for i in v.indices { mean[i] += v[i] } }
        let norm = sqrt(mean.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { for i in mean.indices { mean[i] /= norm } }
        PersonStore.shared.setVoice(mean, for: name)
        print("voice: enrolled from \(vectors.count) segments (\(samples.count / 16000)s)")
        return true
    }

    // MARK: - Report

    /// Similarity against everyone else, per modality. Two people who are hard
    /// to tell apart show up here, before it matters in the kitchen.
    private static func report(name: String) {
        let store = PersonStore.shared
        guard let me = store.person(named: name) else { return }
        print("\n\(name): \(me.modalities)")
        let others = store.people.filter { $0.name.lowercased() != name.lowercased() }
        guard !others.isEmpty else { return }
        print("\nsimilarity to the others — lower is better:")
        print("  \(pad("who", 12))\(pad("voice", 9))face")
        for other in others {
            var voice = "—", face = "—"
            if let a = me.voice, let b = other.voice {
                voice = String(format: "%+.3f", PersonStore.cosine(a, b))
            }
            if !me.faces.isEmpty, !other.faces.isEmpty {
                let best = me.faces.flatMap { m in other.faces.map { PersonStore.cosine(m, $0) } }
                    .max() ?? 0
                face = String(format: "%+.3f", best)
            }
            print("  \(pad(other.name, 12))\(pad(voice, 9))\(face)")
        }
        print("\nvoice matches above \(String(format: "%.2f", VoiceID.threshold)), "
            + "faces above \(String(format: "%.2f", FaceID.threshold)) — "
            + "a pair scoring near those needs both signals to be sure.")
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s + " " : s + String(repeating: " ", count: n - s.count)
    }
}
