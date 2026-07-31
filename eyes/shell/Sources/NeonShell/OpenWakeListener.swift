import AVFoundation
import OnnxRuntimeBindings

// openWakeWord detection: melspectrogram -> speech embedding -> wake model,
// all tiny ONNX models on CPU, fed 80 ms chunks of 16 kHz audio. Unlike the
// SFSpeech matcher this spots the phrase mid-stream with no silence
// bookkeeping. Models live in ~/.config/neon/oww/ — melspectrogram.onnx and
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
    static let threshold: Float = 0.5

    // MARK: - Setup

    private static var modelDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/neon/oww")
    }

    private func loadModels() -> Bool {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.modelDir,
                                                      includingPropertiesForKeys: nil)
        else { return false }
        let onnx = files.filter { $0.pathExtension == "onnx" }
        guard let mel = onnx.first(where: { $0.lastPathComponent == "melspectrogram.onnx" }),
              let embed = onnx.first(where: { $0.lastPathComponent == "embedding_model.onnx" }),
              let wake = onnx.first(where: {
                  !["melspectrogram.onnx", "embedding_model.onnx"].contains($0.lastPathComponent)
              })
        else {
            dbg("oww: models missing in \(Self.modelDir.path)")
            return false
        }
        do {
            let env = try ORTEnv(loggingLevel: .warning)
            self.env = env
            melModel = try ORTSession(env: env, modelPath: mel.path, sessionOptions: nil)
            embedModel = try ORTSession(env: env, modelPath: embed.path, sessionOptions: nil)
            wakeModel = try ORTSession(env: env, modelPath: wake.path, sessionOptions: nil)
            wakeName = wake.deletingPathExtension().lastPathComponent
            dbg("oww: loaded \(wakeName)")
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
            if let score = process(chunk), score > Self.threshold,
               Date().timeIntervalSince(lastFire) > 2 {
                lastFire = Date()
                dbg("oww: DETECTED \(wakeName) score=\(score)")
                let name = wakeName
                DispatchQueue.main.async { self.onDetect(name) }
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
        print(String(format: "max score: %.3f %@", best,
                     best > threshold ? "— DETECTED" : "— no detection"))
    }
}
