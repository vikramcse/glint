import AppKit
import Foundation
import GlintCore
import UniformTypeIdentifiers

/// Extracts plain text, Markdown, code, RTF, Word, OpenDocument and HTML into overlapping
/// text chunks.
public struct TextExtractor: ContentExtractor {
    public static let contentTypes: Set<UTType> = {
        var types: Set<UTType> = [.text, .plainText, .sourceCode, .json, .xml, .yaml, .commaSeparatedText, .rtf, .rtfd, .html]
        for type in richTextTypes.keys { types.insert(type) }
        if let markdown = UTType("net.daringfireball.markdown") { types.insert(markdown) }
        return types
    }()

    /// Formats `NSAttributedString` reads natively (no WebKit, safe off the main thread).
    static let richTextTypes: [UTType: NSAttributedString.DocumentType] = {
        var types: [UTType: NSAttributedString.DocumentType] = [.rtf: .rtf, .rtfd: .rtfd]
        if let docx = UTType("org.openxmlformats.wordprocessingml.document") { types[docx] = .officeOpenXML }
        if let doc = UTType("com.microsoft.word.doc") { types[doc] = .docFormat }
        if let odt = UTType("org.oasis-open.opendocument.text") { types[odt] = .openDocument }
        return types
    }()

    public let options: ExtractionOptions

    public init(options: ExtractionOptions = .default) {
        self.options = options
    }

    public func chunks(of file: FileRef) -> AsyncThrowingStream<Chunk, any Error> {
        let options = options
        let state = PendingChunks()
        return lazyChunkStream {
            if await !state.isLoaded {
                let text = try await Offload.run { try Self.extractText(from: file, options: options) }
                let chunks = options.textChunker.chunk(text).enumerated().map { ordinal, piece in
                    Chunk(
                        ordinal: ordinal,
                        locator: .text(start: piece.start, end: piece.end),
                        text: piece.text,
                        input: .text(piece.text)
                    )
                }
                await state.load(chunks)
            }
            return await state.next()
        }
    }

    /// Reads the whole document as plain text. Blocking; call through `Offload`.
    static func extractText(from file: FileRef, options: ExtractionOptions) throws -> String {
        try ExtractionError.checkReadable(file.url)
        let size = max(file.size, DocumentSize.onDisk(file.url))
        if size > options.maxTextBytes { throw ExtractionError.tooLarge(limit: options.maxTextBytes) }

        let text: String
        if let documentType = richTextType(for: file.contentType) {
            if zippedTypes.contains(documentType) {
                // A small archive can inflate to gigabytes; check before anything inflates it.
                guard let expanded = DocumentSize.zipUncompressedSize(file.url) else { throw ExtractionError.corrupt }
                let limit = options.maxTextBytes.multipliedReportingOverflow(by: expansionAllowance).partialValue
                if expanded > limit { throw ExtractionError.tooLarge(limit: limit) }
            }
            text = try readRichText(file.url, type: documentType)
        } else {
            let data: Data
            do {
                data = try Data(contentsOf: file.url, options: .mappedIfSafe)
            } catch {
                throw ExtractionError.wrap(error)
            }
            guard !data.isEmpty else { throw ExtractionError.empty }
            let decoded = try TextDecoding.decode(data)
            text = file.contentType.conforms(to: .html) ? TextDecoding.plainText(fromHTML: decoded) : decoded
        }
        guard text.contains(where: { !$0.isWhitespace }) else { throw ExtractionError.empty }
        return text
    }

    /// Formats stored as zip archives.
    static let zippedTypes: Set<NSAttributedString.DocumentType> = [.officeOpenXML, .openDocument]
    /// How many times `maxTextBytes` a zipped document may expand to. Its XML is several times
    /// the size of its text, and embedded pictures barely compress.
    static let expansionAllowance: Int64 = 4

    private static func richTextType(for type: UTType) -> NSAttributedString.DocumentType? {
        richTextTypes.first { type.conforms(to: $0.key) }?.value
    }

    private static func readRichText(_ url: URL, type: NSAttributedString.DocumentType) throws -> String {
        if ExtractionError.fileSize(url) == 0, !url.hasDirectoryPath, type != .rtfd {
            throw ExtractionError.empty
        }
        do {
            let string = try NSAttributedString(
                url: url, options: [.documentType: type], documentAttributes: nil
            )
            return string.string
        } catch {
            let category = error.glintCategory
            throw category == .permissionDenied || category == .notFound
                ? ExtractionError.unreadable(category) : ExtractionError.corrupt
        }
    }
}

/// Holds eagerly extracted chunks for a lazy stream.
actor PendingChunks {
    private var chunks: [Chunk] = []
    private var position = 0
    private(set) var isLoaded = false

    func load(_ chunks: [Chunk]) {
        self.chunks = chunks
        isLoaded = true
    }

    func next() -> Chunk? {
        guard position < chunks.count else { return nil }
        defer { position += 1 }
        return chunks[position]
    }
}
