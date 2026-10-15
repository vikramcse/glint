import AppKit
import Foundation
import GlintCore
import GlintTestSupport
import Testing

@testable import GlintExtractors

@Suite("HTML stripping")
struct HTMLStrippingTests {
    static let samples = [
        "<p>One</p><p>Two<br/>Three</p>",
        "<SCRIPT type=x>alert(1)</ScRiPt>after",
        "<scripts>kept</scripts> <script>gone</script> tail",
        "<script>unclosed and <b>bold</b>",
        "<style>a{}</style><!-- note --><div>body</div>",
        "<!-- unclosed comment <i>it</i>",
        "a < b and c > d <br> e",
        "<<a>> <> <h2>Title</H2>x</tr>y</trick>z",
        "Café <em>naïve</em> 東京 <br\ttitle=x>next",
        "<li>item<li>item</li></ul>",
        "trailing <",
        "<script",
        "",
    ]

    @Test(arguments: samples) func matchesTheRegexVersion(html: String) {
        // Compare before entity decoding and whitespace collapsing, which are unchanged.
        let scanned = Self.scan(html)
        let regex = Self.regexStrip(html)
        #expect(scanned == regex)
    }

    static func scan(_ html: String) -> String {
        var bytes = Array(html.utf8)
        bytes = HTMLScanner.removingBlocks(bytes, opener: "<script", closer: "</script>", wordBoundary: true)
        bytes = HTMLScanner.removingBlocks(bytes, opener: "<style", closer: "</style>", wordBoundary: true)
        bytes = HTMLScanner.removingBlocks(bytes, opener: "<!--", closer: "-->", wordBoundary: false)
        bytes = HTMLScanner.replacingTags(bytes, onlyLineBreaks: true)
        bytes = HTMLScanner.replacingTags(bytes, onlyLineBreaks: false)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The regex passes the scanner replaced.
    static func regexStrip(_ html: String) -> String {
        var text = html
        for pattern in ["(?is)<script\\b.*?</script>", "(?is)<style\\b.*?</style>", "(?s)<!--.*?-->"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "(?i)<(br|/p|/div|/li|/h[1-6]|/tr)\\b[^>]*>", with: "\n", options: .regularExpression)
        return text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    /// Unclosed openers made the regexes quadratic (hours for this input); the scanner is
    /// linear, under a second each even in a debug build.
    @Test(.timeLimit(.minutes(1))) func unclosedOpenersStayFast() {
        for opener in ["<script ", "<style ", "<!--", "<", "<br "] {
            let html = String(repeating: opener, count: 500_000 / opener.count)
            let start = ContinuousClock.now
            _ = TextDecoding.plainText(fromHTML: html)
            #expect(ContinuousClock.now - start < .seconds(5), "\(opener)")
        }
    }
}

@Suite("Document size limits")
struct DocumentLimitTests {
    let directory: TemporaryDirectory

    init() throws { directory = try TemporaryDirectory() }

    @Test func realWordDocumentIsMeasuredAndRead() async throws {
        let text = "Quarterly revenue by region grew strongly."
        let data = try NSAttributedString(string: text).data(
            from: NSRange(location: 0, length: text.utf16.count),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        )
        let url = try Fixtures.writeData(data, named: "report.docx", in: directory.url)
        let expanded = try #require(DocumentSize.zipUncompressedSize(url))
        #expect(expanded > 0)
        let chunks = try await collect(TextExtractor(), url)
        #expect(chunks.first?.text?.contains("Quarterly revenue") == true)
    }

    @Test func zipBombIsRejectedBeforeParsing() async throws {
        // A tiny archive whose directory says it inflates to 4 GB.
        let url = try Fixtures.writeData(Self.zip(entries: [("word/document.xml", 0xFFFF_FFF0)]), named: "bomb.docx", in: directory.url)
        #expect(DocumentSize.zipUncompressedSize(url) == 0xFFFF_FFF0)
        let limit = ExtractionOptions.default.maxTextBytes * TextExtractor.expansionAllowance
        try await expectExtractionError(.tooLarge(limit: limit), TextExtractor(), url)
    }

    @Test func sizesAddUpAcrossEntries() throws {
        let data = Self.zip(entries: [("a.xml", 1_000), ("b.xml", 2_500), ("c.png", 7)])
        let url = try Fixtures.writeData(data, named: "doc.odt", in: directory.url)
        #expect(DocumentSize.zipUncompressedSize(url) == 3_507)
    }

    @Test func notAZipIsNil() throws {
        let url = try Fixtures.writeData(Data(repeating: 0x41, count: 100), named: "fake.docx", in: directory.url)
        #expect(DocumentSize.zipUncompressedSize(url) == nil)
    }

    @Test func packageCountsAllItsFiles() async throws {
        let text = String(repeating: "Rich text in a package. ", count: 100)
        let wrapper = try #require(
            NSAttributedString(string: text).rtfdFileWrapper(from: NSRange(location: 0, length: text.utf16.count))
        )
        let url = directory.file("notes.rtfd")
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        #expect(DocumentSize.onDisk(url) > 1_000)
        let small = TextExtractor(options: ExtractionOptions(maxTextBytes: 1_000))
        try await expectExtractionError(.tooLarge(limit: 1_000), small, url)
    }

    /// A stored (uncompressed) zip whose central directory claims the given uncompressed sizes.
    static func zip(entries: [(name: String, claimedSize: UInt32)]) -> Data {
        var archive = Data()
        var directory = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let offset = UInt32(archive.count)
            archive += le32(0x0403_4B50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
            archive += le32(0) + le32(0) + le32(entry.claimedSize) + le16(UInt16(name.count)) + le16(0) + name
            directory += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
            directory += le32(0) + le32(0) + le32(entry.claimedSize) + le16(UInt16(name.count)) + le16(0) + le16(0)
            directory += le16(0) + le16(0) + le32(0) + le32(offset) + name
        }
        let start = UInt32(archive.count)
        archive += directory
        archive += le32(0x0605_4B50) + le16(0) + le16(0) + le16(UInt16(entries.count)) + le16(UInt16(entries.count))
        archive += le32(UInt32(directory.count)) + le32(start) + le16(0)
        return archive
    }

    static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}
