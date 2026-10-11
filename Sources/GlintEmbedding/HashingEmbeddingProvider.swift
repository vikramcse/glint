import Foundation
import GlintCore

/// A deterministic text embedding built by feature hashing of words and character trigrams.
/// It has no semantic knowledge, but identical and overlapping text lands close together,
/// which makes it ideal for tests, fixtures and the eval harness's smoke mode.
public struct HashingEmbeddingProvider: EmbeddingProvider {
    public let descriptor: ModelDescriptor

    public init(descriptor: ModelDescriptor = ModelCatalog.hashing) {
        self.descriptor = descriptor
    }

    public func embed(_ batch: [EmbeddingInput], purpose: EmbeddingPurpose) async throws -> [Embedding] {
        try batch.map { input in
            guard let text = Self.text(of: input) else {
                throw EmbeddingError.unsupportedModality(input.modalities.first(where: { $0 != .text }) ?? .image)
            }
            return Embedding(normalizing: vector(for: text), space: descriptor.space)
        }
    }

    private static func text(of input: EmbeddingInput) -> String? {
        switch input {
        case .text(let text), .document(_, let text): text
        case .interleaved(let parts):
            parts.compactMap { part -> String? in
                if case .text(let text) = part { text } else { nil }
            }.joined(separator: " ").nilIfEmpty
        case .image, .audio, .video: nil
        }
    }

    func vector(for text: String) -> [Float] {
        let dimension = descriptor.dimensions
        var vector = [Float](repeating: 0, count: dimension)
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        for word in words {
            add(word, weight: 1, to: &vector)
            let padded = Array("#\(word)#")
            if padded.count > 3 {
                for start in 0...(padded.count - 3) {
                    add(String(padded[start..<start + 3]), weight: 0.35, to: &vector)
                }
            }
        }
        return vector
    }

    private func add(_ feature: String, weight: Float, to vector: inout [Float]) {
        let hash = Self.fnv1a(feature)
        let index = Int(hash % UInt64(vector.count))
        let sign: Float = (hash >> 63) == 0 ? 1 : -1
        vector[index] += sign * weight
    }

    /// FNV-1a: stable across launches, unlike `Hasher`.
    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
