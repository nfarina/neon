import AVFoundation
import Speech

// Raw stderr breadcrumbs — NSLog output was not reliably observable.
func dbg(_ s: String) {
    FileHandle.standardError.write(Data("NEON \(s)\n".utf8))
}

// Wake-word detection via continuous on-device speech recognition.
//
// The trigger is the name "Neon" at the start of an utterance: silence, then
// "neon" (or "hey neon"), optionally followed by more words. Words spoken
// after the name are captured until a short trailing silence and handed to
// `onWake` so the session can open with them as the first message ("Neon,
// set a timer" shouldn't require a greeting round trip).
//
// This is deliberately the simplest thing that works: if false accepts or
// misses become annoying, swap this class for a purpose-built wake-word
// engine (e.g. Picovoice Porcupine) — the only contract is `onWake`.

final class WakeWordListener: NSObject {
    /// Fired on the wake phrase: the transcribed words after the name (nil
    /// if the name was said alone) and the captured audio of the utterance
    /// itself, for engines that prefer hearing the real thing.
    var onWake: (String?, Data?) -> Void = { _, _ in }
    /// Fired the moment the name is spotted mid-utterance — the pre-wake
    /// cue: eyes open and listen while the speaker is still talking.
    var onNameHeard: () -> Void = {}
    /// The name candidate didn't survive (transcript revision); a pre-wake
    /// that onNameHeard signaled should stand down.
    var onWakeAborted: () -> Void = {}
    /// Streams the recognizer's running transcript (for the debug overlay).
    var onTranscript: (String) -> Void = { _ in }

    private var preWakeSignaled = false

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var rollover: Timer?
    private var restarting = false
    private var active = false
    private var consumerId: UUID?

    // Utterance tracking. Partial results arrive in rapid bursts while
    // someone is speaking and stop during silence, so a wall-clock gap
    // between partials marks an utterance boundary. (Segment timestamps
    // would be cleaner but are unreliable from on-device recognition.)
    //
    // `baseline` is the word list as of the last boundary. The current
    // utterance is everything past the common prefix of baseline and the
    // latest words — computed fresh each time, because the recognizer
    // *revises* earlier words rather than only appending (observed: junk
    // like "no" replaced wholesale by "Neon what's up", which breaks any
    // index latched earlier).
    private var lastPartialAt = Date.distantPast
    private var baseline: [String] = []
    private var latestWords: [String] = []
    private var pendingPoll: Timer?
    private var pendingDeadline = Date.distantFuture
    private var pendingNameEnd: Int?  // index past the name when first spotted
    private var utteranceStartedAt = Date.distantPast  // wall clock of the current burst's first partial

    func start() {
        active = true
        dbg("start(): speech=\(SFSpeechRecognizer.authorizationStatus().rawValue) mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3=authorized, 0=notDetermined)")
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            dbg("speech auth callback: \(status.rawValue)")
            guard status == .authorized else {
                NSLog("Neon wake: speech recognition not authorized")
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                dbg("mic auth callback: \(granted)")
                guard granted else { return }
                DispatchQueue.main.async { self?.begin() }
            }
        }
    }

    /// Stop listening (e.g. while a voice session is having a conversation).
    /// The shared engine keeps running; we just stop consuming from it.
    func stop() {
        active = false
        rollover?.invalidate()
        rollover = nil
        pendingPoll?.invalidate()
        pendingPoll = nil
        preWakeSignaled = false
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        AudioHub.shared.removeConsumer(consumerId)
        consumerId = nil
    }

    private func begin() {
        guard active else { return }
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            NSLog("Neon: speech recognizer unavailable")
            return
        }
        if !recognizer.supportsOnDeviceRecognition {
            NSLog("Neon: on-device recognition unsupported; falling back to server-based")
        }
        self.recognizer = recognizer
        AudioHub.shared.startIfNeeded()
        AudioRing.shared.start()  // wake-utterance capture rides the same hub
        consumerId = AudioHub.shared.addConsumer { [weak self] buffer in
            self?.request?.append(buffer)
        }
        startSession()
        dbg("listening (on-device: \(recognizer.supportsOnDeviceRecognition))")
    }

    private func startSession() {
        guard active, let recognizer else { return }
        restarting = false
        lastPartialAt = .distantPast
        baseline = []
        latestWords = []
        pendingNameEnd = nil
        pendingPoll?.invalidate()
        pendingPoll = nil
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    dbg("transcript: \(text)")
                    self.onTranscript(text)
                    self.handlePartial(text)
                    if result.isFinal {
                        if !self.evaluateUtterance() { self.restart(after: 0.3) }
                        return
                    }
                }
                if let error = error as NSError? {
                    // The recognizer's own end-of-utterance ("no speech
                    // detected") often beats the trailing-silence poll; a
                    // pending wake must be evaluated here, not thrown away.
                    if self.evaluateUtterance() { return }
                    NSLog("Neon wake: task error \(error.domain) \(error.code): \(error.localizedDescription)")
                    self.restart(after: 0.6)
                }
            }
        }
        // Periodically restart so the running transcript never grows unbounded.
        rollover?.invalidate()
        rollover = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            self?.restart(after: 0)
        }
    }

    private func restart(after delay: TimeInterval) {
        guard active, !restarting else { return }
        restarting = true
        rollover?.invalidate()
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.05)) { [weak self] in
            guard let self else { return }
            self.restarting = false
            self.startSession()
        }
    }

    // MARK: - Wake matching

    /// Words the recognizer produces for "neon". It's a dictionary word so
    /// it's usually right; the rest are observed or plausible mis-hearings.
    private static let nameWords: Set<String> = [
        "neon", "neons", "neo", "nion", "nian", "neyon", "leon", "nia",
    ]
    /// "hey neon" still works; the recognizer sometimes fuses it into one
    /// token — observed live: "Hey Neon" -> "Henon".
    private static let heyWords: Set<String> = ["hey", "hay", "hi", "ok", "okay"]
    private static let fusedWords: Set<String> = ["henon", "heynon", "hanon", "heneon", "haynon"]

    private static let utteranceGap: TimeInterval = 0.7   // silence that starts a new utterance
    private static let trailingSilence: TimeInterval = 0.85  // quiet after the name/command = go
    private static let maxCommandWait: TimeInterval = 12  // fire with what we have by then

    /// A deliberate "hey neon"-style summons *anywhere* in the current
    /// utterance (bare "neon" stays anchored to the utterance start so
    /// mid-sentence mentions don't wake her; "hey" + name is unambiguous).
    private static func heySummons(in words: [String], from start: Int) -> Int? {
        for i in start..<max(start, words.count) {
            if fusedWords.contains(words[i]) { return i + 1 }
            if heyWords.contains(words[i]), let end = nameEnd(in: words, from: i) { return end }
        }
        return nil
    }

    /// If an utterance starting at `start` opens with the name, return the
    /// index just past it (where a command would begin).
    private static func nameEnd(in words: [String], from start: Int) -> Int? {
        guard start < words.count else { return nil }
        let w0 = words[start]
        if nameWords.contains(w0) || fusedWords.contains(w0) || w0.hasPrefix("neon") { return start + 1 }
        if w0 == "knee", start + 1 < words.count, words[start + 1] == "on" { return start + 2 }
        if heyWords.contains(w0), start + 1 < words.count {
            if let end = nameEnd(in: words, from: start + 1) { return end }
        }
        return nil
    }

    private static func tokenize(_ text: String) -> [String] {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'"))
        return text.lowercased()
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }
    }

    private static func commonPrefix(_ a: [String], _ b: [String]) -> Int {
        var i = 0
        while i < a.count && i < b.count && a[i] == b[i] { i += 1 }
        return i
    }

    private func handlePartial(_ text: String) {
        let words = Self.tokenize(text)
        let now = Date()
        // A quiet gap since the last partial marks an utterance boundary.
        if now.timeIntervalSince(lastPartialAt) > Self.utteranceGap {
            baseline = latestWords
            utteranceStartedAt = now
        }
        lastPartialAt = now
        latestWords = words

        guard pendingPoll == nil else { return }  // already waiting for the utterance to finish
        let cut = Self.commonPrefix(baseline, words)
        if let end = Self.nameEnd(in: words, from: cut) ?? Self.heySummons(in: words, from: cut) {
            dbg("name candidate; waiting for end of utterance")
            preWakeSignaled = true
            pendingNameEnd = end
            onNameHeard()
            pendingDeadline = now.addingTimeInterval(Self.maxCommandWait)
            pendingPoll = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                guard let self else { return }
                let idle = Date().timeIntervalSince(self.lastPartialAt)
                if idle > Self.trailingSilence || Date() > self.pendingDeadline {
                    self.evaluateUtterance()
                }
            }
        }
    }

    /// The utterance appears to be over (trailing silence, recognizer final,
    /// or recognizer end-of-utterance error): if it began with the name,
    /// wake. Match is computed fresh from the latest transcript so recognizer
    /// revisions between detection and now can't strand a stale index.
    @discardableResult
    private func evaluateUtterance() -> Bool {
        pendingPoll?.invalidate()
        pendingPoll = nil
        guard active, !restarting else { return false }
        let cut = Self.commonPrefix(baseline, latestWords)
        var matched = Self.nameEnd(in: latestWords, from: cut)
            ?? Self.heySummons(in: latestWords, from: cut)
        if matched == nil, let seen = pendingNameEnd {
            // Long utterances give the recognizer time to revise words
            // *before* the name, which shifts the common-prefix boundary and
            // breaks the strict match. The name was validated at detection —
            // re-find it near where it first appeared.
            for i in max(0, seen - 5)..<min(latestWords.count, seen + 3) {
                if let e = Self.nameEnd(in: latestWords, from: i) { matched = e; break }
            }
        }
        pendingNameEnd = nil
        guard let end = matched else {
            baseline = latestWords  // utterance consumed; don't rematch it later
            if preWakeSignaled { preWakeSignaled = false; onWakeAborted() }
            dbg("name candidate lost after revision; standing down")
            return false
        }
        let command = latestWords.dropFirst(end).joined(separator: " ")
        NSLog("Neon: wake — command: \"\(command)\"")
        preWakeSignaled = false
        // The utterance's actual audio, starting a little before the first
        // partial (the recognizer lags the speech it transcribes).
        let prelude = command.isEmpty ? nil
            : AudioRing.shared.audio(since: utteranceStartedAt.addingTimeInterval(-1.5))
        onWake(command.isEmpty ? nil : command, prelude)
        restart(after: 0.2)  // clear the transcript so it can't re-trigger
        return true
    }
}
