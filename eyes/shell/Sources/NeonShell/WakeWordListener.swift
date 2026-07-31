import AVFoundation
import Speech

// Wake-word detection via continuous on-device speech recognition.
//
// This is deliberately the simplest thing that works: transcribe the room
// and fuzzy-match the transcript for "hey neon". If false accepts/misses
// become annoying, swap this class for a purpose-built wake-word engine
// (e.g. Picovoice Porcupine) — the only contract is `onWake`.

final class WakeWordListener: NSObject {
    var onWake: () -> Void = {}

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var rollover: Timer?
    private var restarting = false

    func start() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                NSLog("Neon: speech recognition not authorized (status \(status.rawValue))")
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                guard granted else {
                    NSLog("Neon: microphone access denied")
                    return
                }
                DispatchQueue.main.async { self?.begin() }
            }
        }
    }

    private func begin() {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            NSLog("Neon: speech recognizer unavailable")
            return
        }
        if !recognizer.supportsOnDeviceRecognition {
            NSLog("Neon: on-device recognition unsupported; falling back to server-based")
        }
        self.recognizer = recognizer
        startEngine()
        startSession()
    }

    private func startEngine() {
        guard !engine.isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("Neon: audio engine failed to start: \(error)")
        }
    }

    private func startSession() {
        guard let recognizer else { return }
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
                if error != nil {
                    // Includes the routine "no speech detected" timeout — just begin again.
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
        guard !restarting else { return }
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
        // right; keep "neo" as a fallback for a clipped final n.
        let pattern = #"\b(hey|hay|hi|a)[,.]?\s+(neon|neo|nion)\b"#
        return text.lowercased().range(of: pattern, options: .regularExpression) != nil
    }
}
