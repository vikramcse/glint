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

/// What produced an image, which decides how `.automatic` OCR reads it.
public enum OCRSource: Sendable, Hashable {
    /// A camera photo: scene text, varied lighting. Read accurately, with language correction.
    case camera
    /// A screenshot or other rendered image: crisp UI text.
    case screen
    /// A scanned or rendered document page.
    case document
}

/// On-device text recognition with Vision.
public struct TextRecognizer: Sendable {
    public var level: ExtractionOptions.OCRLevel
    public var usesLanguageCorrection: Bool

    public init(level: ExtractionOptions.OCRLevel = .automatic, usesLanguageCorrection: Bool = true) {
        self.level = level
        self.usesLanguageCorrection = usesLanguageCorrection
    }

    /// Recognized lines, top to bottom, joined with newlines. Empty when the image has no text.
    /// Runs off the cooperative thread pool.
    public func recognizeText(in image: CGImage, source: OCRSource = .screen) async throws -> String {
        let recognizer = self
        return try await Offload.run { try recognizer.recognizeTextBlocking(in: image, source: source) }
    }

    /// Blocking variant for code already running on the offload queue.
    func recognizeTextBlocking(in image: CGImage, source: OCRSource = .screen) throws -> String {
        try Offload.ocrLane.run {
            let request = VNRecognizeTextRequest()
            switch (level, source) {
            case (.accurate, _), (.automatic, .camera):
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = usesLanguageCorrection
                request.automaticallyDetectsLanguage = true
            case (.fast, _), (.automatic, .screen), (.automatic, .document):
                // Language correction costs ~2.5x and changed no words on crisp text.
                request.recognitionLevel = .fast
                request.usesLanguageCorrection = false
            }
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        }
    }

    /// Whether `image` appears to contain any text (1–3 ms; skips OCR on most photos).
    static func containsText(_ image: CGImage) -> Bool {
        let request = VNDetectTextRectanglesRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return true  // When unsure, let recognition decide.
        }
        return !(request.results ?? []).isEmpty
    }
}

extension ImageProcessing {
    /// Pixel size of an image file without decoding it.
    static func pixelSize(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    /// Whether the file carries camera metadata (exposure, lens or camera make).
    static func isCameraPhoto(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return false }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        return exif[kCGImagePropertyExifExposureTime] != nil || exif[kCGImagePropertyExifFNumber] != nil
            || exif[kCGImagePropertyExifLensModel] != nil || tiff[kCGImagePropertyTIFFMake] != nil
    }
}
