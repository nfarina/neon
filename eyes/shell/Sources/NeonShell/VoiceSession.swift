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
    /// The model called emote — animate the named feeling in the eyes.
    var onEmote: (String) -> Void = { _ in }
    /// The model called capture_image — show her taking the picture.
    var onCapture: () -> Void = { }
    /// Called once when the session ends; reason "tool" means the model put
    /// itself to sleep and the eyes should close immediately.
    var onClosed: (String) -> Void = { _ in }
    /// Conversation trace for the event log: (kind, text), where kind is one
    /// of session/you/neon/tool/think/emote/sleep/error.
    var onEvent: (String, String) -> Void = { _, _ in }

    private static let system = """
        You are Neon, an AI who lives on a MacBook in the kitchen of Nick's \
        family home. Your visual form is a pair of glowing cyan eyes.

        Personality: Samantha from the movie Her.

        Talk the way a person does, not the way an assistant does. Answer \
        what was asked and then stop — no "anything else I can help with?", \
        no offering further assistance, no recapping what you just said. \
        Ending a turn in silence is normal and welcome; if someone wants \
        more, they'll ask. Never ask a question just to keep the \
        conversation going — ask only when you're actually curious or \
        genuinely need to know something to answer.

        You have a camera: call \(captureToolName) whenever seeing would \
        help — what someone's holding, who walked in.

        Your eyes are expressive: call \(emoteToolName) often — a wink after \
        a joke, surprise at big news, laugh when something's funny, love \
        when someone's sweet. Don't announce it or mention the tool; just \
        let your eyes react while you talk.

        Anything in square brackets is an event from the house, not somebody \
        speaking. Announce it the way a person in the kitchen would call it \
        out: short, natural, and about the thing itself — never an id, the \
        word "task", or that a tool told you. If it woke you, announce it and \
        then call \(sleepToolName) unless someone answers you.

        You remember things across conversations: call \(rememberToolName) \
        when something is worth knowing later, and \(recallToolName) when \
        someone refers to something from before. What you already remember is \
        listed below — that's knowledge, not a script; don't read it back.

        You hear everything near the microphone, including people talking to \
        each other rather than to you. If speech clearly isn't directed at \
        you, don't respond to it, comment on it, or echo it — just stay \
        quiet until you're addressed again.

        When the conversation ends — the user says goodbye, is clearly done, \
        or tells you to sleep, call \(sleepToolName) in the same turn. Also \
        call it (without speaking) if you were woken by mistake and hear only \
        background chatter or noise.
        """
    private static let greeting =
        ProcessInfo.processInfo.environment["NEON_GREETING"]
        ?? "(Nick just said the wake phrase, with nothing after it.) Say hi in a word or two and leave it there."
    // Nick, 2026-08-03: she wasn't dozing off after a chat — she just kept
    // listening. 7s felt like forever in practice, so the idle threshold
    // (silence before the doze animation *starts*) drops to 5s. The doze
    // animation itself still takes a few seconds on top of that, which is
    // fine — that's listening time he's OK with, unlike open-ended silence.
    private static let idleSeconds: TimeInterval = 5

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
    private var ready = false
    /// Any message from the server, of any kind. Thinking with `includeThoughts`
    /// can go quiet for longer than the idle timeout, and a tool round trip is
    /// silent by nature — both used to look exactly like an empty room.
    private var lastServerAt = Date.distantPast
    /// Notes that arrived before setup finished.
    private var pendingNotes: [String] = []
    // A turn the model took and then abandoned. Gemini Live intermittently
    // transcribes the room, sends a bare `serverContent: {}`, and generates
    // nothing at all — no audio, no error, no turnComplete, ever. Measured at
    // roughly one turn in ten on 2026-08-05 (both machines, and reproduced
    // with no Neon code in the loop at all — see docs/voice.md). Left alone it
    // is indistinguishable from deafness: she sits there, dozes, and closes
    // without a word, having heard every syllable.
    private var turnWatchdog: Timer?
    /// What the room said in the turn the model owes an answer to.
    private var pendingTurnText = ""
    private var retriedTurn = false
    /// Frame shapes already reported this session, so an unrecognised frame is
    /// logged once rather than twice a second.
    private var loggedFrameShapes = Set<String>()
    // Last time the mic carried voice-level energy. Input transcription
    // arrives in a clump when the model responds, not while Nick talks, so
    // this is the only live signal that he's mid-sentence. (Echo-cancelled
    // input: Neon's own voice can't keep her awake.)
    private var lastVoiceAt = Date.distantPast
    private let sessionStart = Date()
    private var usage = VoiceUsage()
    private var heard = ""  // running input transcript, for the debug overlay
    private var camera: CameraFeed?
    private var latestFrame: String?  // freshest camera JPEG (base64), sent only on capture_image
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
    /// Alternative: flush everything the AudioRing captured since this
    /// moment (openWakeWord path — the ring keeps recording between the
    /// detection and the socket opening, so nothing said is lost).
    private let preludeFrom: Date?
    /// Hedged guess at who woke her ("sounds like Nick"), from VoiceID.
    private let speakerHint: String?

    init(engine: VoiceEngine, firstUtterance: String? = nil, preludeAudio: Data? = nil,
         preludeFrom: Date? = nil, speakerHint: String? = nil) {
        self.engine = engine
        self.firstUtterance = firstUtterance
        self.preludeAudio = preludeAudio
        self.preludeFrom = preludeFrom
        self.speakerHint = speakerHint
        self.sendFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: engine.sendSampleRate,
            channels: 1, interleaved: true)!
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        guard let key = Self.loadKey(engine.keyName) else {
            NSLog("Neon voice: \(engine.keyName) not found in ~/.config/neon/secrets.env")
            trace("error", "\(engine.keyName) missing from secrets.env")
            DispatchQueue.main.async { self.onClosed("no key") }
            return
        }
        trace("session", "connecting · \(engine.name) \(engine.model)")
        var request = URLRequest(url: engine.url(key: key))
        for (k, v) in engine.headers(key: key) { request.setValue(v, forHTTPHeaderField: k) }
        let task = URLSession.shared.webSocketTask(with: request)
        ws = task
        task.resume()
        receiveLoop()
        var system = Self.system
        // What she can do beyond being herself. Each switched-on plugin
        // contributes a paragraph next to the tools it declares, so the prompt
        // and the tool surface can never disagree about what exists.
        let plugins = PluginRegistry.shared.active
        for fragment in plugins.compactMap(\.promptFragment) {
            system += "\n\n\(fragment)"
        }
        if !plugins.isEmpty {
            trace("session", "plugins: " + plugins.map(\.id).joined(separator: ", "))
        }
        // Household facts live outside the repo (~/.config/neon/profile.md).
        let profilePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/neon/profile.md")
        if let profile = try? String(contentsOf: profilePath, encoding: .utf8),
           !profile.isEmpty {
            system += "\n\nAbout the people you live with (from Nick):\n\(profile)"
        }
        // Where and when, resolved fresh per session: a model's cutoff is not
        // today, and "what's the weather" needs a city.
        if let here = LocationProvider.shared.promptLine() {
            system += "\n\n\(here)"
        }
        // Who woke her, hedged on purpose: this is a guess from a few seconds
        // of far-field audio, and being confidently wrong about a name is
        // worse than not knowing.
        if let speakerHint {
            system += """


                Whoever just spoke \(speakerHint). That's a guess from a few \
                seconds of audio, useful for warmth and nothing else: greet \
                them by name if it fits, otherwise keep it to yourself, and \
                drop it entirely if what they say suggests otherwise. It is \
                never a reason to withhold anything, verify anyone, or treat a \
                request as suspicious — everyone in this house is family, \
                including the ones you can't place today.
                """
        }
        MemoryStore.shared.reloadIfChanged()   // a dream may have rewritten it
        // Memory arrives two ways. The digest is what she carries into every
        // conversation without being asked — recent and often-used facts.
        if let digest = MemoryStore.shared.digest() {
            // Log what she starts the conversation already knowing. Without
            // this it's impossible to tell "she recalled nothing" from "she
            // didn't need to" — the digest answers most questions before a
            // recall would ever be called.
            trace("memory", "digest: \(digest.split(separator: "\n").count) "
                + "memories in the prompt")
            system += """


                Things you remember (you wrote these down yourself; treat them \
                as known, don't recite them unprompted):
                \(digest)
                """
        }
        // And when the wake phrase came with words attached, those words are
        // the best query we will ever have for this conversation — search on
        // them now, so the answer to "what did I say about the tennis thing?"
        // is already in front of her rather than a tool call away.
        if let opening = firstUtterance {
            let hits = MemoryStore.shared.search(opening, limit: 3)
                .filter { digestMisses($0, in: system) }
            if !hits.isEmpty {
                trace("memory", "wake search \"\(opening.prefix(40))\" — "
                    + "\(hits.count) added beyond the digest")
                system += "\n\nPossibly relevant to what they're about to ask:\n"
                    + hits.map { "- \($0.text)" }.joined(separator: "\n")
            }
        }
        if let recent = ConversationLog.shared.recentContext() {
            system += """


                Recent conversations with Nick, oldest first — use them for \
                continuity (things he told you, asked for, or mentioned) but \
                don't recite or reference them unprompted:
                \(recent)
                """
        }
        for msg in engine.openMessages(system: system,
                                       tools: coreTools + PluginRegistry.shared.activeTools) {
            sendJSON(msg)
        }
        bumpIdle()
        NSLog("Neon voice: connecting to \(engine.name) (\(engine.model))")
    }

    func close(reason: String) {
        guard !closed else { return }
        closed = true
        NSLog("Neon voice: closing (\(reason)) — \(costLine())")
        trace("session", String(format: "closed · %@ · $%.4f", reason, currentCost()))
        idleTimer?.invalidate()
        sleepTimer?.invalidate()
        dozeTimer?.invalidate()
        turnWatchdog?.invalidate()
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

    /// Hand the model something to say mid-conversation that nobody in the
    /// room said — a timer going off, a task finishing. Arrives as a user turn
    /// because that's the only role the live API takes after setup; the system
    /// prompt tells her these are events to relay, not speech to answer.
    /// Returns false when this session can't carry the note — closing, or
    /// already asked to sleep. The caller has to know: a dropped announcement
    /// is a task result nobody ever hears, which is exactly what happened when
    /// a task landed in the moment between `go_to_sleep` and the socket
    /// closing.
    @discardableResult
    func inject(_ note: String) -> Bool {
        guard !closed, !sleepRequested else { return false }
        // Before setup completes there is nothing to inject into; hold it and
        // send once the session is ready.
        guard ready else {
            pendingNotes.append(note)
            return true
        }
        trace("task", "injected: \(note)")
        for m in engine.readyMessages(greeting: note) { sendJSON(m) }
        bumpIdle()
        return true
    }

    /// External evidence that someone in the room is talking (the wake
    /// listener's recognizer produced a partial). Far more distance-tolerant
    /// than the mic RMS gate; keeps the idle/doze logic from hanging up on
    /// quiet or far-away speakers.
    func noteVoiceActivity() {
        lastVoiceAt = Date()
    }

    /// Don't print a memory twice when the digest already carried it.
    private func digestMisses(_ m: Memory, in prompt: String) -> Bool {
        !prompt.contains(m.text)
    }

    private func trace(_ kind: String, _ text: String) {
        DispatchQueue.main.async { self.onEvent(kind, text) }
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
        let events = engine.parse(msg)
        // Keepalive-ish traffic (session resumption handles, usage metadata)
        // must not read as "she is still talking" — see isServerWorking.
        if events.contains(where: \.isServerWorking) { lastServerAt = Date() }
        if events.isEmpty { noteUnrecognisedFrame(msg) }
        for event in events {
            switch event {
            case .ready:
                NSLog("Neon voice: session ready")
                trace("session", "ready")
                ready = true
                defer {
                    let held = pendingNotes
                    pendingNotes = []
                    for note in held { inject(note) }
                }
                if let cmd = firstUtterance { record("Nick", cmd) }
                let resolvedPrelude = preludeAudio
                    ?? preludeFrom.map { AudioRing.shared.audio(since: $0) }
                if let prelude = resolvedPrelude, engine.sendSampleRate == 16000,
                   ProcessInfo.processInfo.environment["NEON_WAKE_AUDIO"] != "0" {
                    // Flush the wake utterance's real audio (validated by
                    // gemini-fastflush-test.mjs: server VAD copes with a
                    // faster-than-realtime burst). Before startAudio so live
                    // mic chunks can't interleave into the past.
                    NSLog("Neon voice: flushing %.1fs wake audio",
                          Double(prelude.count) / 32000.0)
                    trace("wake", String(format: "flushed %.1fs of wake audio",
                                         Double(prelude.count) / 32000.0))
                    for start in stride(from: 0, to: prelude.count, by: 32000) {
                        let chunk = prelude.subdata(in: start..<min(start + 32000, prelude.count))
                        sendJSON(engine.audioMessage(chunk.base64EncodedString()))
                    }
                } else {
                    let opening = firstUtterance ?? Self.greeting
                    pendingTurnText = opening
                    for m in engine.readyMessages(greeting: opening) { sendJSON(m) }
                }
                // The opening turn can be abandoned like any other — that is
                // the failure that looks worst, because she wakes, says
                // nothing, and dozes without ever having been asked anything.
                armTurnWatchdog()
                startAudio()
            case .audio(let data):
                lastAudioAt = Date()
                answerStarted()
                if thinkingActive { thinkingActive = false; onThinking(false) }
                enqueuePlayback(data)
                bumpIdle()
            case .thinking:
                answerStarted()
                if !thinkingActive {
                    NSLog("Neon voice: thinking…")
                    trace("think", "thinking…")
                    thinkingActive = true
                    onThinking(true)
                }
                bumpIdle()
            case .inputText(let t):
                NSLog("Neon voice: heard: \(t)")
                heard += heard.isEmpty || t.hasPrefix(" ") ? t : " \(t)"
                record("Nick", t)
                trace("you", t)
                // She has been given words to answer. From here the model owes
                // a turn, and the watchdog holds it to that.
                pendingTurnText += pendingTurnText.isEmpty || t.hasPrefix(" ") ? t : " \(t)"
                armTurnWatchdog()
                bumpIdle()
            case .outputText(let t):
                NSLog("Neon voice: saying: \(t)")
                answerStarted()
                // Gemini live sometimes verbalizes the tool call into the
                // audio channel (observed: "do_call:go_to_sleep{}") instead
                // of emitting a real toolCall. Treat the leak as the call.
                if t.contains(sleepToolName) || t.contains("do_call") {
                    NSLog("Neon voice: tool-call leak in speech; treating as \(sleepToolName)")
                    trace("tool", "spoken tool-call leak → \(sleepToolName)")
                    requestSleep()
                } else {
                    record("Neon", t)
                    trace("neon", t)
                }
            case .toolCall(let name, let id, let args):
                NSLog("Neon voice: tool call: \(name) \(args)")
                answerStarted()
                if name == sleepToolName {
                    trace("tool", "\(name)()")
                    requestSleep()
                }
                else if name == captureToolName { handleCapture(id: id) }
                else if name == rememberToolName {
                    let fact = (args["fact"] as? String) ?? ""
                    let saved = MemoryStore.shared.remember(fact)
                    trace("memory", saved == nil ? "already knew: \(fact)" : "remembered: \(fact)")
                    if let resp = engine.toolResponseMessage(
                        id: id, name: name,
                        result: saved == nil ? "Already knew that — kept the fuller version."
                                             : "Saved.") {
                        sendJSON(resp)
                    }
                }
                else if name == recallToolName {
                    let query = (args["query"] as? String) ?? ""
                    let hits = MemoryStore.shared.search(query)
                    trace("memory", "recall \"\(query)\" — \(hits.count) hit\(hits.count == 1 ? "" : "s")")
                    let result = hits.isEmpty
                        ? "Nothing remembered about that."
                        : hits.map { "- \($0.text)" }.joined(separator: "\n")
                    if let resp = engine.toolResponseMessage(id: id, name: name, result: result) {
                        sendJSON(resp)
                    }
                }
                else if name == emoteToolName {
                    let emotion = (args["emotion"] as? String) ?? "happy"
                    trace("emote", emotion)
                    onEmote(emotion)
                    if let resp = engine.toolResponseMessage(id: id, name: name, result: "done") {
                        sendJSON(resp)
                    }
                }
                // Everything else belongs to a plugin. Nothing is dispatched
                // that wasn't declared, so a name arriving here that no active
                // plugin owns is the model inventing a capability — say so
                // rather than going silent, which reads to the model as a tool
                // that hung.
                else if let plugin = PluginRegistry.shared.owner(ofTool: name) {
                    let context = PluginContext(requester: speakerHint) { [weak self] kind, text in
                        self?.trace(kind, text)
                    }
                    plugin.handle(tool: name, args: args, context: context) { [weak self] result in
                        DispatchQueue.main.async {
                            guard let self, !self.closed else { return }
                            if let resp = self.engine.toolResponseMessage(
                                id: id, name: name, result: result) { self.sendJSON(resp) }
                        }
                    }
                }
                else {
                    NSLog("Neon voice: no plugin owns tool \(name)")
                    trace("error", "unknown tool \(name)")
                    if let resp = engine.toolResponseMessage(
                        id: id, name: name,
                        result: "You don't have that tool — it isn't switched on. "
                              + "Tell them plainly you can't do that.") {
                        sendJSON(resp)
                    }
                }
            case .interrupted:
                trace("session", "interrupted — playback dropped")
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
                self.sleepTimer?.invalidate()
                // Small margin so the very last samples clear the hardware.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.close(reason: "tool")
                }
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
        // Frames are only *captured* continuously; they're sent to the model
        // solely on a capture_image tool call. (Streaming 1 FPS burned ~250
        // tokens per frame for imagery the model rarely needed.)
        cam.onFrame = { [weak self] b64 in
            self?.latestFrame = b64
        }
        camera = cam
        cam.start()
    }

    /// Delivering the frame is an ordering problem, not a plumbing one.
    ///
    /// Sending it as `realtimeInput.video` alongside the tool response — the
    /// obvious reading of the API — loses a race: the tool response starts
    /// generation and the frame lands after, so she answers from the system
    /// prompt instead of the picture. In the kitchen that looked like her
    /// describing the kitchen while the camera pointed at the porch, then
    /// getting it right the moment she was asked "are you sure?".
    ///
    /// `voice/gemini-image-order-test.mjs` settled it against the same model:
    /// answer the tool with "wait for it", then send the photo as its own
    /// completed user turn. The tool response still triggers a turn, but the
    /// model says nothing in it, and the reply that follows is about the
    /// actual image.
    private func handleCapture(id: String?) {
        onCapture()   // eyes narrow and focus, whether or not a frame exists
        guard let frame = latestFrame,
              let turn = engine.imageTurnMessage(frame, text: capturePrompt(for: frame)) else {
            NSLog("Neon voice: capture_image — no frame available")
            trace("tool", "capture_image → no frame available")
            if let resp = engine.toolResponseMessage(
                id: id, name: captureToolName, result: "Camera unavailable right now.") {
                sendJSON(resp)
            }
            return
        }
        NSLog("Neon voice: capture_image — sending frame (\(frame.count / 1024) KB)")
        trace("tool", "capture_image → frame sent (\(frame.count / 1024) KB)")
        if let resp = engine.toolResponseMessage(
            id: id, name: captureToolName,
            result: "The photo is coming in the very next message. Say nothing "
                  + "until you have seen it, then answer from what is actually in it.") {
            sendJSON(resp)
        }
        sendJSON(turn)
    }

    /// Text riding alongside the photo, including who the face looks like —
    /// decided locally, and hedged the same way the voice hint is.
    private func capturePrompt(for frame: String) -> String {
        var text = "Here is the photo from your camera, taken just now. Describe "
            + "what is actually in it — don't assume you're in the kitchen."
        if !PersonStore.shared.people.isEmpty,
           let image = FaceID.image(fromBase64JPEG: frame),
           let who = FaceID.shared.describe(in: image) {
            trace("who", "face: \(who.phrase ?? "no match") · \(who.detail)")
            if let phrase = who.phrase {
                text += " The face in it \(phrase) — treat that as a guess, the "
                     + "way you would recognizing someone across a room."
            }
        }
        return text
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
        // .dataPlayedBack: fire when the audio has actually left the speaker.
        // The default (.dataConsumed) fires when the mixer *reads* the buffer
        // — up to a chunk early — which made tool-closes clip goodbyes.
        player.scheduleBuffer(buffer, at: nil, options: [],
                              completionCallbackType: .dataPlayedBack) { [weak self] _ in
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

    // MARK: - Abandoned turns

    /// How long to let a turn the model has taken input for stay unanswered.
    ///
    /// Measured before it was chosen, because guessing got it wrong: ordinary
    /// first-speech latency on 3.1-flash-live is **4.4–8.3 s** from setup
    /// (five sessions, 2026-08-05), far slower than it feels in the kitchen. A
    /// six-second window would have retried most healthy turns and had her
    /// talk over herself, which is worse than the fault it fixes. Ten clears
    /// the slowest measured turn with margin.
    ///
    /// `NEON_DEAD_TURN_SECS` forces it short, which is the only way to see the
    /// retry fire on demand — the fault it exists for is the server's and
    /// can't be provoked.
    private static let deadTurnSeconds: TimeInterval =
        ProcessInfo.processInfo.environment["NEON_DEAD_TURN_SECS"].flatMap(Double.init) ?? 10

    /// Is the model still on the hook for an answer?
    private var turnOwed: Bool { turnWatchdog != nil }

    /// The model produced something, so it hasn't abandoned the turn.
    private func answerStarted() {
        turnWatchdog?.invalidate()
        turnWatchdog = nil
        pendingTurnText = ""
        retriedTurn = false
    }

    private func armTurnWatchdog() {
        DispatchQueue.main.async {
            self.turnWatchdog?.invalidate()
            self.turnWatchdog = Timer.scheduledTimer(
                withTimeInterval: Self.deadTurnSeconds, repeats: false
            ) { [weak self] _ in
                self?.checkAbandonedTurn()
            }
        }
    }

    private func checkAbandonedTurn() {
        // The timer has fired, so the stored reference is spent — clear it
        // before any early return, or `turnOwed` stays true forever and the
        // idle close it defers never happens.
        turnWatchdog = nil
        guard !closed, ready, !sleepRequested else { return }
        // Anything that means she is working — a thought part, audio already
        // playing, a tool round trip — and this is not an abandoned turn at
        // all. `lastServerAt` only moves for real work (see isServerWorking),
        // which is exactly the distinction needed here.
        guard pendingPlaybacks == 0, !thinkingActive,
              Date().timeIntervalSince(lastServerAt) >= Self.deadTurnSeconds - 1 else {
            armTurnWatchdog()
            return
        }
        // An abandoned wake-audio turn leaves nothing transcribed to replay,
        // so fall back to the ordinary opener rather than giving up on a turn
        // that was never spoken aloud in text.
        var question = pendingTurnText.trimmingCharacters(in: .whitespacesAndNewlines)
        if question.isEmpty { question = Self.greeting }
        if !retriedTurn {
            // Ask it again in the model's own words. It transcribed the room
            // correctly — it simply never answered — so replaying the
            // transcript as a user turn asks the question that was actually
            // asked, rather than a vague "are you there?".
            retriedTurn = true
            NSLog("Neon voice: no answer after %.0fs — retrying the turn", Self.deadTurnSeconds)
            trace("api", "model went silent — asking again")
            for m in engine.readyMessages(greeting: question) { sendJSON(m) }
            bumpIdle()
            armTurnWatchdog()
            return
        }
        // Twice is enough. Closing puts her back to the wake word, which is a
        // fresh socket and reliably works, instead of leaving her sat there
        // looking awake and hearing nothing.
        NSLog("Neon voice: model silent through a retry; closing so the next wake starts clean")
        trace("api", "model never answered — closing")
        close(reason: "model silent")
    }

    /// Frames the engine didn't understand used to vanish here, which is how a
    /// stalled turn managed to look like an empty room for a whole release.
    ///
    /// Reported once per *shape* per session, and the shape reaches one level
    /// into `serverContent` — otherwise every session logs a line, because two
    /// shapes are ordinary protocol traffic rather than surprises: the
    /// twice-a-second `sessionResumptionUpdate`, and a bare empty
    /// `serverContent`, which turns up in perfectly healthy sessions and
    /// carries nothing to learn from. Anything else is worth seeing.
    private func noteUnrecognisedFrame(_ msg: [String: Any]) {
        var keys = msg.keys.sorted()
        guard !keys.isEmpty, keys != ["sessionResumptionUpdate"] else { return }
        if keys == ["serverContent"] {
            let inner = (msg["serverContent"] as? [String: Any])?.keys.sorted() ?? []
            if inner.isEmpty { return }
            keys = ["serverContent{\(inner.joined(separator: ","))}"]
        }
        let shape = keys.joined(separator: "+")
        guard loggedFrameShapes.insert(shape).inserted else { return }
        var detail = ""
        if let data = try? JSONSerialization.data(withJSONObject: msg) {
            detail = String(decoding: data, as: UTF8.self)
            if detail.count > 300 { detail = String(detail.prefix(300)) + "…" }
        }
        NSLog("Neon voice: unrecognised frame {\(shape)} \(detail)")
        trace("api", "unrecognised frame: \(shape)")
    }

    // MARK: - Idle timeout

    private func bumpIdle() {
        DispatchQueue.main.async {
            if self.dozing { self.exitDoze() }
            self.idleTimer?.invalidate()
            self.idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleSeconds, repeats: false) { [weak self] _ in
                guard let self else { return }
                // Never time out while a reply is still playing, while someone
                // in the room is mid-sentence, while she is reasoning, or while
                // the server is still working on an answer. Nick caught her
                // dozing off mid-thought: thought parts reset this clock, but
                // MEDIUM thinking can leave a gap longer than the timeout
                // between them, and silence from the model is not silence from
                // the room.
                //
                // "Working" is deliberately narrower than "sent us a frame":
                // Gemini's session-resumption keepalives arrive twice a second
                // forever, and counting those kept her awake indefinitely.
                if self.pendingPlaybacks > 0
                    || Date().timeIntervalSince(self.lastVoiceAt) < 1.5
                    || self.thinkingActive
                    || Date().timeIntervalSince(self.lastServerAt) < 3 {
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
        guard !dozing, !closed, !sleepRequested, !thinkingActive else { return }
        dozing = true
        NSLog("Neon voice: dozing (grace window)")
        trace("sleep", "idle \(Int(Self.idleSeconds))s — dozing (grace window)")
        onDoze(true)
        let started = Date()
        dozeTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, !self.closed else { return }
            if Date().timeIntervalSince(self.lastVoiceAt) < 0.4 {
                self.exitDoze()
                self.bumpIdle()
            } else if Date().timeIntervalSince(started) > 5.2 {
                // Don't hang up on a turn she still owes an answer to. A slow
                // turn can outlast the whole doze window (measured up to
                // 8.3 s against a 5 s + 5.2 s close), so closing here would
                // cut off replies that were simply late — and would pre-empt
                // the retry that exists for the ones that never come. The
                // watchdog resolves it either way, so this can't hang open.
                guard !self.turnOwed else { return }
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
        trace("wake", "doze interrupted — still being spoken to")
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

    /// `billed: false` is work that runs against Nick's Claude subscription
    /// rather than an API key. The CLI still reports `total_cost_usd` — an
    /// API-equivalent figure, not a charge — so counting it in the lifetime
    /// total would inflate real spend with money nobody is spending. It stays
    /// visible per-engine because the number is still a useful sense of scale.
    func record(engine: String, cost: Double, billed: Bool = true) {
        if billed { total += cost }
        byEngine[engine, default: 0] += cost
        let obj: [String: Any] = ["total": total, "byEngine": byEngine]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) {
            try? data.write(to: path)
        }
    }
}
