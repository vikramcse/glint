import CoreGraphics
import CoreML
import Foundation
import GlintCore
import Vision

/// Finds faces with Vision and identifies them with SFace, a face recognizer bundled as a Core
/// ML model (scripts/model/convert_sface.py). Faces of one person score a cosine similarity of
/// about 0.4 and up; different people mostly score below 0.3.
public struct FaceAnalyzer: Sendable {
    /// Faces smaller than this many pixels on a side in the analyzed image are skipped; their
    /// identity vectors are too noisy to group.
    public var minimumFaceSide: Double
    /// Faces below this Vision capture quality (blurred, turned away, half hidden) are skipped.
    /// The score is relative: sharp frontal LFW portraits score a median of 0.33 and a p5 of
    /// 0.16, so the bar sits below that.
    public var minimumQuality: Float
    /// At most this many faces per image, largest first (a crowd adds no one the user knows).
    public var maxFaces: Int

    public init(minimumFaceSide: Double = 40, minimumQuality: Float = 0.1, maxFaces: Int = 12) {
        self.minimumFaceSide = minimumFaceSide
        self.minimumQuality = minimumQuality
        self.maxFaces = maxFaces
    }

    /// Whether the bundled recognizer loaded; without it no faces are reported.
    public static var isAvailable: Bool { Recognizer.shared != nil }

    /// Faces in `image`, largest first. Blocking; call through `Offload`.
    public func faces(in image: CGImage) -> [DetectedFace] {
        guard let recognizer = Recognizer.shared else { return [] }
        let landmarks = VNDetectFaceLandmarksRequest()
        let quality = VNDetectFaceCaptureQualityRequest()
        do {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([landmarks])
            let found = (landmarks.results ?? []).filter { pixelSide(of: $0, in: image) >= minimumFaceSide }
            guard !found.isEmpty else { return [] }
            quality.inputFaceObservations = found
            try handler.perform([quality])
        } catch {
            Log.extractor.error("Face detection failed: \(String(describing: error), privacy: .public)")
            return []
        }
        let observations = (quality.results ?? [])
            .filter { ($0.faceCaptureQuality ?? 0) >= minimumQuality }
            .sorted { $0.boundingBox.width > $1.boundingBox.width }
            .prefix(maxFaces)
        return observations.compactMap { observation in
            guard let points = FaceAlignment.points(of: observation, in: image),
                let aligned = FaceAlignment.aligned(image, points: points),
                let print = recognizer.identity(of: aligned)
            else { return nil }
            let box = observation.boundingBox
            return DetectedFace(
                box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height),
                quality: observation.faceCaptureQuality ?? 0,
                print: print,
                crop: Self.crop(observation.boundingBox, of: image)
            )
        }
    }

    private func pixelSide(of face: VNFaceObservation, in image: CGImage) -> Double {
        min(face.boundingBox.width * Double(image.width), face.boundingBox.height * Double(image.height))
    }

    /// A square around the face with room for hair and chin, for display.
    static func crop(_ box: CGRect, of image: CGImage, maxPixel: Int = 192) -> CGImage? {
        let width = Double(image.width)
        let height = Double(image.height)
        let side = min(max(box.width * width, box.height * height) * 1.6, width, height)
        let center = CGPoint(x: box.midX * width, y: (1 - box.midY) * height)
        let originX = min(max(0, center.x - side / 2), width - side)
        let originY = min(max(0, center.y - side / 2), height - side)
        guard let cropped = image.cropping(to: CGRect(x: originX, y: originY, width: side, height: side).integral) else {
            return nil
        }
        return ImageProcessing.scaled(cropped, maxPixel: maxPixel)
    }
}

/// The bundled SFace model. Predictions are serialized; each takes about a millisecond.
final class Recognizer: @unchecked Sendable {
    static let shared: Recognizer? = {
        guard let url = Bundle.module.url(forResource: "SFace", withExtension: "mlmodelc") else {
            Log.extractor.error("SFace model is missing from the bundle")
            return nil
        }
        do {
            return try Recognizer(url: url)
        } catch {
            Log.extractor.error("SFace model failed to load: \(String(describing: error), privacy: .public)")
            return nil
        }
    }()

    private let model: MLModel
    private let constraint: MLImageConstraint
    private let lock = NSLock()

    init(url: URL) throws {
        model = try MLModel(contentsOf: url)
        guard let constraint = model.modelDescription.inputDescriptionsByName["face"]?.imageConstraint else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.constraint = constraint
    }

    /// The unit-length identity vector of a face aligned by `FaceAlignment`.
    func identity(of face: CGImage) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        do {
            let input = try MLFeatureValue(cgImage: face, constraint: constraint)
            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["face": input]))
            guard let array = output.featureValue(for: "identity")?.multiArrayValue else { return nil }
            var values = (0..<array.count).map { Float(truncating: array[$0]) }
            let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 0 else { return nil }
            for index in values.indices { values[index] /= norm }
            return values
        } catch {
            Log.extractor.error("Face recognition failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// Five-point alignment to the 112x112 ArcFace template SFace was trained on.
enum FaceAlignment {
    static let size = 112
    /// Eye centers, nose tip and mouth corners, left to right as seen in the image, top-left origin.
    static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// The five template points of `face` in image pixels with a top-left origin.
    static func points(of face: VNFaceObservation, in image: CGImage) -> [CGPoint]? {
        guard let landmarks = face.landmarks else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        func pixels(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint]? {
            guard let region, region.pointCount > 0 else { return nil }
            return region.pointsInImage(imageSize: size).map { CGPoint(x: $0.x, y: size.height - $0.y) }
        }
        func center(_ points: [CGPoint]) -> CGPoint {
            CGPoint(
                x: points.map(\.x).reduce(0, +) / Double(points.count), y: points.map(\.y).reduce(0, +) / Double(points.count))
        }
        guard let firstEye = pixels(landmarks.leftPupil) ?? pixels(landmarks.leftEye),
            let secondEye = pixels(landmarks.rightPupil) ?? pixels(landmarks.rightEye),
            let nose = pixels(landmarks.nose), let lips = pixels(landmarks.outerLips)
        else { return nil }
        let eyes = [center(firstEye), center(secondEye)].sorted { $0.x < $1.x }
        // Mouth corners are the lip points furthest along the line between the eyes.
        let axis = CGPoint(x: eyes[1].x - eyes[0].x, y: eyes[1].y - eyes[0].y)
        func along(_ point: CGPoint) -> Double { point.x * axis.x + point.y * axis.y }
        guard let mouthLeft = lips.min(by: { along($0) < along($1) }), let mouthRight = lips.max(by: { along($0) < along($1) })
        else { return nil }
        return [eyes[0], eyes[1], center(nose), mouthLeft, mouthRight]
    }

    /// `image` warped so `points` land on the template, as a 112x112 RGB image.
    static func aligned(_ image: CGImage, points: [CGPoint]) -> CGImage? {
        guard let transform = similarity(from: points, to: template),
            let context = CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else { return nil }
        // Core Graphics draws with a bottom-left origin; the transform works top-left, so flip
        // into it and back out.
        let flipSource = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: Double(image.height))
        let flipTarget = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: Double(size))
        context.interpolationQuality = .high
        context.concatenate(flipSource.concatenating(transform).concatenating(flipTarget))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Least-squares rotation, uniform scale and translation taking `source` onto `target`.
    static func similarity(from source: [CGPoint], to target: [CGPoint]) -> CGAffineTransform? {
        guard source.count == target.count, !source.isEmpty else { return nil }
        let count = Double(source.count)
        let sourceMean = CGPoint(x: source.map(\.x).reduce(0, +) / count, y: source.map(\.y).reduce(0, +) / count)
        let targetMean = CGPoint(x: target.map(\.x).reduce(0, +) / count, y: target.map(\.y).reduce(0, +) / count)
        var dot = 0.0
        var cross = 0.0
        var norm = 0.0
        for (s, t) in zip(source, target) {
            let sx = s.x - sourceMean.x
            let sy = s.y - sourceMean.y
            let tx = t.x - targetMean.x
            let ty = t.y - targetMean.y
            dot += sx * tx + sy * ty
            cross += sx * ty - sy * tx
            norm += sx * sx + sy * sy
        }
        guard norm > 0 else { return nil }
        let a = dot / norm
        let b = cross / norm
        return CGAffineTransform(
            a: a, b: b, c: -b, d: a,
            tx: targetMean.x - (a * sourceMean.x - b * sourceMean.y),
            ty: targetMean.y - (b * sourceMean.x + a * sourceMean.y)
        )
    }
}
