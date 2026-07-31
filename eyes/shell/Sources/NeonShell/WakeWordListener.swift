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
    /// Fired on the wake phrase; the argument is what was said after the
    /// name (nil if the name was said on its own).
    var onWake: (String?) -> Void = { _ in }
    /// Streams the recognizer's running transcript (for the debug overlay).
    var onTranscript: (String) -> Void = { _ in }

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
    private var lastPartialAt = Date.distantPast
    private var priorWordCount = 0
    private var burstStart = 0          // word index where the current utterance began
    private var commandStart: Int?      // word index just past the name, once heard
    private var pendingPoll: Timer?
    private var pendingDeadline = Date.distantFuture
    private var latestWords: [String] = []

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
        commandStart = nil
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
        priorWordCount = 0
        burstStart = 0
        commandStart = nil
        latestWords = []
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
                        if self.commandStart != nil { self.fireWake() }
                        else { self.restart(after: 0.3) }
                        return
                    }
                }
                if let error = error as NSError? {
                    // Includes the routine "no speech detected" timeout — just begin again.
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
        "neon", "neons", "neo", "nion", "nian", "neyon", "leon",
    ]
    /// "hey neon" still works; the recognizer sometimes fuses it into one
    /// token — observed live: "Hey Neon" -> "Henon".
    private static let heyWords: Set<String> = ["hey", "hay", "hi", "ok", "okay"]
    private static let fusedWords: Set<String> = ["henon", "heynon", "hanon", "heneon", "haynon"]

    private static let utteranceGap: TimeInterval = 0.7   // silence that starts a new utterance
    private static let trailingSilence: TimeInterval = 0.85  // quiet after the name/command = go
    private static let maxCommandWait: TimeInterval = 6   // fire with what we have by then

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

    private func handlePartial(_ text: String) {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let now = Date()
        // A quiet gap since the last partial marks an utterance boundary.
        if now.timeIntervalSince(lastPartialAt) > Self.utteranceGap {
            burstStart = min(priorWordCount, words.count)
        }
        lastPartialAt = now
        priorWordCount = words.count
        latestWords = words

        guard commandStart == nil else { return }  // already waiting for the command to finish
        if let end = Self.nameEnd(in: words, from: burstStart) {
            dbg("name heard at word \(burstStart); capturing command")
            commandStart = end
            pendingDeadline = now.addingTimeInterval(Self.maxCommandWait)
            pendingPoll?.invalidate()
            pendingPoll = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                guard let self else { return }
                let idle = Date().timeIntervalSince(self.lastPartialAt)
                if idle > Self.trailingSilence || Date() > self.pendingDeadline {
                    self.fireWake()
                }
            }
        }
    }

    private func fireWake() {
        pendingPoll?.invalidate()
        pendingPoll = nil
        guard let start = commandStart else { return }
        commandStart = nil
        let command = latestWords.dropFirst(start).joined(separator: " ")
        NSLog("Neon: wake — command: \"\(command)\"")
        onWake(command.isEmpty ? nil : command)
        restart(after: 0.2)  // clear the transcript so it can't re-trigger
    }
}
