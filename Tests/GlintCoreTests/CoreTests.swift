import Foundation
import Testing
import UniformTypeIdentifiers

@testable import GlintCore

@Suite("MediaKind")
struct MediaKindTests {
    @Test(arguments: [
        (UTType.png, MediaKind.image),
        (.heic, .image),
        (.mpeg4Movie, .video),
        (.quickTimeMovie, .video),
        (.mp3, .audio),
        (.wav, .audio),
        (.pdf, .pdf),
        (.plainText, .document),
        (.swiftSource, .document),
        (.rtf, .document),
    ])
    func classifiesContentTypes(type: UTType, expected: MediaKind) {
        #expect(MediaKind(contentType: type) == expected)
    }

    @Test func classifiesMarkdownAndWord() throws {
        let markdown = try #require(UTType(filenameExtension: "md"))
        #expect(MediaKind(contentType: markdown) == .document)
        let word = try #require(UTType(filenameExtension: "docx"))
        #expect(MediaKind(contentType: word) == .document)
    }

    @Test func ignoresUnsupportedTypes() {
        #expect(MediaKind(contentType: .zip) == nil)
        #expect(MediaKind(contentType: .applicationBundle) == nil)
    }

    @Test func videoAndAudioRequirePro() {
        #expect(MediaKind.video.requiredFeature == .videoSearch)
        #expect(MediaKind.audio.requiredFeature == .audioSearch)
        #expect(MediaKind.image.requiredFeature == nil)
        #expect(MediaKind.document.indexingPriority < MediaKind.audio.indexingPriority)
        #expect(MediaKind.audio.indexingPriority < MediaKind.video.indexingPriority)
    }
}

@Suite("Embedding")
struct EmbeddingTests {
    let space = VectorSpace(modelID: "test", dimension: 4)

    @Test func normalizesToUnitLength() {
        let embedding = Embedding(normalizing: [3, 4, 0, 0], space: space)
        #expect(abs(embedding.cosine(embedding) - 1) < 1e-6)
        #expect(abs(embedding.values[0] - 0.6) < 1e-6)
    }

    @Test func zeroVectorStaysZero() {
        let embedding = Embedding(normalizing: [0, 0, 0, 0], space: space)
        #expect(embedding.values == [0, 0, 0, 0])
    }

    @Test func truncationRenormalizes() {
        let embedding = Embedding(normalizing: [1, 1, 1, 1], space: space)
        let truncated = embedding.truncated(to: 2)
        #expect(truncated.dimension == 2)
        #expect(truncated.space.dimension == 2)
        #expect(abs(truncated.cosine(truncated) - 1) < 1e-6)
    }

    @Test func interleavedModalitiesAreCollected() {
        let input = EmbeddingInput.interleaved([.text("a"), .audio(AudioClip(samples: [0]))])
        #expect(input.modalities == [.text, .audio])
    }

    @Test func spaceIncludesModelVersion() {
        let descriptor = ModelDescriptor(
            id: "m", version: "2", displayName: "M", dimensions: 512, supportedDimensions: [512],
            modalities: [.text], license: "Apache-2.0", allowsCommercialUse: true
        )
        #expect(descriptor.space == VectorSpace(modelID: "m/2", dimension: 512))
    }
}

@Suite("SearchFilter")
struct SearchFilterTests {
    let attributes = FileAttributes(
        kind: .image, modified: Date(timeIntervalSince1970: 1_000), path: "/Users/a/Pictures/beach.jpg"
    )

    @Test func emptyFilterMatchesEverything() {
        #expect(SearchFilter.none.matches(fileID: FileID(1), attributes: attributes))
        #expect(SearchFilter.none.isEmpty)
    }

    @Test func filtersByKind() {
        #expect(SearchFilter(kinds: [.image]).matches(fileID: FileID(1), attributes: attributes))
        #expect(!SearchFilter(kinds: [.video]).matches(fileID: FileID(1), attributes: attributes))
    }

    @Test func filtersByDateRange() {
        #expect(SearchFilter(modifiedAfter: Date(timeIntervalSince1970: 500)).matches(fileID: FileID(1), attributes: attributes))
        #expect(!SearchFilter(modifiedAfter: Date(timeIntervalSince1970: 2_000)).matches(fileID: FileID(1), attributes: attributes))
        #expect(!SearchFilter(modifiedBefore: Date(timeIntervalSince1970: 1_000)).matches(fileID: FileID(1), attributes: attributes))
    }

    @Test func folderPrefixRespectsPathComponents() {
        #expect(SearchFilter(folders: ["/Users/a/Pictures"]).matches(fileID: FileID(1), attributes: attributes))
        #expect(!SearchFilter(folders: ["/Users/a/Pic"]).matches(fileID: FileID(1), attributes: attributes))
    }

    @Test func excludesFiles() {
        #expect(!SearchFilter(excludedFiles: [FileID(1)]).matches(fileID: FileID(1), attributes: attributes))
    }
}

@Suite("ExclusionRules")
struct ExclusionRulesTests {
    @Test func skipsHiddenAndBuiltInFolders() {
        let rules = ExclusionRules.default
        #expect(rules.excludes(path: "/Users/a/.config/file.txt"))
        #expect(rules.excludes(path: "/Users/a/project/node_modules/x/readme.md"))
        #expect(!rules.excludes(path: "/Users/a/Documents/notes.md"))
    }

    @Test func honorsUserRules() {
        let rules = ExclusionRules(folders: ["/Users/a/Private"], fileExtensions: ["log"])
        #expect(rules.excludes(path: "/Users/a/Private/a.txt"))
        #expect(!rules.excludes(path: "/Users/a/PrivateNotes/a.txt"))
        #expect(rules.excludes(path: "/Users/a/Documents/server.log"))
    }
}

@Suite("FeatureGate")
struct FeatureGateTests {
    @Test func freeLocksVideoAndAudio() {
        #expect(!FeatureGateSnapshot.free.allows(.video))
        #expect(!FeatureGateSnapshot.free.allows(.audio))
        #expect(FeatureGateSnapshot.free.allows(.image))
        #expect(FeatureGateSnapshot.free.itemLimit == 10_000)
        #expect(FeatureGateSnapshot.free.sourceLimit == 3)
    }

    @Test func proAllowsEverything() {
        for kind in MediaKind.allCases { #expect(FeatureGateSnapshot.pro.allows(kind)) }
        #expect(FeatureGateSnapshot.pro.itemLimit == nil)
    }

    @Test func boxUpdatesAtomically() {
        let box = FeatureGateBox(.free)
        box.update(.pro)
        #expect(box.current == .pro)
    }
}

@Suite("IndexStatus")
struct IndexStatusTests {
    @Test func progressExcludesLockedFiles() {
        let status = IndexStatus(phase: .indexing, indexed: [.image: 30, .document: 20], pending: 50, locked: 100)
        #expect(status.totalIndexed == 50)
        #expect(status.progress == 0.5)
        #expect(status.isBusy)
    }

    @Test func emptyIndexIsComplete() {
        #expect(IndexStatus().progress == 1)
    }
}

@Suite("Errors")
struct ErrorCategoryTests {
    @Test func mapsSystemErrors() {
        #expect(CancellationError().glintCategory == .cancelled)
        #expect(CocoaError(.fileReadNoPermission).glintCategory == .permissionDenied)
        #expect(CocoaError(.fileReadNoSuchFile).glintCategory == .notFound)
        #expect(URLError(.notConnectedToInternet).glintCategory == .network)
    }
}
