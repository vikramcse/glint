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

        let image = try ImageProcessing.downscaledImage(at: file.url, maxPixel: options.embeddingImageMaxPixel)
        let thumbnail = ImageProcessing.scaled(image, maxPixel: options.thumbnailMaxPixel)

        var text: String?
        if options.ocrEnabled {
            do {
                text = try recognizeText(file.url, preview: image, options: options)
            } catch {
                Log.extractor.error("OCR failed: \(String(describing: error), privacy: .public)")
            }
        }
        return Chunk(
            ordinal: 0,
            locator: .whole,
            text: text,
            input: .image(image),
            preview: ChunkPreview(thumbnail: thumbnail, thumbnailKey: "i")
        )
    }

    /// OCR with `.automatic`: skip images without text, otherwise decode once more at
    /// `ocrMaxPixel` (only when the source is larger than the preview) and pick the recognizer
    /// by source. Explicit `.fast`/`.accurate` levels read the preview as before.
    static func recognizeText(_ url: URL, preview: CGImage, options: ExtractionOptions) throws -> String? {
        let recognizer = TextRecognizer(level: options.ocrLevel)
        let recognized: String
        if options.ocrLevel == .automatic {
            let source: OCRSource = ImageProcessing.isCameraPhoto(at: url) ? .camera : .screen
            // Only camera photos are pre-checked: most have no text, and the 1–3 ms check
            // saves the recognizer. Screens nearly always have text, often too small for the
            // detector at preview size, and fast recognition costs only ~30 ms.
            if source == .camera, !TextRecognizer.containsText(preview) { return nil }
            let longSide = ImageProcessing.pixelSize(at: url).map { max($0.width, $0.height) } ?? 0
            let ocrImage =
                source == .screen && longSide > max(preview.width, preview.height)
                ? try ImageProcessing.downscaledImage(at: url, maxPixel: options.ocrMaxPixel) : preview
            recognized = try recognizer.recognizeTextBlocking(in: ocrImage, source: source)
        } else {
            recognized = try recognizer.recognizeTextBlocking(in: preview)
        }
        return recognized.isEmpty ? nil : recognized
    }
}
