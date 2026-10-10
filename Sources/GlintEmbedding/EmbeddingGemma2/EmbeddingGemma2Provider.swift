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
    /// - Parameter quantization: weight precision of the resident text tower; 8-bit halves its
    ///   memory (see ADR 0006 for the accuracy check). Media towers stay bf16.
    public init(
        directory: URL, towers: EG2Towers = .all, dimensions: Int = 512, quantization: EG2Quantization = .int8
    ) async throws {
        let config = try EG2Configuration.load(from: directory)
        guard [768, 512, 256, 128].contains(dimensions), dimensions <= config.textConfig.embeddingDim else {
            throw EmbeddingError.modelUnavailable("dimension \(dimensions)")
        }
        let tokenizer = try await TokenizerLoader.load(directory)
        var descriptor = ModelCatalog.embeddingGemma2
        descriptor.dimensions = dimensions
        self.descriptor = descriptor
        runtime = try EG2Runtime(
            directory: directory, config: config, tokenizer: tokenizer, towers: towers, quantization: quantization)
        await runtime.warmUp()
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
    private let directory: URL
    /// Text sequences are batched together; media inputs run one at a time to bound memory.
    private let textBatchSize = 16
    /// Images, frames and audio embedded per model call.
    private let mediaBatchSize = 4
    /// Media towers unload after this long without media input.
    private let idleUnload: Duration = .seconds(120)
    private var lastMediaUse = ContinuousClock.now
    private var unloadTask: Task<Void, Never>?

    init(
        directory: URL, config: EG2Configuration, tokenizer: any Tokenizer, towers: EG2Towers,
        quantization: EG2Quantization = .none
    ) throws {
        let model = EG2Model(config, towers: towers)
        try model.loadWeights(from: directory)
        if quantization == .int8 { model.quantizeText() }
        // Return freed buffers to the system instead of caching them for reuse.
        Memory.cacheLimit = 64 * 1_024 * 1_024
        self.model = model
        self.directory = directory
        processor = EG2Processor(tokenizer: tokenizer, config: config)
    }

    var loadedTowers: EG2Towers { model.loadedTowers }

    /// Loads the towers `inputs` need and schedules unloading when media stops arriving.
    private func prepareTowers(for inputs: [EmbeddingInput]) throws {
        var needed: EG2Towers = []
        for input in inputs {
            let modalities = input.modalities
            if modalities.contains(.image) || modalities.contains(.video) { needed.insert(.vision) }
            if modalities.contains(.audio) { needed.insert(.audio) }
        }
        guard !needed.isEmpty else { return }
        lastMediaUse = .now
        let missing = needed.subtracting(model.loadedTowers)
        if !missing.isEmpty {
            try model.attach(missing, from: directory)
            Log.embedding.info("Loaded media towers for indexing")
        }
        scheduleUnload()
    }

    private func scheduleUnload() {
        guard unloadTask == nil else { return }
        unloadTask = Task { [idleUnload] in
            while !Task.isCancelled {
                try? await Task.sleep(for: idleUnload)
                if self.unloadIfIdle() { return }
            }
        }
    }

    /// Compiles the text graph for the common query lengths so the first searches are fast.
    func warmUp() {
        for length in [16, 32, 48, 64] {
            let ids = MLXArray([Int32](repeating: Int32(EG2Processor.eosToken), count: length), [1, length])
            let mask = MLXArray.ones([1, length], type: Int32.self)
            eval(model.compiledText(ids, mask))
        }
    }

    func detachMediaForTesting() {
        model.detach([.vision, .audio])
    }

    private func unloadIfIdle() -> Bool {
        guard ContinuousClock.now - lastMediaUse >= idleUnload else { return false }
        model.detach([.vision, .audio])
        unloadTask = nil
        Log.embedding.info("Unloaded idle media towers")
        return true
    }

    func embed(_ inputs: [EmbeddingInput], purpose: EmbeddingPurpose) throws -> [[Float]] {
        try prepareTowers(for: inputs)
        var results = [[Float]?](repeating: nil, count: inputs.count)
        var textIndices: [Int] = []
        var mediaIndices: [Int] = []
        for (index, input) in inputs.enumerated() {
            if case .text = input { textIndices.append(index) } else { mediaIndices.append(index) }
        }
        // Media runs in small batches: the GPU is underused one image at a time, while large
        // batches of 2,520-patch images cost a lot of memory.
        for start in stride(from: 0, to: mediaIndices.count, by: mediaBatchSize) {
            let indices = Array(mediaIndices[start..<min(start + mediaBatchSize, mediaIndices.count)])
            let items = try indices.map { try processor.prepare(inputs[$0], purpose: purpose) }
            for (index, vector) in zip(indices, try run(items)) { results[index] = vector }
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

/// Weight precision of the resident text tower.
public enum EG2Quantization: Sendable, Hashable {
    case none
    /// Affine 8-bit, group size 64.
    case int8
}

/// Loads the checkpoint's `tokenizer.json` (no network).
enum TokenizerLoader {
    static func load(_ directory: URL) async throws -> any Tokenizer {
        try await AutoTokenizer.from(modelFolder: directory)
    }
}
