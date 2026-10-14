import AppKit
import CoreGraphics
import Foundation
import GlintCore
import PDFKit
import UniformTypeIdentifiers

/// Extracts PDFs page by page: text chunks per page (OCR for pages without a text layer), a
/// rendered page thumbnail, and one visual page chunk for visual search.
public struct PDFExtractor: ContentExtractor {
    public static let contentTypes: Set<UTType> = [.pdf]

    /// Pages with fewer non-whitespace characters than this are treated as scans and OCR'd.
    static let minimumTextLayerCharacters = 20

    public let options: ExtractionOptions

    public init(options: ExtractionOptions = .default) {
        self.options = options
    }

    public func chunks(of file: FileRef) -> AsyncThrowingStream<Chunk, any Error> {
        let cursor = PDFCursor(url: file.url, options: options)
        return lazyChunkStream { try await cursor.next() }
    }
}

/// Walks a PDF one page at a time so only one page render is in memory.
actor PDFCursor {
    private let url: URL
    private let options: ExtractionOptions
    private var document: PDFDocument?
    private var pageCount = 0
    private var nextPage = 0
    private var nextOrdinal = 0
    private var queued: [Chunk] = []

    init(url: URL, options: ExtractionOptions) {
        self.url = url
        self.options = options
    }

    func next() async throws -> Chunk? {
        if document == nil { try open() }
        while queued.isEmpty, nextPage < pageCount {
            try Task.checkCancellation()
            queued = try await chunks(forPage: nextPage)
            nextPage += 1
        }
        return queued.isEmpty ? nil : queued.removeFirst()
    }

    private func open() throws {
        try ExtractionError.checkReadable(url)
        guard ExtractionError.fileSize(url) > 0 else { throw ExtractionError.empty }
        guard let document = PDFDocument(url: url) else { throw ExtractionError.corrupt }
        if document.isLocked, !document.unlock(withPassword: "") { throw ExtractionError.unsupported }
        guard document.pageCount > 0 else { throw ExtractionError.empty }
        self.document = document
        pageCount = min(document.pageCount, options.maxPDFPages)
    }

    private func chunks(forPage index: Int) async throws -> [Chunk] {
        guard let page = document?.page(at: index) else { return [] }
        let render = Self.render(page, maxPixel: options.embeddingImageMaxPixel)

        var text = TextDecoding.collapseWhitespace(page.string ?? "")
        if text.filter({ !$0.isWhitespace }).count < PDFExtractor.minimumTextLayerCharacters,
            options.ocrEnabled, let render
        {
            // Scans are read at OCR resolution; the fast recognizer needs ~2048 px for body text.
            let scan = options.ocrLevel == .automatic ? Self.render(page, maxPixel: options.ocrMaxPixel) ?? render : render
            let recognized =
                (try? await TextRecognizer(level: options.ocrLevel).recognizeText(in: scan, source: .document)) ?? ""
            if recognized.count > text.count { text = recognized }
        }

        var chunks: [Chunk] = options.textChunker.chunk(text).map { piece in
            Chunk(ordinal: 0, locator: .page(index), text: piece.text, input: .text(piece.text))
        }
        if let render {
            chunks.append(
                Chunk(ordinal: 0, locator: .page(index), input: .image(render))
            )
        }
        for position in chunks.indices {
            chunks[position].ordinal = nextOrdinal
            nextOrdinal += 1
        }
        if !chunks.isEmpty {
            chunks[0].preview = ChunkPreview(
                thumbnail: render.map { ImageProcessing.scaled($0, maxPixel: options.thumbnailMaxPixel) },
                thumbnailKey: "p\(index)"
            )
        }
        return chunks
    }

    /// Renders a page on white, honoring its rotation, with the long side at most `maxPixel`.
    static func render(_ page: PDFPage, maxPixel: Int) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let pageSize = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }
        let scale = Double(maxPixel) / Double(max(pageSize.width, pageSize.height))
        let width = max(1, Int((pageSize.width * scale).rounded()))
        let height = max(1, Int((pageSize.height * scale).rounded()))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }
}
