import AVFoundation

// One persistent audio engine shared by the wake listener and voice sessions.
// A single engine means the microphone never changes hands (no CoreAudio
// handoff races), and voice processing — echo cancellation — is enabled once
// at startup, before the graph is built, which is what its initialization
// demands. AEC is what makes barge-in possible: it subtracts our own speaker
// output from the mic signal, and it can only do that when capture and
// playback share an engine.
final class AudioHub {
    static let shared = AudioHub()

    let player = AVAudioPlayerNode()
    private(set) var voiceProcessing = false
    private(set) var tapFormat: AVAudioFormat?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var consumers: [UUID: (AVAudioPCMBuffer) -> Void] = [:]
    private var started = false
    private var playerAttached = false

    /// Idempotent; call only after microphone permission is granted.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
            voiceProcessing = true
        } catch {
            dbg("hub: voice processing enable failed (\(error.localizedDescription)); using half-duplex fallback")
        }
        let nodeFormat = input.outputFormat(forBus: 0)
        // With voice processing on, the input node reports the raw mic array
        // (4ch on this MacBook); tap in mono at the node's sample rate.
        let format = AVAudioFormat(standardFormatWithSampleRate: nodeFormat.sampleRate, channels: 1)!
        tapFormat = format
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            let sinks = Array(self.consumers.values)
            self.lock.unlock()
            for sink in sinks { sink(buffer) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            dbg("hub: engine failed to start: \(error.localizedDescription)")
        }
        dbg("hub: running=\(engine.isRunning) vp=\(voiceProcessing) format=\(format)")
        // A configuration change silently stops the tap; rebuild on it.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            dbg("hub: configuration changed — rebuilding")
            self?.restart()
        }
    }

    /// Attach the playback node lazily, after the engine is running: doing
    /// this while building the graph breaks voice-processing initialization
    /// (CoreAudio -10875), but a live attachment is fine.
    func ensurePlayer() {
        guard !playerAttached else { player.play(); return }
        playerAttached = true
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!)
        player.play()
        dbg("hub: player attached (engine running=\(engine.isRunning))")
    }

    /// Tear the engine down and build it again. AVAudioEngine stops
    /// delivering tap buffers on a configuration change (device added or
    /// removed, sample rate changed) without reporting an error to anyone,
    /// and the only cure is a rebuild.
    func restart() {
        guard started else { return }
        dbg("hub: restarting")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        started = false
        playerAttached = false
        startIfNeeded()
    }

    func addConsumer(_ sink: @escaping (AVAudioPCMBuffer) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); consumers[id] = sink; lock.unlock()
        return id
    }

    func removeConsumer(_ id: UUID?) {
        guard let id else { return }
        lock.lock(); consumers.removeValue(forKey: id); lock.unlock()
    }
}
