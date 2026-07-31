import AVFoundation

// Rolling buffer of the last ~20 s of mic audio (16 kHz mono int16, the
// Gemini send format). Always capturing via AudioHub, so a wake can flush
// the *actual audio* of "Neon, ..." into the session instead of relying on
// Apple's transcription of it. Faster-than-realtime flush is validated by
// voice/gemini-fastflush-test.mjs.
final class AudioRing {
    static let shared = AudioRing()

    private let lock = NSLock()
    private var chunks: [(at: Date, data: Data)] = []
    private var converter: AVAudioConverter?
    private var consumerId: UUID?
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private static let keepSeconds: TimeInterval = 20

    func start() {
        guard consumerId == nil else { return }
        let hub = AudioHub.shared
        guard let tapFormat = hub.tapFormat else { return }
        converter = AVAudioConverter(from: tapFormat, to: format)
        consumerId = hub.addConsumer { [weak self] buffer in self?.capture(buffer) }
        dbg("audio ring recording")
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = 16000.0 / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
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
        lock.lock()
        chunks.append((Date(), data))
        let cutoff = Date().addingTimeInterval(-Self.keepSeconds)
        while let first = chunks.first, first.at < cutoff { chunks.removeFirst() }
        lock.unlock()
    }

    /// All captured audio from `since` to now (capped so pre-name chatter
    /// can't balloon the flush).
    func audio(since: Date, cap: TimeInterval = 12) -> Data {
        lock.lock()
        defer { lock.unlock() }
        let start = max(since, Date().addingTimeInterval(-cap))
        var out = Data()
        for c in chunks where c.at >= start { out.append(c.data) }
        return out
    }
}
