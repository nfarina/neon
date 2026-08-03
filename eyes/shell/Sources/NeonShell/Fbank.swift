import Accelerate
import Foundation

// Kaldi-compatible 80-bin log-mel filterbank features.
//
// Speaker-embedding models (CAM++, WeSpeaker, TitaNet) all take features
// rather than waveform — sherpa-onnx and friends do this step outside the
// ONNX graph, so a Swift host has to do it too. The constants below are
// Kaldi's defaults, which is what these models were trained on; they are not
// adjustable knobs. Getting any of them wrong produces embeddings that look
// plausible and match nothing.
//
// (openWakeWord's melspectrogram.onnx can't be reused here: 32 bins, its own
// scaling, a different window — a different feature space entirely.)
enum Fbank {
    static let sampleRate = 16000.0
    static let frameLength = 400        // 25 ms
    static let frameShift = 160         // 10 ms
    static let fftSize = 512
    static let melBins = 80
    static let lowFreq = 20.0
    static let preemphasis: Float = 0.97

    /// Povey window: Hann raised to 0.85, Kaldi's default for this family.
    private static let window: [Float] = {
        (0..<frameLength).map { i in
            let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(frameLength - 1))
            return Float(pow(hann, 0.85))
        }
    }()

    private static func hzToMel(_ hz: Double) -> Double { 1127.0 * log(1.0 + hz / 700.0) }
    private static func melToHz(_ mel: Double) -> Double { 700.0 * (exp(mel / 1127.0) - 1.0) }

    /// Triangular mel filters over the power-spectrum bins.
    private static let filters: [[Float]] = {
        let bins = fftSize / 2 + 1
        let highFreq = sampleRate / 2
        let melLow = hzToMel(lowFreq), melHigh = hzToMel(highFreq)
        let step = (melHigh - melLow) / Double(melBins + 1)
        return (0..<melBins).map { m in
            let left = melToHz(melLow + Double(m) * step)
            let center = melToHz(melLow + Double(m + 1) * step)
            let right = melToHz(melLow + Double(m + 2) * step)
            return (0..<bins).map { b -> Float in
                let f = Double(b) * sampleRate / Double(fftSize)
                if f <= left || f >= right { return 0 }
                return Float(f <= center ? (f - left) / (center - left)
                                         : (right - f) / (right - center))
            }
        }
    }()

    private static let fft = vDSP_create_fftsetup(vDSP_Length(log2(Double(fftSize))), FFTRadix(kFFTRadix2))!

    /// Samples are int16-range floats (what AudioRing and the wake pipeline
    /// carry). Returns `[frames][80]`, mean-normalized over time — CAM++ ships
    /// with feature_normalize_type "mean", and skipping it costs real accuracy.
    static func features(_ samples: [Float]) -> [[Float]] {
        guard samples.count >= frameLength else { return [] }
        let frameCount = 1 + (samples.count - frameLength) / frameShift
        var out: [[Float]] = []
        out.reserveCapacity(frameCount)

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        let bins = fftSize / 2 + 1

        for f in 0..<frameCount {
            var frame = Array(samples[(f * frameShift)..<(f * frameShift + frameLength)])
            // Kaldi order: remove DC, pre-emphasize, then window.
            var mean: Float = 0
            vDSP_meanv(frame, 1, &mean, vDSP_Length(frameLength))
            var negMean = -mean
            vDSP_vsadd(frame, 1, &negMean, &frame, 1, vDSP_Length(frameLength))
            for i in stride(from: frameLength - 1, through: 1, by: -1) {
                frame[i] -= preemphasis * frame[i - 1]
            }
            frame[0] -= preemphasis * frame[0]
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(frameLength))

            var padded = frame + [Float](repeating: 0, count: fftSize - frameLength)
            var power = [Float](repeating: 0, count: bins)
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    padded.withUnsafeMutableBufferPointer { pp in
                        pp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                        }
                    }
                    vDSP_fft_zrip(fft, &split, 1, vDSP_Length(log2(Double(fftSize))), FFTDirection(FFT_FORWARD))
                    // vDSP packs Nyquist into imag[0] and scales by 2.
                    let nyquist = split.imagp[0] / 2
                    split.imagp[0] = 0
                    for b in 0..<(fftSize / 2) {
                        let re = split.realp[b] / 2, im = split.imagp[b] / 2
                        power[b] = re * re + im * im
                    }
                    power[fftSize / 2] = nyquist * nyquist
                }
            }

            var melFrame = [Float](repeating: 0, count: melBins)
            for m in 0..<melBins {
                var energy: Float = 0
                vDSP_dotpr(power, 1, filters[m], 1, &energy, vDSP_Length(bins))
                melFrame[m] = log(max(energy, .leastNormalMagnitude))
            }
            out.append(melFrame)
        }

        // Cepstral mean normalization over the utterance.
        guard !out.isEmpty else { return out }
        for d in 0..<melBins {
            var sum: Float = 0
            for frame in out { sum += frame[d] }
            let mean = sum / Float(out.count)
            for i in out.indices { out[i][d] -= mean }
        }
        return out
    }
}
