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
                let recognized = try TextRecognizer(level: options.ocrLevel).recognizeTextBlocking(in: image)
                text = recognized.isEmpty ? nil : recognized
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
}
