import CoreGraphics
import Foundation
import GlintCore
import UniformTypeIdentifiers

/// Extracts one chunk per image: a downscaled image to embed, a thumbnail, and OCR text for the
/// keyword index.
public struct ImageExtractor: ContentExtractor {
    public static let contentTypes: Set<UTType> = [.image]

    public let options: ExtractionOptions

    public init(options: ExtractionOptions = .default) {
        self.options = options
    }

    public func chunks(of file: FileRef) -> AsyncThrowingStream<Chunk, any Error> {
        let options = options
        let state = PendingChunks()
        return lazyChunkStream {
            if await !state.isLoaded {
                await state.load([try await Offload.run { try Self.extract(file, options: options) }])
            }
            return await state.next()
        }
    }

    /// Blocking; call through `Offload`.
    static func extract(_ file: FileRef, options: ExtractionOptions) throws -> Chunk {
        try ExtractionError.checkReadable(file.url)
        guard ExtractionError.fileSize(file.url) > 0 else { throw ExtractionError.empty }

        let (image, text) = try decodeAndRead(file.url, options: options)
        let thumbnail = ImageProcessing.scaled(image, maxPixel: options.thumbnailMaxPixel)
        return Chunk(
            ordinal: 0,
            locator: .whole,
            text: text,
            input: .image(image),
            preview: ChunkPreview(thumbnail: thumbnail, thumbnailKey: "i")
        )
    }

    /// Decodes the image once and reads its text.
    ///
    /// With `.automatic` OCR:
    /// - Camera photos are decoded at preview size, pre-checked for text (1–3 ms), and read
    ///   with the accurate recognizer only when text is present.
    /// - Other images larger than the preview are decoded once at `ocrMaxPixel`; the preview
    ///   and thumbnail are scaled from that, and the fast recognizer runs only when the text
    ///   detector (reliable at this size, unlike at preview size) finds text.
    /// Explicit `.fast`/`.accurate` levels read the preview, as before.
    static func decodeAndRead(_ url: URL, options: ExtractionOptions) throws -> (image: CGImage, text: String?) {
        let previewSize = options.embeddingImageMaxPixel
        guard options.ocrEnabled else {
            return (try ImageProcessing.downscaledImage(at: url, maxPixel: previewSize), nil)
        }
        let recognizer = TextRecognizer(level: options.ocrLevel)
        func read(_ image: CGImage, _ source: OCRSource) -> String? {
            do {
                let text = try recognizer.recognizeTextBlocking(in: image, source: source)
                return text.isEmpty ? nil : text
            } catch {
                Log.extractor.error("OCR failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        guard options.ocrLevel == .automatic else {
            let preview = try ImageProcessing.downscaledImage(at: url, maxPixel: previewSize)
            return (preview, read(preview, .screen))
        }
        let longSide = ImageProcessing.pixelSize(at: url).map { max($0.width, $0.height) } ?? 0
        if ImageProcessing.isCameraPhoto(at: url) || longSide <= previewSize {
            let preview = try ImageProcessing.downscaledImage(at: url, maxPixel: previewSize)
            let source: OCRSource = ImageProcessing.isCameraPhoto(at: url) ? .camera : .screen
            guard source == .screen || TextRecognizer.containsText(preview) else { return (preview, nil) }
            return (preview, read(preview, source))
        }
        let large = try ImageProcessing.downscaledImage(at: url, maxPixel: options.ocrMaxPixel)
        let preview = ImageProcessing.scaled(large, maxPixel: previewSize)
        guard TextRecognizer.containsText(large) else { return (preview, nil) }
        return (preview, read(large, .screen))
    }
}
