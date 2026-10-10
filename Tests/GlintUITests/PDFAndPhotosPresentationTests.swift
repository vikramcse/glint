import Foundation
import GlintCore
import GlintSearch
import Testing

@testable import GlintUI

@Suite("PDF match target")
struct PDFMatchTargetTests {
    @Test func clampsPageIntoDocument() {
        #expect(PDFMatchTarget.clampedPage(3, pageCount: 10) == 3)
        #expect(PDFMatchTarget.clampedPage(12, pageCount: 10) == 9)
        #expect(PDFMatchTarget.clampedPage(-1, pageCount: 10) == 0)
        #expect(PDFMatchTarget.clampedPage(5, pageCount: 0) == 0)
    }

    @Test func highlightTermsComeFromSnippetMatches() {
        let snippet = Snippet.make(from: "Pricing: Team $49. Enterprise pricing for Acme", terms: ["pricing", "acme", "a"])
        let terms = PDFMatchTarget.highlightTerms(from: snippet)
        #expect(terms.map { $0.lowercased() } == ["pricing", "acme"])
    }

    @Test func targetUsesMatchedPage() {
        let result = SearchResult.fixture(name: "deck.pdf", kind: .pdf, locator: .page(4), snippet: "the pricing chart")
        let target = PDFMatchTarget(result: result)
        #expect(target.pageIndex == 4)
        #expect(target.terms == ["pricing"])
        #expect(PDFMatchTarget(result: .fixture(name: "x.pdf", kind: .pdf)).pageIndex == 0)
    }
}

@Suite("Photos presentation")
struct PhotosPresentationTests {
    @Test func photosAssetsShowLibraryAsLocation() {
        let path = PhotosLibraryPath.path(forAsset: "A/L0/001", filename: "IMG_1.HEIC")
        #expect(Formatting.folder(of: path) == "Photos Library")
        #expect(Formatting.folder(of: "/Users/a/Pictures/x.jpg").hasSuffix("Pictures"))
    }

    @Test func sourceSymbols() {
        let photos = SourceInfo(
            id: SourceID(1), path: PhotosLibraryPath.library, isExternalVolume: false, isAccessible: true, itemCount: 0)
        let drive = SourceInfo(id: SourceID(2), path: "/Volumes/SSD", isExternalVolume: true, isAccessible: true, itemCount: 0)
        #expect(photos.symbolName == "photo.on.rectangle.angled")
        #expect(photos.displayName == "Photos Library")
        #expect(drive.symbolName == "externaldrive")
    }
}
