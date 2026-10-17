import CoreGraphics
import Foundation
import GlintCore
import GlintTestSupport
import Testing
import UniformTypeIdentifiers

@testable import GlintExtractors

@Suite("PDFExtractor")
struct PDFExtractorTests {
    let directory: TemporaryDirectory
    let extractor = PDFExtractor()

    init() throws { directory = try TemporaryDirectory() }

    @Test func extractsTextAndVisualChunksPerPage() async throws {
        let url = try Fixtures.writePDF(
            pages: ["Revenue by region chart for the Acme pitch", "Appendix: pricing tiers and discounts"],
            in: directory.url
        )
        let chunks = try await collect(extractor, url)
        #expect(chunks.count == 4)
        #expect(chunks.map(\.ordinal) == [0, 1, 2, 3])
        #expect(chunks.map(\.locator) == [.page(0), .page(0), .page(1), .page(1)])

        #expect(chunks[0].text?.contains("Acme pitch") == true)
        #expect(chunks[2].text?.contains("pricing tiers") == true)

        for visual in [chunks[1], chunks[3]] {
            #expect(visual.text == nil)
            guard case .image(let image) = visual.input else {
                Issue.record("Expected an image input")
                continue
            }
            #expect(max(image.width, image.height) == 1_024)
        }
    }

    @Test func thumbnailOnlyOnFirstChunkOfEachPage() async throws {
        let url = try Fixtures.writePDF(pages: ["One", "Two", "Three"], in: directory.url)
        let chunks = try await collect(extractor, url)
        let thumbnails = chunks.filter { $0.preview.thumbnail != nil }
        #expect(thumbnails.map(\.preview.thumbnailKey) == ["p0", "p1", "p2"])
        #expect(thumbnails.allSatisfy { max($0.preview.thumbnail?.width ?? 0, $0.preview.thumbnail?.height ?? 0) <= 512 })
    }

    @Test func renderHasInk() async throws {
        let url = try Fixtures.writePDF(pages: [String(repeating: "Dark text block. ", count: 40)], in: directory.url)
        let chunks = try await collect(extractor, url)
        let thumbnail = try #require(chunks.first?.preview.thumbnail)
        #expect(darkPixelFraction(thumbnail) > 0.005)
    }

    @Test func pageWithoutTextLayerFallsBackToOCRAndStillHasVisualChunk() async throws {
        let url = try Fixtures.writePDF(pages: [""], in: directory.url)
        let chunks = try await collect(extractor, url)
        #expect(chunks.count == 1)
        #expect(chunks[0].input != nil)
        #expect(chunks[0].preview.thumbnailKey == "p0")
    }

    @Test func respectsPageCap() async throws {
        let url = try Fixtures.writePDF(pages: ["a page", "b page", "c page"], in: directory.url)
        let capped = PDFExtractor(options: ExtractionOptions(maxPDFPages: 2))
        let pages = Set(try await collect(capped, url).compactMap(\.locator.pageIndex))
        #expect(pages == [0, 1])
    }

    @Test func corruptAndEmptyFilesFail() async throws {
        let corrupt = try Fixtures.writeData(Data("not a pdf at all".utf8), named: "broken.pdf", in: directory.url)
        try await expectExtractionError(.corrupt, extractor, corrupt)
        let empty = try Fixtures.writeData(Data(), named: "empty.pdf", in: directory.url)
        try await expectExtractionError(.empty, extractor, empty)
    }

    /// A cancelled consumer ends the stream early (standard `AsyncStream` semantics), so
    /// callers check `Task.isCancelled` after the loop rather than catching an error.
    @Test func consumerCancellationStopsExtraction() async throws {
        let url = try Fixtures.writePDF(pages: Array(repeating: "page text", count: 30), in: directory.url)
        let ref = try Fixtures.fileRef(url)
        let task = Task {
            var count = 0
            do {
                for try await _ in extractor.chunks(of: ref) {
                    count += 1
                    if count == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            } catch ExtractionError.cancelled {
                return count
            }
            return count
        }
        let produced = try await task.value
        #expect(produced == 2)
    }
}

@Suite("ImageExtractor")
struct ImageExtractorTests {
    let directory: TemporaryDirectory

    init() throws { directory = try TemporaryDirectory() }

    @Test func keepsOCRTextOnlyWhenItHasAWord() {
        // Edges and textures in photos that the recognizer reads as text.
        #expect(!ImageExtractor.containsWord("•–"))
        #expect(!ImageExtractor.containsWord("211 *A3"))
        #expect(!ImageExtractor.containsWord(""))
        // A single sign is still worth a keyword match.
        #expect(ImageExtractor.containsWord("STOP"))
        #expect(ImageExtractor.containsWord("Gate 12"))
    }

    @Test func fusesWordsOnlyWhenTheyReadLikeText() {
        // A photo of a train coach without camera metadata: a few garbled signs.
        #expect(!ImageExtractor.readsLikeText("Ja석 ENTRY CIR 23381| 2338I1 65-72 0อลง•oibE 2D.6.3 LIFT HERE"))
        // A small rendered screenshot: short lines, but words.
        #expect(ImageExtractor.readsLikeText("Flight confirmation\nIndiGo 6E 2341\nBLR to GOI · 12 Dec\nBooking ref QX7P2M"))
        #expect(!ImageExtractor.readsLikeText(""))
        // A screenshot: sentences, even with UI chrome around them.
        #expect(ImageExtractor.readsLikeText("5:02 4G Virtual Machines built for Apple silicon and AI agents, lightweight and fast"))
        // Long but garbled: handwriting the recognizer could not read.
        #expect(
            !ImageExtractor.readsLikeText(
                Array(repeating: "TpiTh.T47,A TrTR TTP*YI DKVn5'I1 laL8*JN 3'1411ATT4 word", count: 12).joined(separator: " ")))
    }

    @Test func screenshotsEmbedTheirWords() async throws {
        let url = try Fixtures.writeTextImage("FLIGHT CONFIRMATION FOR YOUR TRIP TO GOA DEPARTING MONDAY MORNING", in: directory.url)
        let chunks = try await collect(ImageExtractor(options: ExtractionOptions()), url)
        if case .interleaved(let parts)? = chunks.first?.input {
            #expect(parts.count == 2)
        } else {
            Issue.record("expected image and words")
        }
    }

    @Test func recognizesRenderedWords() async throws {
        let url = try Fixtures.writeTextImage("FLIGHT CONFIRMATION", in: directory.url)
        for level in [ExtractionOptions.OCRLevel.accurate, .fast] {
            let extractor = ImageExtractor(options: ExtractionOptions(ocrLevel: level))
            let chunks = try await collect(extractor, url)
            #expect(chunks.count == 1)
            let text = chunks[0].text?.uppercased() ?? ""
            #expect(text.contains("FLIGHT") || text.contains("CONFIRMATION"), "OCR (\(level)) read: \(text)")
        }
    }

    @Test func downscalesForEmbeddingAndThumbnail() async throws {
        let url = try Fixtures.writeGradientImage(in: directory.url)
        let chunks = try await collect(ImageExtractor(), url)
        let chunk = try #require(chunks.first)
        #expect(chunk.locator == .whole)
        #expect(chunk.text == nil)
        guard case .image(let image) = chunk.input else {
            Issue.record("Expected an image input")
            return
        }
        #expect(image.width == 1_024)
        #expect(image.height == 768)
        let thumbnail = try #require(chunk.preview.thumbnail)
        #expect(thumbnail.width == 512)
        #expect(chunk.preview.thumbnailKey == "i")
    }

    @Test func skipsOCRWhenDisabled() async throws {
        let url = try Fixtures.writeTextImage("HELLO", in: directory.url)
        let chunks = try await collect(ImageExtractor(options: ExtractionOptions(ocrEnabled: false)), url)
        #expect(chunks.first?.text == nil)
    }

    @Test func corruptAndEmptyFilesFail() async throws {
        let corrupt = try Fixtures.writeData(Data(repeating: 0x42, count: 512), named: "broken.png", in: directory.url)
        try await expectExtractionError(.corrupt, ImageExtractor(), corrupt)
        let empty = try Fixtures.writeData(Data(), named: "empty.jpg", in: directory.url)
        try await expectExtractionError(.empty, ImageExtractor(), empty)
    }
}

/// Fraction of pixels darker than mid-grey.
func darkPixelFraction(_ image: CGImage) -> Double {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 255, count: width * height)
    let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
        guard
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return 0 }
    return Double(pixels.filter { $0 < 128 }.count) / Double(pixels.count)
}
