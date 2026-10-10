import CoreGraphics
import Foundation
import GlintCore
import Testing

@testable import GlintEmbedding

@Suite("HashingEmbeddingProvider")
struct HashingProviderTests {
    let provider = HashingEmbeddingProvider()

    @Test func isDeterministicAndNormalized() async throws {
        let first = try await provider.embed([.text("blue mug on a desk")], purpose: .document)
        let second = try await provider.embed([.text("blue mug on a desk")], purpose: .query)
        #expect(first == second)
        #expect(abs(first[0].cosine(first[0]) - 1) < 1e-5)
        #expect(first[0].space == ModelCatalog.hashing.space)
    }

    @Test func overlappingTextIsCloser() async throws {
        let vectors = try await provider.embed(
            [.text("pricing chart acme"), .text("acme pricing chart deck"), .text("beach holiday photos")],
            purpose: .document
        )
        #expect(vectors[0].cosine(vectors[1]) > vectors[0].cosine(vectors[2]))
    }

    @Test func rejectsMediaWithoutText() async {
        await #expect(throws: EmbeddingError.self) {
            _ = try await provider.embed([.audio(AudioClip(samples: [0, 0]))], purpose: .document)
        }
    }

    @Test func usesTextPartsOfInterleavedInput() async throws {
        let vectors = try await provider.embed(
            [.interleaved([.audio(AudioClip(samples: [0])), .text("deadline")]), .text("deadline")],
            purpose: .document
        )
        #expect(abs(vectors[0].cosine(vectors[1]) - 1) < 1e-5)
    }
}

@Suite("AppleOnDeviceEmbeddingProvider")
struct AppleProviderTests {
    @Test func semanticNeighboursAreCloser() async throws {
        let provider = try AppleOnDeviceEmbeddingProvider()
        let vectors = try await provider.embed(
            [.text("a dog playing on the beach"), .text("puppy running on sand"), .text("quarterly revenue report")],
            purpose: .document
        )
        #expect(vectors.allSatisfy { $0.dimension == 512 })
        #expect(vectors[0].cosine(vectors[1]) > vectors[0].cosine(vectors[2]))
    }

    @Test func describesImagesIntoTheSameSpace() async throws {
        let provider = try AppleOnDeviceEmbeddingProvider()
        let sky = try #require(Self.solidImage(red: 0.35, green: 0.6, blue: 0.95))
        let vectors = try await provider.embed([.image(sky)], purpose: .document)
        #expect(vectors.count == 1)
        #expect(vectors[0].space == provider.descriptor.space)
    }

    @Test func emptyTextGivesZeroVector() async throws {
        let provider = try AppleOnDeviceEmbeddingProvider()
        let vectors = try await provider.embed([.text("   ")], purpose: .document)
        #expect(vectors[0].values.allSatisfy { $0 == 0 })
    }

    static func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage? {
        let context = CGContext(
            data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        return context?.makeImage()
    }
}

@Suite("PriorityGate")
struct PriorityGateTests {
    @Test func indexerWaitsForSearchToFinish() async throws {
        let gate = PriorityGate(quietPeriod: .milliseconds(50))
        let clock = ContinuousClock()
        let searchDone = clock.now
        try await gate.withSearchPriority { try await Task.sleep(for: .milliseconds(30)) }
        let start = clock.now
        await gate.waitForIndexingTurn()
        // The quiet period started when the search ended.
        #expect(clock.now - start >= .milliseconds(30))
        #expect(clock.now - searchDone >= .milliseconds(50))
    }

    @Test func batchesShrinkWhileTyping() async {
        let gate = PriorityGate()
        #expect(await gate.recommendedBatchSize(16) == 16)
        await gate.withSearchPriority {}
        #expect(await gate.recommendedBatchSize(16) == 4)
    }

    @Test func queryEncoderUsesProviderSpace() async throws {
        let encoder = GatedQueryEncoder(provider: HashingEmbeddingProvider(), gate: PriorityGate())
        let embedding = try await encoder.encode(query: "receipt")
        #expect(embedding.space == encoder.space)
    }
}

@Suite("ModelCatalog")
struct ModelCatalogTests {
    @Test func onlyCommerciallyLicensedModelsShip() {
        #expect(ModelCatalog.all.allSatisfy { $0.descriptor.allowsCommercialUse })
    }

    @Test func spacesAreDistinct() {
        let spaces = Set(ModelCatalog.all.map(\.descriptor.space))
        #expect(spaces.count == ModelCatalog.all.count)
    }
}
