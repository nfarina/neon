import AVFoundation
import CoreImage

// Low-rate camera capture for the voice session: one JPEG frame per second
// while a conversation is open, delivered as base64 for realtimeInput.video.
// The camera runs only during sessions (privacy + token cost); a session
// works fine audio-only if the camera is denied or absent.
final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFrame: (String) -> Void = { _ in }  // base64 JPEG

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "neon.camera")
    private let ciContext = CIContext()
    private var lastSent = Date.distantPast
    private var frames = 0
    private static let interval: TimeInterval = 1.0

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            dbg("camera auth: \(granted)")
            guard granted, let self else { return }
            self.queue.async { self.configure() }
        }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    private func configure() {
        if session.inputs.isEmpty {
            session.sessionPreset = .vga640x480
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                dbg("camera unavailable")
                return
            }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings =
                [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
        }
        session.startRunning()
        dbg("camera running")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastSent) >= Self.interval,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastSent = now
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let quality = CIImageRepresentationOption(
            rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let jpeg = ciContext.jpegRepresentation(
            of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [quality: 0.6])
        else { return }
        frames += 1
        if frames % 15 == 1 { dbg("camera frame \(frames) (\(jpeg.count / 1024) KB)") }
        onFrame(jpeg.base64EncodedString())
    }
}
