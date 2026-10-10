import Foundation
import GlintCore

/// A near-free provider that accepts every modality, so throughput tests measure Glint's
/// pipeline (hashing, extraction, OCR, batching, commits) rather than a model.
public struct PipelineEmbeddingProvider: EmbeddingProvider {
    public let descriptor = ModelDescriptor(
        id: "glint.pipeline-test", version: "1", displayName: "Pipeline (tests)", dimensions: 64,
        supportedDimensions: [64], modalities: [.text, .image, .audio, .video], license: "Proprietary",
        allowsCommercialUse: true
    )
    /// Simulated model time per call and per input, to exercise cross-file batching.
    public var costPerCall: Duration
    public var costPerInput: Duration

    public init(costPerCall: Duration = .zero, costPerInput: Duration = .zero) {
        self.costPerCall = costPerCall
        self.costPerInput = costPerInput
    }

    public func embed(_ batch: [EmbeddingInput], purpose: EmbeddingPurpose) async throws -> [Embedding] {
        let cost = costPerCall + costPerInput * batch.count
        if cost > .zero { try await Task.sleep(for: cost) }
        return batch.enumerated().map { index, input in
            var values = [Float](repeating: 0, count: 64)
            values[Self.bucket(input) % 64] = 1
            values[(index * 7) % 64] += 0.5
            return Embedding(normalizing: values, space: descriptor.space)
        }
    }

    private static func bucket(_ input: EmbeddingInput) -> Int {
        switch input {
        case .text(let text): abs(text.hashValue)
        case .image: 1
        case .audio: 2
        case .video: 3
        case .interleaved(let parts): parts.first.map(bucket) ?? 4
        }
    }
}
