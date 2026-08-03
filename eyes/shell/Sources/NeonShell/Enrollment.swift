import Foundation

// One sitting per person: look at the camera, then talk. Both modalities land
// in the same record, and the report at the end is per-modality — which is the
// point of doing them together. Whether Sam and Alex separate by face, by
// voice, or only by both at once is a question you can only answer by seeing
// the two numbers side by side.
//
// Enrollment images are never written to disk. The embeddings are computed from
// frames in memory and the frames are dropped; there is no reason to keep a
// library of photographs of somebody's children. The settings panel does show a
// live preview while the camera runs — that frame goes to the screen and
// nowhere else.
//
// The sitting is driven by timers rather than a blocking loop, because it has
// two callers now: the terminal (NEON_ENROL=Sam) and the settings panel,
// where blocking the main thread would freeze the very UI that is showing the
// countdown. The terminal wrapper pumps the run loop and prints; the panel
// subscribes to the same callbacks and draws them.

final class EnrollmentSession {
    enum Phase: String {
        case faces, gettingReady, voice, finished, failed
    }

    struct Progress {
        let phase: Phase
        /// What the person being enrolled should be doing right now.
        let message: String
        /// Seconds left in this phase, for a countdown.
        let remaining: Int
        /// Frames or seconds captured so far — evidence it is working.
        let captured: Int
    }

    var onProgress: (Progress) -> Void = { _ in }
    /// Base64 JPEG from the camera, for a live preview. Only fires during the
    /// face phase, and only if somebody is listening.
    var onPreview: (String) -> Void = { _ in }
    /// (succeeded, report). The report is the similarity table — the thing
    /// worth reading, whichever front end asked.
    var onFinished: (Bool, String) -> Void = { _, _ in }

    private(set) var isRunning = false

    private var name = ""
    private var faceSeconds: TimeInterval = 8
    private var voiceSeconds: TimeInterval = 12

    private var camera: CameraFeed?
    private var ticker: Timer?
    private var phaseEnds = Date()
    private let lock = NSLock()
    private var faceFrames: [(quality: Float, embedding: [Float])] = []
    private var enrolledFaces = false
    private var enrolledVoice = false
    private var voiceStart = Date()
    private var wantsPreview = false

    func start(name: String, faceSeconds: TimeInterval = 8, voiceSeconds: TimeInterval = 12,
               wantsPreview: Bool = false) {
        guard !isRunning else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onFinished(false, "No name given.")
            return
        }
        isRunning = true
        self.name = trimmed
        self.faceSeconds = faceSeconds
        self.voiceSeconds = voiceSeconds
        self.wantsPreview = wantsPreview
        faceFrames = []
        enrolledFaces = false
        enrolledVoice = false
        beginFaces()
    }

    func cancel() {
        guard isRunning else { return }
        stopEverything()
        isRunning = false
        onProgress(Progress(phase: .failed, message: "Cancelled.", remaining: 0, captured: 0))
        onFinished(false, "Cancelled — nothing was saved.")
    }

    private func stopEverything() {
        ticker?.invalidate()
        ticker = nil
        camera?.stop()
        camera = nil
    }

    // MARK: - Faces

    private func beginFaces() {
        guard FaceID.shared.isAvailable else {
            beginGettingReady(skippedFaces: true)
            return
        }
        let cam = CameraFeed()
        // A pool worth choosing from — enrollment runs at 4 fps rather than
        // the session's 1 fps, since choosing six frames out of five is not a
        // choice, and these frames never leave the machine.
        cam.interval = 0.25
        cam.onFrame = { [weak self] b64 in
            guard let self else { return }
            if self.wantsPreview { DispatchQueue.main.async { self.onPreview(b64) } }
            guard let image = FaceID.image(fromBase64JPEG: b64) else { return }
            // Largest face in frame: whoever is being enrolled is nearest.
            guard let face = FaceID.shared.faces(in: image).max(by: { $0.area < $1.area })
            else { return }
            self.lock.lock()
            self.faceFrames.append((face.quality, face.embedding))
            self.lock.unlock()
        }
        camera = cam
        cam.start()
        runPhase(.faces, seconds: faceSeconds,
                 message: "Look at the camera. Move your head a little — a few angles beat one perfect shot.") {
            self.finishFaces()
        }
    }

    private func finishFaces() {
        camera?.stop()
        camera = nil
        lock.lock()
        // Keep the best handful by Vision's own capture-quality score: blinks
        // and motion blur baked into an identity cost accuracy for months.
        let keep = Array(faceFrames.sorted { $0.quality > $1.quality }.prefix(6))
        let seen = faceFrames.count
        lock.unlock()

        if keep.count >= 2 {
            PersonStore.shared.setFaces(keep.map(\.embedding), for: name)
            enrolledFaces = true
            dbg("enrol: faces kept \(keep.count) of \(seen) frames")
        } else {
            dbg("enrol: only \(keep.count) usable face frame(s) — no face enrolled")
        }
        beginGettingReady(skippedFaces: false)
    }

    // MARK: - Voice

    /// A beat between the two halves. Without it the voice recording starts
    /// while the person is still sat forward looking at the lens, and the first
    /// seconds of a voiceprint are them saying "oh — now?".
    private func beginGettingReady(skippedFaces: Bool) {
        guard VoiceID.shared.isAvailable else {
            finish()
            return
        }
        let hub = AudioHub.shared
        hub.startIfNeeded()
        AudioRing.shared.start()
        guard hub.tapFormat != nil else {
            dbg("enrol: microphone unavailable — no voice enrolled")
            finish()
            return
        }
        runPhase(.gettingReady, seconds: 3,
                 message: "Now your voice. Stand where you normally stand.") {
            self.beginVoice()
        }
    }

    private func beginVoice() {
        voiceStart = Date()
        runPhase(.voice, seconds: voiceSeconds,
                 message: "Talk naturally — read this out, describe your day, anything.") {
            self.finishVoice()
        }
    }

    private func finishVoice() {
        let pcm = AudioRing.shared.audio(since: voiceStart, cap: voiceSeconds + 2)
        let samples: [Float] = pcm.withUnsafeBytes {
            $0.bindMemory(to: Int16.self).map { Float($0) }
        }
        guard samples.count > 16000 else {
            dbg("enrol: heard almost nothing — no voice enrolled")
            finish()
            return
        }
        // Thirds averaged: steadier than one long window, free to compute.
        let third = samples.count / 3
        let clips = [Array(samples[0..<third]),
                     Array(samples[third..<(2 * third)]),
                     Array(samples[(2 * third)...])]
        let vectors = clips.compactMap { VoiceID.shared.embed($0) }
        guard !vectors.isEmpty else {
            dbg("enrol: couldn't build a voiceprint from that audio")
            finish()
            return
        }
        var mean = [Float](repeating: 0, count: vectors[0].count)
        for v in vectors { for i in v.indices { mean[i] += v[i] } }
        let norm = sqrt(mean.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { for i in mean.indices { mean[i] /= norm } }
        PersonStore.shared.setVoice(mean, for: name)
        enrolledVoice = true
        dbg("enrol: voice from \(vectors.count) segments (\(samples.count / 16000)s)")
        finish()
    }

    // MARK: - Finishing

    private func finish() {
        stopEverything()
        isRunning = false
        guard enrolledFaces || enrolledVoice else {
            let why = FaceID.shared.isAvailable || VoiceID.shared.isAvailable
                ? "Nothing usable was captured — try again with more light, or closer to the mic."
                : "No recognition models installed (see docs/people.md)."
            onProgress(Progress(phase: .failed, message: why, remaining: 0, captured: 0))
            onFinished(false, why)
            return
        }
        let report = Enrollment.report(name: name)
        onProgress(Progress(phase: .finished, message: "Done.", remaining: 0, captured: 0))
        onFinished(true, report)
    }

    // MARK: - Phase plumbing

    private func runPhase(_ phase: Phase, seconds: TimeInterval, message: String,
                          then: @escaping () -> Void) {
        ticker?.invalidate()
        phaseEnds = Date().addingTimeInterval(seconds)
        emit(phase, message)
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            if Date() >= self.phaseEnds {
                self.ticker?.invalidate()
                self.ticker = nil
                then()
            } else {
                self.emit(phase, message)
            }
        }
    }

    private func emit(_ phase: Phase, _ message: String) {
        lock.lock()
        let captured = phase == .faces ? faceFrames.count
            : phase == .voice ? Int(Date().timeIntervalSince(voiceStart)) : 0
        lock.unlock()
        onProgress(Progress(phase: phase, message: message,
                            remaining: max(0, Int(phaseEnds.timeIntervalSinceNow.rounded(.up))),
                            captured: captured))
    }
}

// MARK: - Terminal front end and the report

enum Enrollment {

    /// `NEON_ENROL=Sam` — the original path, still the one to use when
    /// something is wrong and you want the numbers in a scrollback buffer.
    static func run(name: String, faceSeconds: TimeInterval = 8,
                    voiceSeconds: TimeInterval = 12) {
        print("\nEnrolling \(name).\n")
        let session = EnrollmentSession()
        var lastPhase: EnrollmentSession.Phase?
        var done = false

        session.onProgress = { p in
            if p.phase != lastPhase {
                lastPhase = p.phase
                print("\n\(p.message)")
            }
            guard p.phase == .faces || p.phase == .voice || p.phase == .gettingReady else { return }
            let detail = p.phase == .faces ? " — \(p.captured) frames" : ""
            print("  \(p.remaining)s\(detail)   ", terminator: "")
            fflush(stdout)
        }
        session.onFinished = { ok, report in
            print("\n\n\(report)")
            if !ok { print("") }
            done = true
        }
        session.start(name: name, faceSeconds: faceSeconds, voiceSeconds: voiceSeconds)
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    }

    /// `NEON_FACEID_TEST=1` — no enrollment, just proof the chain works.
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
        camera.interval = 0.25
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

    /// Similarity against everyone else, per modality. Two people who are hard
    /// to tell apart show up here, before it matters in the kitchen. Returned
    /// as text rather than printed, because both front ends want to show it.
    static func report(name: String) -> String {
        let store = PersonStore.shared
        guard let me = store.person(named: name) else { return "\(name): nothing enrolled." }
        var lines = ["\(name): \(me.modalities)"]
        let others = store.people.filter { $0.name.lowercased() != name.lowercased() }
        guard !others.isEmpty else { return lines.joined(separator: "\n") }

        lines.append("")
        lines.append("similarity to the others — lower is better:")
        lines.append("  \(pad("who", 12))\(pad("voice", 9))face")
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
            lines.append("  \(pad(other.name, 12))\(pad(voice, 9))\(face)")
        }
        lines.append("")
        lines.append("voice matches above \(String(format: "%.2f", VoiceID.threshold)), "
            + "faces above \(String(format: "%.2f", FaceID.threshold)) — "
            + "a pair scoring near those needs both signals to be sure.")
        return lines.joined(separator: "\n")
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s + " " : s + String(repeating: " ", count: n - s.count)
    }
}
