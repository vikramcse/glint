import CoreGraphics
import CoreVideo
import Foundation
import GlintCore
import Vision

/// Describes what a photo or video frame shows in plain words for the keyword index:
/// confident scene labels ("car", "beach") and what people are wearing ("person in white
/// shirt").
///
/// Clothing color is read from the region just below each face, keeping only pixels that
/// Vision's person segmentation marks as the person, so the background never colors the
/// answer. Faces are anchored rather than body pose because close-up selfies rarely show hips.
/// Blocking; call through `Offload`.
struct VisualTagger: Sendable {
    var sceneConfidence: Float = 0.3
    var sceneLimit = 6
    var maxPeople = 6
    /// Faces smaller than this fraction of the image width are too far away to judge clothing.
    var minimumFaceWidth: CGFloat = 0.035

    func tags(for image: CGImage) -> [String] {
        let scene = VNClassifyImageRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try VNImageRequestHandler(cgImage: image).perform([scene, faces, segmentation])
        } catch {
            Log.extractor.debug("Visual tagging failed: \(error.localizedDescription, privacy: .public)")
            return []
        }

        var tags: [String] = []
        let colors = clothingColors(in: image, faces: faces.results ?? [], mask: segmentation.results?.first.map(PersonMask.init))
        for color in colors {
            tags.append("person in \(color) shirt")
            tags.append("\(color) clothes")
        }
        let labels = (scene.results ?? [])
            .filter { $0.confidence >= sceneConfidence }
            .prefix(sceneLimit)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        tags.append(contentsOf: labels)

        var seen = Set<String>()
        return tags.filter { seen.insert($0).inserted }
    }

    /// One color name per visible person, in order of appearance, without duplicates.
    func clothingColors(in image: CGImage, faces: [VNFaceObservation], mask: PersonMask?) -> [String] {
        guard let pixels = RGBAPixels(image) else { return [] }
        var colors: [String] = []
        for face in faces.filter({ $0.boundingBox.width >= minimumFaceWidth }).prefix(maxPeople) {
            // Normalized coordinates, origin bottom-left. The torso starts a little below the
            // chin and is about two faces wide and one and a half faces tall.
            let box = face.boundingBox
            let top = box.minY - box.height * 0.45
            guard top > 0.02 else { continue }
            let region = CGRect(
                x: box.midX - box.width, y: max(0, top - box.height * 1.4),
                width: box.width * 2, height: min(top, box.height * 1.4)
            )
            guard let color = pixels.medianColor(in: region, mask: mask) else { continue }
            let name = ColorNamer.name(red: color.red, green: color.green, blue: color.blue)
            if !colors.contains(name) { colors.append(name) }
        }
        return colors
    }
}

/// Person segmentation mask from Vision (255 = person).
struct PersonMask {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]

    init(width: Int, height: Int, bytesPerRow: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.bytes = bytes
    }

    init(_ observation: VNPixelBufferObservation) {
        let buffer = observation.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            bytes = Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: bytesPerRow * height))
        } else {
            bytes = []
        }
    }

    /// Whether the point (normalized, origin top-left) belongs to a person.
    func contains(x: Double, y: Double) -> Bool {
        guard !bytes.isEmpty else { return true }
        let column = min(width - 1, max(0, Int(x * Double(width))))
        let row = min(height - 1, max(0, Int(y * Double(height))))
        return bytes[row * bytesPerRow + column] >= 128
    }
}

/// An image redrawn into a plain RGBA buffer for sampling.
struct RGBAPixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        self.width = width
        self.height = height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        bytes = buffer
    }

    /// Per-channel median of the pixels in `region` (normalized, origin bottom-left) that
    /// the mask marks as a person. `nil` when too few pixels qualify.
    func medianColor(in region: CGRect, mask: PersonMask?) -> (red: Double, green: Double, blue: Double)? {
        let x0 = max(0, Int(region.minX * Double(width))), x1 = min(width, Int(region.maxX * Double(width)))
        let y0 = max(0, Int((1 - region.maxY) * Double(height))), y1 = min(height, Int((1 - region.minY) * Double(height)))
        guard x1 > x0, y1 > y0 else { return nil }
        let step = max(1, min(x1 - x0, y1 - y0) / 40)
        var reds: [UInt8] = [], greens: [UInt8] = [], blues: [UInt8] = []
        for y in stride(from: y0, to: y1, by: step) {
            for x in stride(from: x0, to: x1, by: step) {
                if let mask, !mask.contains(x: Double(x) / Double(width), y: Double(y) / Double(height)) { continue }
                let index = (y * width + x) * 4
                reds.append(bytes[index])
                greens.append(bytes[index + 1])
                blues.append(bytes[index + 2])
            }
        }
        guard reds.count >= 30 else { return nil }
        func median(_ values: [UInt8]) -> Double { Double(values.sorted()[values.count / 2]) / 255 }
        return (median(reds), median(greens), median(blues))
    }
}

/// Maps an sRGB color to a common English color name.
enum ColorNamer {
    static func name(red: Double, green: Double, blue: Double) -> String {
        let maximum = max(red, green, blue), minimum = min(red, green, blue)
        let value = maximum
        let saturation = maximum == 0 ? 0 : (maximum - minimum) / maximum
        var hue = 0.0
        if maximum != minimum {
            if maximum == red {
                hue = (green - blue) / (maximum - minimum)
            } else if maximum == green {
                hue = 2 + (blue - red) / (maximum - minimum)
            } else {
                hue = 4 + (red - green) / (maximum - minimum)
            }
            hue *= 60
            if hue < 0 { hue += 360 }
        }
        if value < 0.22 { return "black" }
        if saturation < 0.18 { return value > 0.62 ? "white" : (value > 0.38 ? "gray" : "black") }
        if saturation < 0.3, value > 0.7, hue < 60 || hue > 330 { return "beige" }
        switch hue {
        case ..<15, 345...: return value < 0.5 ? "maroon" : (saturation < 0.45 ? "pink" : "red")
        case ..<40: return value < 0.55 ? "brown" : "orange"
        case ..<70: return value < 0.5 ? "olive" : "yellow"
        case ..<165: return "green"
        case ..<200: return "teal"
        case ..<255: return value < 0.4 ? "navy" : "blue"
        case ..<290: return "purple"
        default: return saturation < 0.5 ? "pink" : "magenta"
        }
    }
}
