import AVFoundation
import Foundation

// A live spoken conversation with Gemini over the Live API WebSocket.
// Owns the microphone and speakers for its lifetime: mic audio goes up as
// 16 kHz PCM, 24 kHz PCM replies are played back, and Apple's voice
// processing provides echo cancellation so Neon does not hear itself.
// The message schema is validated by voice/gemini-live-audio-test.mjs.
final class VoiceSession: NSObject {
    var onAmplitude: (Float) -> Void = { _ in }   // 0..1 while Neon speaks
    var onClosed: () -> Void = {}

    private static let model = "gemini-2.5-flash-native-audio-latest"
    private static let system = """
        You are Neon, an AI assistant who lives on a MacBook in Nick's \
        kitchen. Your visual form is a pair of glowing cyan eyes. Be warm, \
        quick, and genuinely helpful. Keep spoken replies short and natural \
        — no catchphrases, no persona theatrics.
        """
    private static let idleSeconds: TimeInterval = 15

    private var ws: URLSessionWebSocketTask?
    private var consumerId: UUID?
    private var inputConverter: AVAudioConverter?
    private let sendFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private var idleTimer: Timer?
    private var closed = false
    // Playback bookkeeping. When the hub's echo cancellation is active the
    // mic streams continuously (true barge-in); when it is not, these drive
    // the half-duplex fallback that mutes the mic while Neon speaks.
    private var pendingPlaybacks = 0
    private var playbackTailUntil = Date.distantPast

    // MARK: - Lifecycle

    func start() {
        guard let key = Self.loadKey() else {
            NSLog("Neon voice: GEMINI_API_KEY not found in ~/.config/neon/secrets.env")
            DispatchQueue.main.async { self.onClosed() }
            return
        }
        let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(key)")!
        let task = URLSession.shared.webSocketTask(with: url)
        ws = task
        task.resume()
        receiveLoop()
        sendJSON([
            "setup": [
                "model": "models/\(Self.model)",
                "generationConfig": ["responseModalities": ["AUDIO"]],
                "systemInstruction": ["parts": [["text": Self.system]]],
                "outputAudioTranscription": [String: String](),
                "inputAudioTranscription": [String: String](),
            ],
        ])
        bumpIdle()
    }

    func close(reason: String) {
        guard !closed else { return }
        closed = true
        NSLog("Neon voice: closing (\(reason))")
        idleTimer?.invalidate()
        AudioHub.shared.removeConsumer(consumerId)
        consumerId = nil
        AudioHub.shared.player.stop()  // the shared engine keeps running
        ws?.cancel(with: .normalClosure, reason: nil)
        DispatchQueue.main.async { self.onClosed() }
    }

    private static func loadKey() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/neon/secrets.env")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("GEMINI_API_KEY=") {
            return String(line.dropFirst("GEMINI_API_KEY=".count))
        }
        return nil
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
        if msg["setupComplete"] != nil {
            NSLog("Neon voice: session ready")
            startAudio()
            // Acknowledge the wake phrase right away so the wake feels heard.
            sendJSON([
                "clientContent": [
                    "turns": [[
                        "role": "user",
                        "parts": [["text": "(Nick just said the wake phrase.) Greet him in a word or two and ask what he needs."]],
                    ]],
                    "turnComplete": true,
                ],
            ])
            return
        }
        guard let sc = msg["serverContent"] as? [String: Any] else { return }
        if sc["interrupted"] != nil {
            // Barge-in: drop everything queued and keep listening.
            AudioHub.shared.player.stop()
            pendingPlaybacks = 0
            playbackTailUntil = Date.distantPast
            AudioHub.shared.player.play()
        }
        if let turn = sc["modelTurn"] as? [String: Any],
           let parts = turn["parts"] as? [[String: Any]] {
            for part in parts {
                if let inline = part["inlineData"] as? [String: Any],
                   let b64 = inline["data"] as? String,
                   let data = Data(base64Encoded: b64) {
                    enqueuePlayback(data)
                }
            }
            bumpIdle()
        }
        if let tx = sc["inputTranscription"] as? [String: Any], let t = tx["text"] as? String {
            NSLog("Neon voice: heard: \(t)")
            bumpIdle()
        }
        if let tx = sc["outputTranscription"] as? [String: Any], let t = tx["text"] as? String {
            NSLog("Neon voice: saying: \(t)")
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
        // Half-duplex fallback, only when echo cancellation is unavailable:
        // stay quiet while Neon's reply is playing (+ tail).
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
        sendJSON([
            "realtimeInput": [
                "audio": ["mimeType": "audio/pcm;rate=16000", "data": data.base64EncodedString()],
            ],
        ])
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
                self?.close(reason: "idle")
            }
        }
    }
}
