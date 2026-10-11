import CoreGraphics
import Foundation

/// A media modality an embedding model can encode.
public enum Modality: String, Sendable, Codable, CaseIterable, Hashable {
    case text, image, audio, video
}

/// Why an input is being embedded. Models use different task prompts per purpose.
public enum EmbeddingPurpose: Sendable, Hashable {
    /// A user's search query (EmbeddingGemma task prompt `SearchQuery`).
    case query
    /// Content being indexed (EmbeddingGemma task prompt `Document` for text).
    case document
}

/// Mono PCM audio, 16 kHz unless stated otherwise.
public struct AudioClip: Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    /// Offset of the first sample within the source file, in seconds.
    public var start: Double

    public init(samples: [Float], sampleRate: Double = 16_000, start: Double = 0) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.start = start
    }

    public var duration: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
}

/// A short span of video sampled at a fixed frame rate (1 fps by default).
public struct VideoClip: Sendable {
    public var frames: [CGImage]
    public var audio: AudioClip?
    public var start: Double
    public var end: Double

    public init(frames: [CGImage], audio: AudioClip? = nil, start: Double, end: Double) {
        self.frames = frames
        self.audio = audio
        self.start = start
        self.end = end
    }
}

/// Anything an `EmbeddingProvider` can encode.
public enum EmbeddingInput: Sendable {
    case text(String)
    /// A text chunk of a named file; models that support it embed the title with the text.
    case document(title: String, text: String)
    case image(CGImage)
    case audio(AudioClip)
    case video(VideoClip)
    case interleaved([EmbeddingInput])

    /// Every modality present in the input, including nested interleaved parts.
    public var modalities: Set<Modality> {
        switch self {
        case .text, .document: [.text]
        case .image: [.image]
        case .audio: [.audio]
        case .video(let clip): clip.audio == nil ? [.video] : [.video, .audio]
        case .interleaved(let parts): parts.reduce(into: []) { $0.formUnion($1.modalities) }
        }
    }
}

/// Identifies the vector space a vector lives in. Vectors from different spaces never mix.
public struct VectorSpace: Sendable, Hashable, Codable, CustomStringConvertible {
    public var modelID: String
    public var dimension: Int

    public init(modelID: String, dimension: Int) {
        self.modelID = modelID
        self.dimension = dimension
    }

    public var description: String { "\(modelID)@\(dimension)" }
}

/// A unit-length vector in a known space.
public struct Embedding: Sendable, Hashable {
    public let values: [Float]
    public let space: VectorSpace

    /// Creates an embedding, L2-normalizing `values` (a zero vector stays zero).
    public init(normalizing values: [Float], space: VectorSpace) {
        precondition(values.count == space.dimension, "Embedding dimension mismatch")
        var norm: Float = 0
        for value in values { norm += value * value }
        norm = norm.squareRoot()
        self.values = norm > 0 ? values.map { $0 / norm } : values
        self.space = space
    }

    /// Creates an embedding from values already known to be unit length.
    public init(unchecked values: [Float], space: VectorSpace) {
        self.values = values
        self.space = space
    }

    public var dimension: Int { values.count }

    /// Cosine similarity; both vectors are unit length so this is a dot product.
    public func cosine(_ other: Embedding) -> Float {
        precondition(other.dimension == dimension, "Embedding dimension mismatch")
        var sum: Float = 0
        for index in values.indices { sum += values[index] * other.values[index] }
        return sum
    }

    /// Truncates to a Matryoshka prefix and re-normalizes.
    public func truncated(to dimension: Int) -> Embedding {
        guard dimension < self.dimension else { return self }
        return Embedding(
            normalizing: Array(values.prefix(dimension)),
            space: VectorSpace(modelID: space.modelID, dimension: dimension)
        )
    }
}
