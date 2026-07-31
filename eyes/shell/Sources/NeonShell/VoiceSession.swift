import AVFoundation
import Foundation

// A live spoken conversation over a realtime speech-to-speech API, generic
// across providers via VoiceEngine. Streams mic audio up from the shared
// AudioHub, plays replies through it, and meters token usage into costs.
final class VoiceSession: NSObject {
    var onAmplitude: (Float) -> Void = { _ in }
    /// Fires true when the model starts reasoning (thought parts streaming)
    /// and false when its spoken reply begins — drives the eyes' indicator.
    var onThinking: (Bool) -> Void = { _ in }
    /// Fires true when idle silence begins the doze animation (session still
    /// open as a grace window) and false if the speaker resumes mid-doze.
    var onDoze: (Bool) -> Void = { _ in }
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
        you, don't respond to it, comment on it, or echo it — just stay \
        quiet until you're addressed again.

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
    private static let idleSeconds: TimeInterval = 7

    let engine: VoiceEngine
    private var ws: URLSessionWebSocketTask?
    private var consumerId: UUID?
    private var inputConverter: AVAudioConverter?
    private let sendFormat: AVAudioFormat
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private var idleTimer: Timer?
    private var closed = false
    private var sleepRequested = false  // model called go_to_sleep; close after audio finishes
    private var sleepTimer: Timer?
    private var dozing = false
    private var dozeTimer: Timer?
    private var lastAudioAt = Date.distantPast  // last audio *received* (chunks may trail the tool call)
    private var thinkingActive = false
    // Last time the mic carried voice-level energy. Input transcription
    // arrives in a clump when the model responds, not while Nick talks, so
    // this is the only live signal that he's mid-sentence. (Echo-cancelled
    // input: Neon's own voice can't keep her awake.)
    private var lastVoiceAt = Date.distantPast
    private let sessionStart = Date()
    private var usage = VoiceUsage()
    private var heard = ""  // running input transcript, for the debug overlay
    private var camera: CameraFeed?
    private var transcript: [(speaker: String, text: String)] = []

    // Playback bookkeeping; also drives the half-duplex fallback when the
    // hub's echo cancellation is unavailable.
    private var pendingPlaybacks = 0
    private var playbackTailUntil = Date.distantPast

    /// The words spoken after the wake name, if any — the opening user turn.
    private let firstUtterance: String?
    /// The captured 16 kHz audio of that utterance. When present (and the
    /// engine takes 16 kHz), it's flushed instead of sending the text —
    /// Gemini hears the real thing rather than Apple's transcription of it.
    private let preludeAudio: Data?

    init(engine: VoiceEngine, firstUtterance: String? = nil, preludeAudio: Data? = nil) {
        self.engine = engine
        self.firstUtterance = firstUtterance
        self.preludeAudio = preludeAudio
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
        var system = Self.system
        if let recent = ConversationLog.shared.recentContext() {
            system += """


                Recent conversations with Nick, oldest first — use them for \
                continuity (things he told you, asked for, or mentioned) but \
                don't recite or reference them unprompted:
                \(recent)
                """
        }
        for msg in engine.openMessages(system: system) { sendJSON(msg) }
        bumpIdle()
        NSLog("Neon voice: connecting to \(engine.name) (\(engine.model))")
    }

    func close(reason: String) {
        guard !closed else { return }
        closed = true
        NSLog("Neon voice: closing (\(reason)) — \(costLine())")
        idleTimer?.invalidate()
        sleepTimer?.invalidate()
        dozeTimer?.invalidate()
        if thinkingActive { thinkingActive = false; onThinking(false) }
        camera?.stop()
        camera = nil
        ConversationLog.shared.append(turns: transcript)
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

    /// External evidence that someone in the room is talking (the wake
    /// listener's recognizer produced a partial). Far more distance-tolerant
    /// than the mic RMS gate; keeps the idle/doze logic from hanging up on
    /// quiet or far-away speakers.
    func noteVoiceActivity() {
        lastVoiceAt = Date()
    }

    private func costLine() -> String {
        String(format: "in %d out %d tokens, ~$%.4f", usage.audioIn + usage.textIn,
               usage.audioOut + usage.textOut, currentCost())
    }

    func statsPairs() -> [[String]] {
        let elapsed = Int(Date().timeIntervalSince(sessionStart))
        let state = thinkingActive ? "thinking"
            : dozing ? "dozing"
            : pendingPlaybacks > 0 ? "speaking"
            : Date().timeIntervalSince(lastVoiceAt) < 1.0 ? "hearing you"
            : "listening"
        return [
            ["engine", "\(engine.name) · \(engine.model)"],
            ["state", state],
            ["session", String(format: "%d:%02d", elapsed / 60, elapsed % 60)],
            ["audio in/out", "\(usage.audioIn)/\(usage.audioOut) tok"],
            ["text in/out", "\(usage.textIn)/\(usage.textOut) tok"],
            ["video in", "\(usage.imageIn) tok"],
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
                if let cmd = firstUtterance { record("Nick", cmd) }
                if let prelude = preludeAudio, engine.sendSampleRate == 16000,
                   ProcessInfo.processInfo.environment["NEON_WAKE_AUDIO"] != "0" {
                    // Flush the wake utterance's real audio (validated by
                    // gemini-fastflush-test.mjs: server VAD copes with a
                    // faster-than-realtime burst). Before startAudio so live
                    // mic chunks can't interleave into the past.
                    NSLog("Neon voice: flushing %.1fs wake audio",
                          Double(prelude.count) / 32000.0)
                    for start in stride(from: 0, to: prelude.count, by: 32000) {
                        let chunk = prelude.subdata(in: start..<min(start + 32000, prelude.count))
                        sendJSON(engine.audioMessage(chunk.base64EncodedString()))
                    }
                } else {
                    let opening = firstUtterance ?? Self.greeting
                    for m in engine.readyMessages(greeting: opening) { sendJSON(m) }
                }
                startAudio()
            case .audio(let data):
                lastAudioAt = Date()
                if thinkingActive { thinkingActive = false; onThinking(false) }
                enqueuePlayback(data)
                bumpIdle()
            case .thinking:
                if !thinkingActive {
                    NSLog("Neon voice: thinking…")
                    thinkingActive = true
                    onThinking(true)
                }
                bumpIdle()
            case .inputText(let t):
                NSLog("Neon voice: heard: \(t)")
                heard += heard.isEmpty || t.hasPrefix(" ") ? t : " \(t)"
                record("Nick", t)
                bumpIdle()
            case .outputText(let t):
                NSLog("Neon voice: saying: \(t)")
                // Gemini live sometimes verbalizes the tool call into the
                // audio channel (observed: "do_call:go_to_sleep{}") instead
                // of emitting a real toolCall. Treat the leak as the call.
                if t.contains(sleepToolName) || t.contains("do_call") {
                    NSLog("Neon voice: tool-call leak in speech; treating as \(sleepToolName)")
                    requestSleep()
                } else {
                    record("Neon", t)
                }
            case .toolCall(let name):
                NSLog("Neon voice: tool call: \(name)")
                if name == sleepToolName { requestSleep() }
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

    /// The model asked to sleep, but audio chunks for its goodbye may still
    /// be arriving — the playback queue can momentarily drain mid-stream, so
    /// "queue empty" alone clips the goodbye. Close only once the queue is
    /// empty AND no new audio has arrived for a beat.
    private func requestSleep() {
        guard !sleepRequested else { return }
        sleepRequested = true
        let deadline = Date().addingTimeInterval(12)
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, !self.closed else { return }
            let audioQuiet = Date().timeIntervalSince(self.lastAudioAt) > 0.7
            if (self.pendingPlaybacks <= 0 && audioQuiet) || Date() > deadline {
                self.close(reason: "tool")
            }
        }
    }

    private func record(_ speaker: String, _ text: String) {
        if transcript.last?.speaker == speaker {
            transcript[transcript.count - 1].text += text.hasPrefix(" ") || text.isEmpty
                ? text : " \(text)"
        } else {
            transcript.append((speaker, text))
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
        startCamera()
    }

    private func startCamera() {
        guard engine.videoMessage("") != nil,  // engine takes video at all
              ProcessInfo.processInfo.environment["NEON_CAMERA"] != "0" else { return }
        let cam = CameraFeed()
        cam.onFrame = { [weak self] b64 in
            guard let self, !self.closed, let msg = self.engine.videoMessage(b64) else { return }
            self.sendJSON(msg)
        }
        camera = cam
        cam.start()
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
        var acc: Int64 = 0
        let n = Int(out.frameLength)
        for i in 0..<n { let v = Int64(ch[0][i]); acc += v * v }
        let rms = sqrt(Double(acc) / Double(n))
        if rms > 250 {  // low bar: quiet/distant speech must still count
            lastVoiceAt = Date()
        }
        let data = Data(bytes: ch[0], count: n * 2)
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
            if self.dozing { self.exitDoze() }
            self.idleTimer?.invalidate()
            self.idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleSeconds, repeats: false) { [weak self] _ in
                guard let self else { return }
                // Never time out while a reply is still playing or while
                // someone in the room is mid-sentence.
                if self.pendingPlaybacks > 0 || Date().timeIntervalSince(self.lastVoiceAt) < 1.5 {
                    self.bumpIdle()
                } else {
                    self.enterDoze()
                }
            }
        }
    }

    // Idle doesn't hang up immediately: the eyes doze off while the session
    // stays open, so someone resuming mid-doze is still heard. The session
    // closes only when the doze animation has fully completed (~5 s).
    private func enterDoze() {
        guard !dozing, !closed, !sleepRequested else { return }
        dozing = true
        NSLog("Neon voice: dozing (grace window)")
        onDoze(true)
        let started = Date()
        dozeTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, !self.closed else { return }
            if Date().timeIntervalSince(self.lastVoiceAt) < 0.4 {
                self.exitDoze()
                self.bumpIdle()
            } else if Date().timeIntervalSince(started) > 5.2 {
                self.dozeTimer?.invalidate()
                self.close(reason: "idle")
            }
        }
    }

    private func exitDoze() {
        guard dozing else { return }
        dozing = false
        dozeTimer?.invalidate()
        NSLog("Neon voice: doze interrupted — still being spoken to")
        onDoze(false)
    }
}

// MARK: - Short-term memory

// Cross-session continuity: every session's transcript is appended to a
// rolling log, and the tail of that log is injected into the next session's
// system prompt. Crude but effective — "remember the number 47" survives a
// sleep/wake cycle. Long-term (summarized) memory can come later.
final class ConversationLog {
    static let shared = ConversationLog()
    private let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/neon/conversations.md")

    func append(turns: [(speaker: String, text: String)]) {
        let clean = turns.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !clean.isEmpty else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE MMM d, h:mm a"
        var block = "\n## \(fmt.string(from: Date()))\n"
        for t in clean {
            block += "\(t.speaker): \(t.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        // Keep the file itself bounded; the distant past is long-term memory's job.
        let combined = String((existing + block).suffix(30_000))
        try? combined.write(to: path, atomically: true, encoding: .utf8)
    }

    /// The tail of the log, for injection into a new session's prompt.
    func recentContext(maxChars: Int = 2500) -> String? {
        guard let text = try? String(contentsOf: path, encoding: .utf8),
              !text.isEmpty else { return nil }
        let tail = String(text.suffix(maxChars))
        // Cut at a line boundary so we don't start mid-sentence.
        return tail.firstIndex(of: "\n").map { String(tail[$0...]) } ?? tail
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
