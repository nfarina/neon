import CoreGraphics
import Foundation
import OnnxRuntimeBindings
import Vision

// Recognising faces: Apple's Vision finds them, ArcFace says who they are.
//
// Vision has no public face-identity API — VNGenerateFaceprintRequest is
// private, and VNGenerateImageFeaturePrintRequest is a general image
// descriptor that keys on lighting and background as much as identity, which
// is precisely wrong for telling twins apart. So detection and landmarks come
// from Vision (excellent, free, on-device) and the embedding comes from an
// ArcFace ONNX model — the same shape as the wake word and voice pipelines.
//
// Model: buffalo_s recognition (13 MB) in ~/.config/neon/faceid/.
final class FaceID {
    static let shared = FaceID()

    private var env: ORTEnv?
    private var session: ORTSession?

    /// Cosine threshold for a match. ArcFace embeddings separate much harder
    /// than speaker embeddings — same-person pairs typically sit well above
    /// 0.4 and different-person pairs near 0 — so this is deliberately not the
    /// same number as the voice threshold.
    static var threshold: Float = {
        ProcessInfo.processInfo.environment["NEON_FACEID_THRESHOLD"]
            .flatMap(Float.init) ?? 0.42
    }()

    private static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/neon/faceid")

    /// ArcFace's canonical 5-point layout for a 112×112 crop: eyes, nose,
    /// mouth corners. Every embedding is computed against this frame of
    /// reference, so alignment is not optional decoration — an unaligned crop
    /// embeds to something confidently wrong.
    private static let reference: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),   // left eye
        CGPoint(x: 73.5318, y: 51.5014),   // right eye
        CGPoint(x: 56.0252, y: 71.7366),   // nose
        CGPoint(x: 41.5493, y: 92.3655),   // left mouth corner
        CGPoint(x: 70.7299, y: 92.2041),   // right mouth corner
    ]

    var isAvailable: Bool { session != nil || load() }

    @discardableResult
    func load() -> Bool {
        guard session == nil else { return true }
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.dir,
                                                                  includingPropertiesForKeys: nil)) ?? []
        guard let model = files.first(where: { $0.pathExtension == "onnx" }) else {
            dbg("faceid: no model in \(Self.dir.path)")
            return false
        }
        do {
            let env = try ORTEnv(loggingLevel: .warning)
            self.env = env
            session = try ORTSession(env: env, modelPath: model.path, sessionOptions: nil)
            dbg("faceid: loaded \(model.lastPathComponent)")
            return true
        } catch {
            dbg("faceid: load failed: \(error)")
            return false
        }
    }

    // MARK: - Detection

    struct Face {
        let embedding: [Float]
        /// Vision's own view of how usable the shot is (0…1). Enrollment uses
        /// it to throw away blinks, blur and bad angles rather than baking
        /// them into someone's identity.
        let quality: Float
        let area: CGFloat
    }

    /// Every usable face in the image, best-quality first.
    func faces(in image: CGImage) -> [Face] {
        guard isAvailable else { return [] }
        let landmarks = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([landmarks]) } catch {
            dbg("faceid: detection failed: \(error.localizedDescription)")
            return []
        }
        guard let observations = landmarks.results, !observations.isEmpty else { return [] }

        // Capture quality is a *separate* request — VNDetectFaceLandmarksRequest
        // leaves faceCaptureQuality nil, so scoring frames by it silently
        // ranked everything equal at the fallback value. Fed the landmark
        // observations so it scores the same faces rather than re-detecting.
        var quality: [Float] = Array(repeating: 0.5, count: observations.count)
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        qualityRequest.inputFaceObservations = observations
        if (try? handler.perform([qualityRequest])) != nil,
           let scored = qualityRequest.results, scored.count == observations.count {
            quality = scored.map { $0.faceCaptureQuality ?? 0.5 }
        }

        return observations.enumerated().compactMap { i, face -> Face? in
            guard let points = fivePoints(face, imageSize: CGSize(width: image.width,
                                                                 height: image.height)),
                  let chip = align(image, from: points),
                  let embedding = embed(chip) else { return nil }
            return Face(embedding: embedding, quality: quality[i],
                        area: face.boundingBox.width * face.boundingBox.height)
        }.sorted { $0.quality > $1.quality }
    }

    /// The five landmarks ArcFace aligns on, in image pixel coordinates.
    /// Vision reports landmarks normalized to the face box, in a
    /// bottom-left origin — both have to be undone.
    private func fivePoints(_ face: VNFaceObservation, imageSize: CGSize) -> [CGPoint]? {
        guard let marks = face.landmarks,
              let leftEye = marks.leftEye, let rightEye = marks.rightEye,
              let nose = marks.nose, let lips = marks.outerLips else { return nil }
        func center(_ region: VNFaceLandmarkRegion2D) -> CGPoint {
            let pts = region.normalizedPoints
            guard !pts.isEmpty else { return .zero }
            let sx = pts.reduce(0) { $0 + $1.x }, sy = pts.reduce(0) { $0 + $1.y }
            return CGPoint(x: CGFloat(sx) / CGFloat(pts.count), y: CGFloat(sy) / CGFloat(pts.count))
        }
        func toImage(_ p: CGPoint) -> CGPoint {
            let box = face.boundingBox
            let x = (box.origin.x + p.x * box.width) * imageSize.width
            let yUp = (box.origin.y + p.y * box.height) * imageSize.height
            return CGPoint(x: x, y: imageSize.height - yUp)   // flip to CG's top-left origin
        }
        let lipPts = lips.normalizedPoints
        guard !lipPts.isEmpty else { return nil }
        let leftCorner = lipPts.min { $0.x < $1.x }!
        let rightCorner = lipPts.max { $0.x < $1.x }!
        return [
            toImage(center(leftEye)), toImage(center(rightEye)), toImage(center(nose)),
            toImage(CGPoint(x: CGFloat(leftCorner.x), y: CGFloat(leftCorner.y))),
            toImage(CGPoint(x: CGFloat(rightCorner.x), y: CGFloat(rightCorner.y))),
        ]
    }

    // MARK: - Alignment

    /// Warps the face onto ArcFace's reference layout.
    ///
    /// The transform is the least-squares *similarity* (rotation, uniform
    /// scale, translation — no reflection, no shear), which has a closed form
    /// in complex arithmetic: treat each point as x+iy, and the best `a` in
    /// `y = a·x + b` is Σ(conj(xᵢ)·yᵢ)/Σ|xᵢ|² over centered points. That avoids
    /// the SVD an Umeyama fit would otherwise need, and cannot mirror a face.
    private func align(_ image: CGImage, from points: [CGPoint]) -> [Float]? {
        let src = points.map { (Double($0.x), Double($0.y)) }
        let dst = Self.reference.map { (Double($0.x), Double($0.y)) }
        let n = Double(src.count)
        let sx = src.reduce(0) { $0 + $1.0 } / n, sy = src.reduce(0) { $0 + $1.1 } / n
        let dx = dst.reduce(0) { $0 + $1.0 } / n, dy = dst.reduce(0) { $0 + $1.1 } / n

        var numRe = 0.0, numIm = 0.0, den = 0.0
        for i in src.indices {
            let xr = src[i].0 - sx, xi = src[i].1 - sy
            let yr = dst[i].0 - dx, yi = dst[i].1 - dy
            numRe += xr * yr + xi * yi      // conj(x) · y
            numIm += xr * yi - xi * yr
            den += xr * xr + xi * xi
        }
        guard den > 1e-6 else { return nil }
        let aRe = numRe / den, aIm = numIm / den
        let scale2 = aRe * aRe + aIm * aIm
        guard scale2 > 1e-9 else { return nil }

        // Inverse map: source = conj(a)·(dst − b) / |a|², with b = d̄ − a·s̄.
        let bRe = dx - (aRe * sx - aIm * sy), bIm = dy - (aIm * sx + aRe * sy)

        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let bpr = image.bytesPerRow, bpp = image.bitsPerPixel / 8
        let w = image.width, h = image.height
        guard bpp >= 3 else { return nil }

        // ArcFace wants NCHW RGB scaled to [-1, 1].
        var out = [Float](repeating: 0, count: 3 * 112 * 112)
        for py in 0..<112 {
            for px in 0..<112 {
                let ur = Double(px) - bRe, ui = Double(py) - bIm
                let srcX = (aRe * ur + aIm * ui) / scale2
                let srcY = (aRe * ui - aIm * ur) / scale2
                let ix = Int(srcX.rounded()), iy = Int(srcY.rounded())
                var r: Float = 0, g: Float = 0, b: Float = 0
                if ix >= 0, ix < w, iy >= 0, iy < h {
                    let o = iy * bpr + ix * bpp
                    // CGImage from a JPEG here is BGRA or RGBA; both put the
                    // three color bytes first in memory order R,G,B for
                    // .byteOrder32Big|.noneSkipLast, which is what we request.
                    r = Float(bytes[o]); g = Float(bytes[o + 1]); b = Float(bytes[o + 2])
                }
                let i = py * 112 + px
                out[i] = (r - 127.5) / 127.5
                out[112 * 112 + i] = (g - 127.5) / 127.5
                out[2 * 112 * 112 + i] = (b - 127.5) / 127.5
            }
        }
        return out
    }

    // MARK: - Embedding

    private func embed(_ chip: [Float]) -> [Float]? {
        guard let session else { return nil }
        do {
            let data = NSMutableData(bytes: chip, length: chip.count * 4)
            let value = try ORTValue(tensorData: data, elementType: .float,
                                     shape: [1, 3, 112, 112])
            let inName = try session.inputNames()[0]
            let outName = try session.outputNames()[0]
            let out = try session.run(withInputs: [inName: value],
                                      outputNames: [outName], runOptions: nil)
            guard let tensor = out[outName] else { return nil }
            var vec = (try tensor.tensorData() as Data)
                .withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let norm = sqrt(vec.reduce(0) { $0 + $1 * $1 })
            guard norm > 0 else { return nil }
            for i in vec.indices { vec[i] /= norm }
            return vec
        } catch {
            dbg("faceid: inference failed: \(error)")
            return nil
        }
    }

    // MARK: - Recognition

    /// Hedged, like the voice hint: "looks like Alex", never an assertion.
    func describe(in image: CGImage) -> (phrase: String, detail: String)? {
        guard let face = faces(in: image).first else { return nil }
        let match = PersonStore.shared.matchFace(face.embedding, threshold: Self.threshold)
        return (PersonStore.phrase(match, verb: "look"),
                PersonStore.detail(match)
                    + String(format: ", quality %.2f", face.quality))
    }

    /// Decodes a base64 JPEG (what CameraFeed carries) into a bitmap laid out
    /// the way `align` expects to read it.
    static func image(fromBase64JPEG b64: String) -> CGImage? {
        guard let data = Data(base64Encoded: b64),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let raw = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = raw.width, h = raw.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return raw }
        ctx.draw(raw, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
