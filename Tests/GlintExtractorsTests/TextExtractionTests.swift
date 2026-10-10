import Foundation
import GlintCore
import GlintTestSupport
import Testing
import UniformTypeIdentifiers

@testable import GlintExtractors

/// Drains an extractor stream.
func collect(_ extractor: some ContentExtractor, _ url: URL) async throws -> [Chunk] {
    var chunks: [Chunk] = []
    for try await chunk in extractor.chunks(of: try Fixtures.fileRef(url)) { chunks.append(chunk) }
    return chunks
}

/// Expects the extractor to fail with `expected`.
func expectExtractionError(
    _ expected: ExtractionError, _ extractor: some ContentExtractor, _ url: URL,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    await #expect(throws: expected, sourceLocation: sourceLocation) {
        _ = try await collect(extractor, url)
    }
}

@Suite("TextChunker")
struct TextChunkerTests {
    func words(_ count: Int) -> String {
        (0..<count).map { "w\($0)" }.joined(separator: " ")
    }

    @Test func emptyAndWhitespaceProduceNothing() {
        let chunker = TextChunker()
        #expect(chunker.chunk("").isEmpty)
        #expect(chunker.chunk("  \n\t  ").isEmpty)
    }

    @Test func shortTextIsOneChunkWithTrimmedOffsets() {
        let text = "  hello brave world  "
        let pieces = TextChunker().chunk(text)
        #expect(pieces.count == 1)
        #expect(pieces[0].text == "hello brave world")
        #expect(pieces[0].start == 2)
        #expect(pieces[0].end == 19)
    }

    @Test func chunksOverlapByConfiguredWords() {
        let chunker = TextChunker(maxTokens: 10, overlapTokens: 3, tokensPerWord: 1)
        let pieces = chunker.chunk(words(25))
        // Hop of 7 words: 0-9, 7-16, 14-23, 21-24.
        #expect(pieces.map { $0.text.split(separator: " ").first } == ["w0", "w7", "w14", "w21"])
        #expect(pieces.map { $0.text.split(separator: " ").count } == [10, 10, 10, 4])
        #expect(pieces.last?.text.hasSuffix("w24") == true)
    }

    @Test func offsetsSliceTheSourceExactly() {
        let text = "Café ☕️ naïve résumé — emoji 👩‍👩‍👧 end " + words(40)
        let chunker = TextChunker(maxTokens: 7, overlapTokens: 2, tokensPerWord: 1)
        let characters = Array(text)
        for piece in chunker.chunk(text) {
            #expect(String(characters[piece.start..<piece.end]) == piece.text)
        }
    }

    @Test func neverSplitsWords() {
        let text = "supercalifragilistic " + String(repeating: "x", count: 5_000)
        let pieces = TextChunker(maxTokens: 1, overlapTokens: 0, tokensPerWord: 1).chunk(text)
        #expect(pieces.map(\.text) == ["supercalifragilistic", String(repeating: "x", count: 5_000)])
    }

    @Test func defaultSizesFollowThePRD() {
        let chunker = TextChunker()
        #expect(chunker.wordsPerChunk == 393)
        #expect(chunker.overlapWords == 49)
        #expect(TextChunker(maxTokens: 2, overlapTokens: 64, tokensPerWord: 1).overlapWords == 1)
    }
}

@Suite("TextExtractor")
struct TextExtractorTests {
    let directory: TemporaryDirectory
    let extractor = TextExtractor()

    init() throws { directory = try TemporaryDirectory() }

    @Test func extractsMarkdownIntoTextChunks() async throws {
        let url = try Fixtures.writeText("# Pricing\n\nThe Acme pitch deck.", named: "notes.md", in: directory.url)
        let chunks = try await collect(extractor, url)
        #expect(chunks.count == 1)
        #expect(chunks[0].text?.contains("Acme pitch") == true)
        #expect(chunks[0].locator == .text(start: 0, end: 31))
        guard case .text(let input) = chunks[0].input else {
            Issue.record("Expected text input")
            return
        }
        #expect(input == chunks[0].text)
    }

    @Test func longDocumentsBecomeOrderedChunks() async throws {
        let text = (0..<1_000).map { "word\($0)" }.joined(separator: " ")
        let url = try Fixtures.writeText(text, named: "long.txt", in: directory.url)
        let chunks = try await collect(extractor, url)
        #expect(chunks.count == 3)
        #expect(chunks.map(\.ordinal) == [0, 1, 2])
    }

    @Test(arguments: [
        (String.Encoding.utf8, true),
        (.utf16LittleEndian, true),
        (.utf16BigEndian, true),
        (.utf16LittleEndian, false),
        (.windowsCP1252, false),
    ])
    func detectsEncodings(encoding: String.Encoding, byteOrderMark: Bool) async throws {
        let text = "Résumé for the café meeting, naïve façade"
        let url = try Fixtures.writeText(
            text, named: "encoded.txt", in: directory.url, encoding: encoding, byteOrderMark: byteOrderMark
        )
        let chunks = try await collect(extractor, url)
        #expect(chunks.first?.text == text)
    }

    @Test func readsRTF() async throws {
        let url = try Fixtures.writeRTF("Quarterly revenue by region grew strongly.", in: directory.url)
        let chunks = try await collect(extractor, url)
        #expect(chunks.first?.text == "Quarterly revenue by region grew strongly.")
    }

    @Test func stripsHTML() async throws {
        let html = """
            <html><head><style>p { color: red }</style><script>var secret = 1;</script></head>
            <body><h1>Flight confirmation</h1><p>Seat 12A &amp; window &#8212; Goa&nbsp;trip</p></body></html>
            """
        let url = try Fixtures.writeText(html, named: "page.html", in: directory.url)
        let text = try #require(try await collect(extractor, url).first?.text)
        #expect(text.contains("Flight confirmation"))
        #expect(text.contains("Seat 12A & window — Goa trip"))
        #expect(!text.contains("secret"))
        #expect(!text.contains("color"))
        #expect(!text.contains("<"))
    }

    @Test func zeroByteFileIsEmpty() async throws {
        let url = try Fixtures.writeData(Data(), named: "empty.txt", in: directory.url)
        try await expectExtractionError(.empty, extractor, url)
    }

    @Test func whitespaceOnlyFileIsEmpty() async throws {
        let url = try Fixtures.writeText(" \n\n\t ", named: "blank.txt", in: directory.url)
        try await expectExtractionError(.empty, extractor, url)
    }

    @Test func binaryDataIsUnsupported() async throws {
        let bytes = Data((0..<2_048).map { UInt8($0 % 7 == 0 ? 0 : $0 % 256) })
        let url = try Fixtures.writeData(bytes, named: "binary.txt", in: directory.url)
        try await expectExtractionError(.unsupported, extractor, url)
    }

    @Test func enforcesSizeCap() async throws {
        let url = try Fixtures.writeText(String(repeating: "a ", count: 600), named: "big.txt", in: directory.url)
        let small = TextExtractor(options: ExtractionOptions(maxTextBytes: 1_000))
        try await expectExtractionError(.tooLarge(limit: 1_000), small, url)
    }

    @Test func missingFileIsUnreadable() async throws {
        let ref = FileRef(
            id: FileID(1), url: directory.file("missing.txt"), kind: .document, contentType: .plainText,
            size: 10, modified: Date()
        )
        await #expect(throws: ExtractionError.unreadable(.notFound)) {
            for try await _ in extractor.chunks(of: ref) {}
        }
    }

    @Test func corruptRTFIsCorrupt() async throws {
        let url = try Fixtures.writeData(Data([0xFF, 0x00, 0x13, 0x37]), named: "broken.docx", in: directory.url)
        try await expectExtractionError(.corrupt, extractor, url)
    }

    @Test func errorCategoriesMap() {
        #expect(ExtractionError.unreadable(.permissionDenied).category == .permissionDenied)
        #expect(ExtractionError.tooLarge(limit: 1).category == .unsupported)
        #expect(ExtractionError.corrupt.category == .corrupt)
        #expect(ExtractionError.cancelled.category == .cancelled)
        #expect(ExtractionError.wrap(CancellationError()) == .cancelled)
        #expect(ExtractionError.wrap(CocoaError(.fileReadNoPermission)) == .unreadable(.permissionDenied))
        #expect(!ExtractionError.unreadable(.notFound).description.contains("/"))
    }
}
