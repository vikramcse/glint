import CoreGraphics
import Foundation
import ImageIO
import Vision

/// ImageIO and Core Graphics helpers shared by the image, PDF and video extractors.
enum ImageProcessing {
    /// Decodes `url` downscaled so its long side is at most `maxPixel`, applying EXIF orientation.
    /// Never decodes the full-resolution image.
    static func downscaledImage(at url: URL, maxPixel: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) > 0
        else {
            throw ExtractionError.corrupt
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ExtractionError.corrupt
        }
        return image
    }

    /// Redraws `image` so its long side is at most `maxPixel`. Returns `image` when already small.
    static func scaled(_ image: CGImage, maxPixel: Int) -> CGImage {
        let longSide = max(image.width, image.height)
        guard longSide > maxPixel, maxPixel > 0 else { return image }
        let scale = Double(maxPixel) / Double(longSide)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}

/// On-device text recognition with Vision.
public struct TextRecognizer: Sendable {
    public var level: ExtractionOptions.OCRLevel
    public var usesLanguageCorrection: Bool

    public init(level: ExtractionOptions.OCRLevel = .accurate, usesLanguageCorrection: Bool = true) {
        self.level = level
        self.usesLanguageCorrection = usesLanguageCorrection
    }

    /// Recognized lines, top to bottom, joined with newlines. Empty when the image has no text.
    /// Runs off the cooperative thread pool.
    public func recognizeText(in image: CGImage) async throws -> String {
        let recognizer = self
        return try await Offload.run { try recognizer.recognizeTextBlocking(in: image) }
    }

    /// Blocking variant for code already running on the offload queue.
    func recognizeTextBlocking(in image: CGImage) throws -> String {
        Offload.ocrSlots.wait()
        defer { Offload.ocrSlots.signal() }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level == .accurate ? .accurate : .fast
        request.usesLanguageCorrection = usesLanguageCorrection
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
