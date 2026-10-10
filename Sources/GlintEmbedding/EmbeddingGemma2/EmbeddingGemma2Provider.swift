import Foundation
import GlintCore
import MLX
import Tokenizers

/// EmbeddingGemma 2 (Apache-2.0) running natively on Apple silicon through MLX.
///
/// One model encodes text, images, video frames and audio into a shared space. The output is
/// truncated to `dimensions` (Matryoshka: 768, 512, 256 or 128) and re-normalized. Towers are
/// loaded on demand: a query-only instance loads just the text tower.
public final class EmbeddingGemma2Provider: EmbeddingProvider, @unchecked Sendable {
    public let descriptor: ModelDescriptor
    private let runtime: EG2Runtime

    /// Loads the model from a downloaded checkpoint directory.
    /// - Parameters:
    ///   - towers: which towers to load; the search path uses `.text` only.
    ///   - dimensions: Matryoshka output size.
    public init(directory: URL, towers: EG2Towers = .all, dimensions: Int = 512) async throws {
        let config = try EG2Configuration.load(from: directory)
        guard [768, 512, 256, 128].contains(dimensions), dimensions <= config.textConfig.embeddingDim else {
            throw EmbeddingError.modelUnavailable("dimension \(dimensions)")
        }
        let tokenizer = try await TokenizerLoader.load(directory)
        var descriptor = ModelCatalog.embeddingGemma2
        descriptor.dimensions = dimensions
        self.descriptor = descriptor
        runtime = try EG2Runtime(directory: directory, config: config, tokenizer: tokenizer, towers: towers)
    }

    public func embed(_ batch: [EmbeddingInput], purpose: EmbeddingPurpose) async throws -> [Embedding] {
        let vectors = try await runtime.embed(batch, purpose: purpose)
        return vectors.map { Embedding(normalizing: Array($0.prefix(descriptor.dimensions)), space: descriptor.space) }
    }

    /// Embeds text exactly as given (prompt already included), for parity checks.
    func runtimeEmbedRaw(_ texts: [String]) async throws -> [[Float]] {
        try await runtime.embedRaw(texts)
    }

    /// Releases GPU buffers MLX keeps cached between calls (call when indexing goes idle).
    public func trimMemory() {
        Memory.clearCache()
    }
}

/// Serializes model execution: MLX evaluation is not reentrant for one model.
actor EG2Runtime {
    private let model: EG2Model
    private let processor: EG2Processor
    /// Text sequences are batched together; media inputs run one at a time to bound memory.
    private let textBatchSize = 16

    init(directory: URL, config: EG2Configuration, tokenizer: any Tokenizer, towers: EG2Towers) throws {
        let model = EG2Model(config, towers: towers)
        try model.loadWeights(from: directory)
        self.model = model
        processor = EG2Processor(tokenizer: tokenizer, config: config)
    }

    func embed(_ inputs: [EmbeddingInput], purpose: EmbeddingPurpose) throws -> [[Float]] {
        var results = [[Float]?](repeating: nil, count: inputs.count)
        var textIndices: [Int] = []
        for (index, input) in inputs.enumerated() {
            if case .text = input {
                textIndices.append(index)
            } else {
                results[index] = try run([processor.prepare(input, purpose: purpose)]).first
            }
        }
        for start in stride(from: 0, to: textIndices.count, by: textBatchSize) {
            let indices = Array(textIndices[start..<min(start + textBatchSize, textIndices.count)])
            let items = try indices.map { try processor.prepare(inputs[$0], purpose: purpose) }
            for (index, vector) in zip(indices, runText(items)) { results[index] = vector }
        }
        return results.map { $0 ?? [] }
    }

    func embedRaw(_ texts: [String]) throws -> [[Float]] {
        let items = texts.map { text in
            EG2Processor.Item(
                ids: [Int32(EG2Processor.bosToken)] + processor.tokenizer.encode(text: text, addSpecialTokens: false).map(Int32.init)
                    + [Int32(EG2Processor.eosToken)])
        }
        return runText(items)
    }

    /// Runs a prepared batch (parity tests feed reference tensors directly).
    func embed(batch: EG2Batch) throws -> [Float] {
        let output = try model(batch)
        eval(output)
        return output[0].asArray(Float.self)
    }

    /// Text-only batches go through the compiled graph with bucketed lengths and batch sizes.
    private func runText(_ items: [EG2Processor.Item]) -> [[Float]] {
        let length = EG2Processor.bucketed(items.map(\.ids.count).max() ?? 1)
        var padded = items
        // Pad the batch to a power of two so a few compiled shapes cover every call.
        let rows = max(1, 1 << Int(ceil(log2(Double(items.count)))))
        while padded.count < rows { padded.append(EG2Processor.Item(ids: [Int32(EG2Processor.eosToken)])) }
        let batch = processor.batch(padded, padTo: length)
        let output = model.compiledText(batch.inputIDs, batch.attentionMask)
        eval(output)
        let width = output.dim(1)
        let flat = output.asArray(Float.self)
        return (0..<items.count).map { Array(flat[($0 * width)..<(($0 + 1) * width)]) }
    }

    private func run(_ items: [EG2Processor.Item]) throws -> [[Float]] {
        let output = try model(processor.batch(items))
        eval(output)
        let width = output.dim(1)
        let flat = output.asArray(Float.self)
        return (0..<output.dim(0)).map { Array(flat[($0 * width)..<(($0 + 1) * width)]) }
    }
}

/// Loads the checkpoint's `tokenizer.json` (no network).
enum TokenizerLoader {
    static func load(_ directory: URL) async throws -> any Tokenizer {
        try await AutoTokenizer.from(modelFolder: directory)
    }
}
