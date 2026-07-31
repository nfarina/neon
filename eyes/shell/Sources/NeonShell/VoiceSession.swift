import AVFoundation
import Foundation

// A live spoken conversation over a realtime speech-to-speech API, generic
// across providers via VoiceEngine. Streams mic audio up from the shared
// AudioHub, plays replies through it, and meters token usage into costs.
final class VoiceSession: NSObject {
    var onAmplitude: (Float) -> Void = { _ in }
    /// Called once when the session ends; reason "tool" means the model put
    /// itself to sleep and the eyes should close immediately.
    var onClosed: (String) -> Void = { _ in }

    private static let system = """
        You are Neon, an AI assistant who lives on a MacBook in Nick's \
        kitchen. Your visual form is a pair of glowing cyan eyes. Be warm, \
        quick, and genuinely helpful. Keep spoken replies short and natural \
        — no catchphrases, no persona theatrics.

        You hear everything near the microphone, including people talking to \
        each other rather than to you. If speech clearly isn't directed at \
        you, don't respond to it.

        When the conversation ends — the user says goodbye, is clearly done, \
        or tells you to sleep — say a brief goodbye and then always call \
        \(sleepToolName) in the same turn. Also call it (without speaking) if \
        you were woken by mistake and hear only background chatter or noise. \
        Invoke tools only as real function calls; never say or spell a tool's \
        name out loud.
        """
    private static let greeting =
        ProcessInfo.processInfo.environment["NEON_GREETING"]
        ?? "(Nick just said the wake phrase.) Greet him in a word or two and ask what he needs."
    private static let idleSeconds: TimeInterval = 15

    let engine: VoiceEngine
    private var ws: URLSessionWebSocketTask?
    private var consumerId: UUID?
    private var inputConverter: AVAudioConverter?
    private let sendFormat: AVAudioFormat
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private var idleTimer: Timer?
    private var closed = false
    private var sleepRequested = false  // model called go_to_sleep; close after playback drains
    private let sessionStart = Date()
    private var usage = VoiceUsage()
    private var heard = ""  // running input transcript, for the debug overlay

    // Playback bookkeeping; also drives the half-duplex fallback when the
    // hub's echo cancellation is unavailable.
    private var pendingPlaybacks = 0
    private var playbackTailUntil = Date.distantPast

    /// The words spoken after the wake name, if any — sent as the opening
    /// user turn instead of asking for a greeting.
    private let firstUtterance: String?

    init(engine: VoiceEngine, firstUtterance: String? = nil) {
        self.engine = engine
        self.firstUtterance = firstUtterance
        self.sendFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: engine.sendSampleRate,
            channels: 1, interleaved: true)!
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        guard let key = Self.loadKey(engine.keyName) else {
            NSLog("Neon voice: \(engine.keyName) not found in ~/.config/neon/secrets.env")
            DispatchQueue.main.async { self.onClosed("no key") }
            return
        }
        var request = URLRequest(url: engine.url(key: key))
        for (k, v) in engine.headers(key: key) { request.setValue(v, forHTTPHeaderField: k) }
        let task = URLSession.shared.webSocketTask(with: request)
        ws = task
        task.resume()
        receiveLoop()
        for msg in engine.openMessages(system: Self.system) { sendJSON(msg) }
        bumpIdle()
        NSLog("Neon voice: connecting to \(engine.name) (\(engine.model))")
    }

    func close(reason: String) {
        guard !closed else { return }
        closed = true
        NSLog("Neon voice: closing (\(reason)) — \(costLine())")
        idleTimer?.invalidate()
        AudioHub.shared.removeConsumer(consumerId)
        consumerId = nil
        AudioHub.shared.player.stop()
        ws?.cancel(with: .normalClosure, reason: nil)
        UsageStore.shared.record(engine: engine.name, cost: currentCost())
        DispatchQueue.main.async { self.onClosed(reason) }
    }

    private static func loadKey(_ name: String) -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/neon/secrets.env")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("\(name)=") {
            return String(line.dropFirst(name.count + 1))
        }
        return nil
    }

    // MARK: - Stats

    func currentCost() -> Double {
        engine.cost(usage, elapsed: Date().timeIntervalSince(sessionStart))
    }

    private func costLine() -> String {
        String(format: "in %d out %d tokens, ~$%.4f", usage.audioIn + usage.textIn,
               usage.audioOut + usage.textOut, currentCost())
    }

    func statsPairs() -> [[String]] {
        let elapsed = Int(Date().timeIntervalSince(sessionStart))
        return [
            ["engine", "\(engine.name) · \(engine.model)"],
            ["session", String(format: "%d:%02d", elapsed / 60, elapsed % 60)],
            ["audio in/out", "\(usage.audioIn)/\(usage.audioOut) tok"],
            ["text in/out", "\(usage.textIn)/\(usage.textOut) tok"],
            ["session cost", String(format: "$%.4f", currentCost())],
            ["lifetime", String(format: "$%.3f", UsageStore.shared.total + currentCost())],
            ["hears", String(heard.suffix(70))],
        ]
    }

    // MARK: - WebSocket

    private func receiveLoop() {
        ws?.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .failure(let error):
                NSLog("Neon voice: socket error: \(error.localizedDescription)")
                self.close(reason: "socket")
            case .success(let message):
                let data: Data
                switch message {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: data = Data()
                }
                if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    DispatchQueue.main.async { self.handleMessage(obj) }
                }
                self.receiveLoop()
            }
        }
    }

    private func sendJSON(_ obj: [String: Any]) {
        guard !closed, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        ws?.send(.string(String(decoding: data, as: UTF8.self))) { error in
            if let error { NSLog("Neon voice: send failed: \(error.localizedDescription)") }
        }
    }

    private func handleMessage(_ msg: [String: Any]) {
        for event in engine.parse(msg) {
            switch event {
            case .ready:
                NSLog("Neon voice: session ready")
                startAudio()
                let opening = firstUtterance ?? Self.greeting
                for m in engine.readyMessages(greeting: opening) { sendJSON(m) }
            case .audio(let data):
                enqueuePlayback(data)
                bumpIdle()
            case .inputText(let t):
                NSLog("Neon voice: heard: \(t)")
                heard += heard.isEmpty || t.hasPrefix(" ") ? t : " \(t)"
                bumpIdle()
            case .outputText(let t):
                NSLog("Neon voice: saying: \(t)")
                // Gemini live sometimes verbalizes the tool call into the
                // audio channel (observed: "do_call:go_to_sleep{}") instead
                // of emitting a real toolCall. Treat the leak as the call.
                if t.contains(sleepToolName) || t.contains("do_call") {
                    NSLog("Neon voice: tool-call leak in speech; treating as \(sleepToolName)")
                    sleepRequested = true
                    if pendingPlaybacks <= 0 { close(reason: "tool") }
                }
            case .toolCall(let name):
                NSLog("Neon voice: tool call: \(name)")
                if name == sleepToolName {
                    sleepRequested = true
                    if pendingPlaybacks <= 0 { close(reason: "tool") }
                    // else: closed by the playback drain handler
                }
            case .interrupted:
                AudioHub.shared.player.stop()
                pendingPlaybacks = 0
                playbackTailUntil = Date.distantPast
                AudioHub.shared.player.play()
            case .usage(let u, let cumulative):
                if cumulative { usage = u } else { usage.add(u) }
            }
        }
    }

    // MARK: - Audio

    private func startAudio() {
        let hub = AudioHub.shared
        hub.startIfNeeded()
        guard let tapFormat = hub.tapFormat else {
            NSLog("Neon voice: audio hub unavailable")
            close(reason: "audio hub")
            return
        }
        hub.ensurePlayer()
        inputConverter = AVAudioConverter(from: tapFormat, to: sendFormat)
        consumerId = hub.addConsumer { [weak self] buffer in
            self?.sendMic(buffer)
        }
    }

    private func sendMic(_ buffer: AVAudioPCMBuffer) {
        guard !closed, let converter = inputConverter else { return }
        // Half-duplex fallback, only when echo cancellation is unavailable.
        if !AudioHub.shared.voiceProcessing,
           pendingPlaybacks > 0 || Date() < playbackTailUntil { return }
        let ratio = sendFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: sendFormat, frameCapacity: capacity) else { return }
        var fed = false
        var convError: NSError?
        converter.convert(to: out, error: &convError) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard convError == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let data = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
        sendJSON(engine.audioMessage(data.base64EncodedString()))
    }

    private func enqueuePlayback(_ data: Data) {
        let frames = data.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        var sum: Float = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            let out = buffer.floatChannelData![0]
            for i in 0..<frames {
                let v = Float(samples[i]) / 32768
                out[i] = v
                sum += v * v
            }
        }
        let amp = min(1, sqrt(sum / Float(frames)) * 6)
        onAmplitude(amp)
        pendingPlaybacks += 1
        let player = AudioHub.shared.player
        player.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingPlaybacks -= 1
                if self.pendingPlaybacks <= 0 {
                    self.playbackTailUntil = Date().addingTimeInterval(0.3)
                    if self.sleepRequested { self.close(reason: "tool"); return }
                    // The reply has finished *playing*; idle silence starts now.
                    // (Audio arrives from the API much faster than realtime, so
                    // the receive-side bumps alone would start the idle clock
                    // mid-answer on long replies.)
                    self.bumpIdle()
                }
            }
        }
        if !player.isPlaying { player.play() }
    }

    // MARK: - Idle timeout

    private func bumpIdle() {
        DispatchQueue.main.async {
            self.idleTimer?.invalidate()
            self.idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleSeconds, repeats: false) { [weak self] _ in
                guard let self else { return }
                // Never time out while a reply is still playing.
                if self.pendingPlaybacks > 0 { self.bumpIdle() } else { self.close(reason: "idle") }
            }
        }
    }
}

// MARK: - Persistent lifetime usage

final class UsageStore {
    static let shared = UsageStore()
    private(set) var total: Double = 0
    private(set) var byEngine: [String: Double] = [:]
    private let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/neon/usage.json")

    private init() {
        if let data = try? Data(contentsOf: path),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            total = obj["total"] as? Double ?? 0
            byEngine = obj["byEngine"] as? [String: Double] ?? [:]
        }
    }

    func record(engine: String, cost: Double) {
        total += cost
        byEngine[engine, default: 0] += cost
        let obj: [String: Any] = ["total": total, "byEngine": byEngine]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) {
            try? data.write(to: path)
        }
    }
}
