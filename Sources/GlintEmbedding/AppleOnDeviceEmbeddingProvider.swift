import Foundation
import GlintCore
import NaturalLanguage

/// Interim embedding provider built only from macOS frameworks (see ADR 0002).
///
/// Media is first described with words by Vision and SoundAnalysis classifiers, then every
/// input is embedded with the system's 512-dimension English sentence embedding. This gives
/// one shared space for all five media today, with no download, while the EmbeddingGemma 2
/// MLX port goes through the M0 spike. Swapping providers rebuilds the index in the
/// background because vectors are tagged with `descriptor.space`.
public struct AppleOnDeviceEmbeddingProvider: EmbeddingProvider {
    public let descriptor = ModelCatalog.appleOnDevice
    private let encoder: SentenceEncoder
    private let describer = MediaDescriber()

    /// Fails when the sentence embedding assets are missing on this Mac.
    public init() throws {
        encoder = try SentenceEncoder()
    }

    public func embed(_ batch: [EmbeddingInput], purpose: EmbeddingPurpose) async throws -> [Embedding] {
        var embeddings: [Embedding] = []
        embeddings.reserveCapacity(batch.count)
        for input in batch {
            try Task.checkCancellation()
            let text = describer.describe(input)
            let values = await encoder.vector(for: text)
            embeddings.append(Embedding(normalizing: values, space: descriptor.space))
        }
        return embeddings
    }
}

/// Serializes access to `NLEmbedding`, which is not documented as thread-safe.
actor SentenceEncoder {
    private let embedding: NLEmbedding
    private let dimension: Int
    /// Long text is embedded in segments of this many words and mean-pooled.
    private let wordsPerSegment = 120
    private let maxSegments = 4

    init() throws {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw EmbeddingError.modelUnavailable(ModelCatalog.appleOnDevice.id)
        }
        self.embedding = embedding
        dimension = embedding.dimension
    }

    /// The pooled vector for `text`, or a zero vector when nothing could be embedded
    /// (a zero vector never matches anything, so the chunk stays keyword-only).
    func vector(for text: String) -> [Float] {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return zero }
        var sum = [Double](repeating: 0, count: dimension)
        var segments = 0
        var start = 0
        while start < words.count, segments < maxSegments {
            let end = min(start + wordsPerSegment, words.count)
            let segment = words[start..<end].joined(separator: " ")
            if let vector = embedding.vector(for: segment), vector.count == dimension {
                for index in 0..<dimension { sum[index] += vector[index] }
                segments += 1
            }
            start = end
        }
        guard segments > 0 else { return zero }
        return sum.map { Float($0 / Double(segments)) }
    }

    private var zero: [Float] { [Float](repeating: 0, count: dimension) }
}
