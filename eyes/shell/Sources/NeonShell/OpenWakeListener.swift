import AVFoundation
import OnnxRuntimeBindings

// openWakeWord detection: melspectrogram -> speech embedding -> wake model,
// all tiny ONNX models on CPU, fed 80 ms chunks of 16 kHz audio. Unlike the
// SFSpeech matcher this spots the phrase mid-stream with no silence
// bookkeeping. Models ship in the app bundle from wake/models/ — melspectrogram.onnx and
// embedding_model.onnx are openWakeWord's shared feature extractors; any
// other .onnx file is treated as the wake model (drop in hey_neon.onnx
// later and it just works).
//
// Pipeline constants from openwakeword/utils.py (AudioFeatures):
//   - 1280-sample chunks of raw int16-range floats
//   - mel output transformed x/10 + 2, 32 bins per frame
//   - embeddings over 76-frame windows, stride 8, 96 dims
//   - wake model scores the last 16 embeddings
final class OpenWakeListener {
    var onDetect: (String) -> Void = { _ in }  // wake model name

    /// Name of the wake model actually in use, once loaded — surfaced in the
    /// debug overlay so "which wake path is live?" is answerable at a glance.
    private(set) var modelName: String?
    /// Peak score of the most recent detection, and when it fired.
    private(set) var lastScore: Float = 0
    private(set) var lastDetectAt: Date?

    private let queue = DispatchQueue(label: "neon.oww")
    private var env: ORTEnv?
    private var melModel: ORTSession?
    private var embedModel: ORTSession?
    private var wakeModel: ORTSession?
    private var wakeName = "?"
    private var consumerId: UUID?
    private var converter: AVAudioConverter?
    private let format16k = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    private var samples: [Float] = []        // raw int16-range values
    private var melTail: [Float] = []        // 480-sample lookback across chunks
    private var melFrames: [[Float]] = []    // 32 per frame
    private var windowStart = 0              // next embedding window start
    // Primed with zeros (as openWakeWord does) so scoring starts with the
    // very first real embedding rather than after ~2 s of buffer fill.
    private var embeddings: [[Float]] =
        Array(repeating: [Float](repeating: 0, count: 96), count: 16)
    // The first few scores mix real embeddings with the zero priming — a
    // discontinuity that spikes the wake model on any audio. Skip them.
    private var scoresRun = 0
    private static let warmupScores = 4
    private var lastFire = Date.distantPast
    private var startTimer: Timer?
    /// Detection threshold, tunable without a rebuild
    /// (`NEON_OWW_THRESHOLD=0.5`). Calibrated per model — models differ in how
    /// hot they run — and calibrated *through this pipeline*, not the training
    /// one. Revisit it whenever `wake/models` changes.
    ///
    /// 0.4 for v4 (2026-08-02, layer_size 192). The offline picture argued for
    /// 0.8: `wake/scripts/eval_runtime.py` on 12 held-out recordings put every
    /// true positive at 0.968–0.998 and ordinary speech at ≤0.018. But live in
    /// the kitchen a clear "hey neon" was observed scoring ~0.5 — recorded
    /// clips do not carry the room's reverb, the speaker's distance, or the
    /// AEC-processed mic path, and those cost real score. Trust the room over
    /// the eval set.
    ///
    /// Lowering is close to free because of *what* sits near the boundary. A
    /// 36-utterance negative battery through this pipeline (3 voices, incl.
    /// "the neon sign in the window is broken") topped out at 0.009 for
    /// ordinary speech; the only things scoring high were deliberate
    /// soundalikes — "hey Nia" (0.99) and "hey Neo" (0.83) — and both already
    /// cleared 0.8, so lowering admits no new *kind* of false accept, just more
    /// instances of two confusions we arguably want to wake on anyway ("Neo"
    /// is Neon's old name, "Nia" is already a listed misheard variant).
    /// 0.4 therefore keeps a ~44x margin over real speech while giving the far
    /// end of the kitchen somewhere to land. `wake-scores.log` records what
    /// actually happens; tune from that, not from this comment.
    ///
    /// It then went to 0.2, from that log rather than from any eval: live
    /// wakes turn out to *vary enormously* — three clear utterances in a quiet
    /// room peaked at 0.99, 0.94 and 0.29, the last one silently failing. The
    /// spread, not the average, is what a threshold has to survive, and no
    /// recorded set shows it. 0.2 still sits ~20x over the measured
    /// ordinary-speech ceiling (0.009), which is margin enough given that the
    /// near neighbours are soundalikes we'd happily wake on.
    ///
    /// Do not tune this from `verify_model.py`. Its Python `predict_clip`
    /// starts from zero-primed buffers, and zeros make any speech score high
    /// while they drain — on v3 it reported 91.7% where this path scored 58.3%.
    /// The two disagree by enough to pick the wrong threshold.
    static let threshold: Float = {
        ProcessInfo.processInfo.environment["NEON_OWW_THRESHOLD"]
            .flatMap(Float.init) ?? 0.2
    }()
    /// Scores that came close but didn't fire, for tuning from the room.
    /// Reported at most once a second so a long sentence can't flood the log.
    /// The floor has to stay well under `threshold` or near misses stop being
    /// visible in the event log at exactly the moment they start mattering.
    var onNearMiss: (Float) -> Void = { _ in }
    private static let nearMissFloor: Float = 0.05
    private var lastNearMiss = Date.distantPast
    /// When the microphone last delivered a buffer. A wake listener that has
    /// stopped receiving audio looks exactly like one that hears nothing —
    /// silent, and indistinguishable from a quiet room.
    private(set) var lastChunkAt = Date.distantPast
    var secondsSinceAudio: TimeInterval { Date().timeIntervalSince(lastChunkAt) }

    // MARK: - Setup

    /// The models ship inside the app bundle — they are build artifacts locked
    /// to the pipeline constants below, not something to configure per machine.
    /// Same idiom as `loadEyes()`: bundle first, then a dev fallback so the
    /// offline harness works when running the bare binary out of `.build/`.
    static var modelDir: URL? {
        if let url = Bundle.main.url(forResource: "oww", withExtension: nil) {
            return url
        }
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<5 {
            let candidate = dir.appendingPathComponent("wake/models")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    private func loadModels() -> Bool {
        let fm = FileManager.default
        guard let dir = Self.modelDir else {
            dbg("oww: no model directory (bundle Resources/oww or wake/models)")
            return false
        }
        guard let files = try? fm.contentsOfDirectory(at: dir,
                                                      includingPropertiesForKeys: nil)
        else { return false }
        let onnx = files.filter { $0.pathExtension == "onnx" }
        // Any .onnx that isn't a shared feature extractor is a candidate wake
        // model. A Neon-named model always wins so a leftover trial model
        // (hey_jarvis) can sit in the directory without silently taking over.
        let candidates = onnx.filter {
            !["melspectrogram.onnx", "embedding_model.onnx"].contains($0.lastPathComponent)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let mel = onnx.first(where: { $0.lastPathComponent == "melspectrogram.onnx" }),
              let embed = onnx.first(where: { $0.lastPathComponent == "embedding_model.onnx" }),
              let wake = candidates.first(where: {
                  $0.lastPathComponent.lowercased().contains("neon")
              }) ?? candidates.first
        else {
            dbg("oww: models missing in \(dir.path)")
            return false
        }
        do {
            let env = try ORTEnv(loggingLevel: .warning)
            self.env = env
            melModel = try ORTSession(env: env, modelPath: mel.path, sessionOptions: nil)
            embedModel = try ORTSession(env: env, modelPath: embed.path, sessionOptions: nil)
            wakeModel = try ORTSession(env: env, modelPath: wake.path, sessionOptions: nil)
            wakeName = wake.deletingPathExtension().lastPathComponent
            let loaded = wakeName
            DispatchQueue.main.async { self.modelName = loaded }
            let others = candidates.filter { $0 != wake }
                .map { $0.deletingPathExtension().lastPathComponent }
            dbg("oww: loaded \(wakeName) (threshold \(Self.threshold))"
                + (others.isEmpty ? "" : " (ignoring \(others.joined(separator: ", ")))"))
            return true
        } catch {
            dbg("oww: model load failed: \(error)")
            return false
        }
    }

    // MARK: - Live listening

    func start() {
        queue.async {
            guard self.wakeModel != nil || self.loadModels() else { return }
            self.primeBuffers()
            DispatchQueue.main.async { self.attachWhenHubReady() }
        }
    }

    /// Drop the tap and take a fresh one. The engine can stop delivering
    /// buffers without erroring — a device change is the usual cause — and
    /// nothing about that state is visible from inside the callback that
    /// stopped being called.
    func reattach() {
        AudioHub.shared.removeConsumer(consumerId)
        consumerId = nil
        AudioHub.shared.restart()
        lastChunkAt = Date()   // give the new tap a grace period
        attachWhenHubReady()
    }

    private func attachWhenHubReady() {
        guard consumerId == nil else { return }
        guard let tapFormat = AudioHub.shared.tapFormat else {
            // Hub not running yet (mic permission flow); retry shortly.
            startTimer?.invalidate()
            startTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
                self?.attachWhenHubReady()
            }
            return
        }
        converter = AVAudioConverter(from: tapFormat, to: format16k)
        consumerId = AudioHub.shared.addConsumer { [weak self] buffer in
            self?.capture(buffer)
        }
        dbg("oww: listening (\(wakeName))")
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        lastChunkAt = Date()
        guard let converter else { return }
        let ratio = 16000.0 / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format16k, frameCapacity: capacity) else { return }
        var fed = false
        var convError: NSError?
        converter.convert(to: out, error: &convError) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard convError == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let n = Int(out.frameLength)
        var floats = [Float](repeating: 0, count: n)
        for i in 0..<n { floats[i] = Float(ch[0][i]) }
        queue.async {
            self.samples.append(contentsOf: floats)
            self.drain()
        }
    }

    /// openWakeWord primes its buffers by running ~4 s of random noise
    /// through the pipeline — zero-filled buffers are far outside the
    /// models' training distribution and cause spurious spikes (observed:
    /// any speech scored ~0.99 while zero priming drained).
    private func primeBuffers() {
        var noise = [Float](repeating: 0, count: 16000 * 4)
        for i in noise.indices { noise[i] = Float(Int.random(in: -1000...1000)) }
        var offset = 0
        while offset + 1280 <= noise.count {
            _ = process(Array(noise[offset..<offset + 1280]))
            offset += 1280
        }
    }

    private func drain() {
        while samples.count >= 1280 {
            let chunk = Array(samples.prefix(1280))
            samples.removeFirst(1280)
            guard let score = process(chunk) else { continue }
            let over = score > Self.threshold
            let fired = over && Date().timeIntervalSince(lastFire) > 2
            // Persisted for threshold tuning — the page's event log dies with
            // the app, and one remembered number is not a distribution. A
            // score over the bar that lost to the 2 s refractory window is
            // logged "held", not "miss": the tail of one wake looks exactly
            // like a stack of failures otherwise, which makes the file read
            // as if the threshold were far too high.
            WakeScoreLog.shared.record(model: wakeName, score: score,
                                       outcome: fired ? "WAKE" : (over ? "held" : "miss"),
                                       threshold: Self.threshold)
            if fired {
                lastFire = Date()
                dbg("oww: DETECTED \(wakeName) score=\(score)")
                let name = wakeName
                DispatchQueue.main.async {
                    self.lastScore = score
                    self.lastDetectAt = Date()
                    self.onDetect(name)
                }
            } else if score > Self.nearMissFloor,
                      Date().timeIntervalSince(lastNearMiss) > 1 {
                lastNearMiss = Date()
                DispatchQueue.main.async { self.onNearMiss(score) }
            }
        }
    }

    // MARK: - The pipeline

    private func run(_ session: ORTSession, _ input: [Float], shape: [NSNumber]) throws -> [Float] {
        let data = NSMutableData(bytes: input, length: input.count * 4)
        let value = try ORTValue(tensorData: data, elementType: .float, shape: shape)
        let inName = try session.inputNames()[0]
        let outName = try session.outputNames()[0]
        let outputs = try session.run(withInputs: [inName: value],
                                      outputNames: [outName], runOptions: nil)
        guard let out = outputs[outName] else { return [] }
        let outData = try out.tensorData() as Data
        return outData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Push one 1280-sample chunk through; returns a wake score when the
    /// wake model ran.
    private func process(_ chunk: [Float]) -> Float? {
        guard let melModel, let embedModel, let wakeModel else { return nil }
        do {
            // 1. melspectrogram with a 480-sample lookback (as openWakeWord's
            // streaming path does): compute over tail+chunk, keep the last 8
            // frames per 1280-sample chunk so nothing is lost at seams.
            let input = melTail + chunk
            melTail = Array((melTail + chunk).suffix(480))
            let mel = try run(melModel, input, shape: [1, NSNumber(value: input.count)])
            let frameCount = mel.count / 32
            let keep = min(frameCount, chunk.count / 160)
            for f in (frameCount - keep)..<frameCount {
                melFrames.append(Array(mel[f * 32..<(f + 1) * 32]).map { $0 / 10 + 2 })
            }
            // 2. embeddings over 76-frame windows, stride 8
            var scored: Float?
            while melFrames.count - windowStart >= 76 {
                let window = melFrames[windowStart..<windowStart + 76].flatMap { $0 }
                windowStart += 8
                let emb = try run(embedModel, window, shape: [1, 76, 32, 1])
                embeddings.append(emb)
                embeddings.removeFirst(embeddings.count - 16)
                // 3. wake model over the last 16 embeddings
                let flat = embeddings.flatMap { $0 }
                let score = try run(wakeModel, flat, shape: [1, 16, 96])
                scoresRun += 1
                if scoresRun > Self.warmupScores {
                    scored = max(scored ?? 0, score.first ?? 0)
                }
            }
            // Trim mel history so buffers stay small.
            if windowStart > 500 {
                melFrames.removeFirst(windowStart - 100)
                windowStart = 100
            }
            return scored
        } catch {
            dbg("oww: inference error: \(error)")
            return nil
        }
    }

    // MARK: - Offline test (NEON_OWW_TEST=path/to/16k-mono.wav)

    static func offlineTest(wavPath: String) {
        let listener = OpenWakeListener()
        guard listener.loadModels() else { print("models missing"); return }
        listener.primeBuffers()
        guard let wav = FileManager.default.contents(atPath: wavPath) else {
            print("cannot read \(wavPath)"); return
        }
        guard let dataRange = wav.range(of: Data("data".utf8)) else {
            print("no data chunk"); return
        }
        let pcm = wav.subdata(in: wav.index(dataRange.upperBound, offsetBy: 4)..<wav.count)
        let samples: [Float] = pcm.withUnsafeBytes {
            $0.bindMemory(to: Int16.self).map { Float($0) }
        }
        print("samples: \(samples.count) (\(Double(samples.count) / 16000)s)")
        var best: Float = 0
        var offset = 0
        while offset + 1280 <= samples.count {
            let chunk = Array(samples[offset..<offset + 1280])
            offset += 1280
            if let s = listener.process(chunk) {
                if s > 0.1 { print(String(format: "t=%.2fs score=%.3f", Double(offset) / 16000, s)) }
                best = max(best, s)
            }
        }
        print(String(format: "max score: %.3f vs threshold %.2f %@", best, threshold,
                     best > threshold ? "— DETECTED" : "— no detection"))
    }
}
