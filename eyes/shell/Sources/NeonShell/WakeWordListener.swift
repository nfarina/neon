import AVFoundation
import Speech

// Raw stderr breadcrumbs — NSLog output was not reliably observable.
func dbg(_ s: String) {
    FileHandle.standardError.write(Data("NEON \(s)\n".utf8))
}

// Wake-word detection via continuous on-device speech recognition.
//
// This is deliberately the simplest thing that works: transcribe the room
// and fuzzy-match the transcript for "hey neon". If false accepts/misses
// become annoying, swap this class for a purpose-built wake-word engine
// (e.g. Picovoice Porcupine) — the only contract is `onWake`.

final class WakeWordListener: NSObject {
    var onWake: () -> Void = {}
    /// Streams the recognizer's running transcript (for the debug overlay).
    var onTranscript: (String) -> Void = { _ in }

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var rollover: Timer?
    private var restarting = false
    private var active = false
    private var consumerId: UUID?

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
                    if Self.containsWakePhrase(text) {
                        NSLog("Neon: wake phrase heard in \"\(text)\"")
                        self.onWake()
                        self.restart(after: 0.2)  // clear transcript so it can't re-trigger
                        return
                    }
                    if result.isFinal {
                        self.restart(after: 0.3)
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

    static func containsWakePhrase(_ text: String) -> Bool {
        // Tolerate common mis-hearings of "hey neon".
        // "neon" is a dictionary word, so the recognizer usually gets it
        // right; the rest are plausible mis-hearings observed or anticipated.
        // The recognizer sometimes fuses the whole phrase into one token —
        // observed live: "Hey Neon" -> "Henon".
        let pattern = #"\b(hey|hay|hi|a)[,.]?\s+(neon|neo|nion|nian|neyon|leon|knee on|neo n)\b|\b(henon|heynon|hanon|heneon|haynon)\b"#
        return text.lowercased().range(of: pattern, options: .regularExpression) != nil
    }
}
