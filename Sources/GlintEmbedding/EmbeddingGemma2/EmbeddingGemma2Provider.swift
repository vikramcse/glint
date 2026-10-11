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
    ///   memory (see ADR 0006 for the accuracy check).
    /// - Parameter mediaQuantization: weight precision of the vision and audio towers, applied
    ///   each time they load for indexing. 8-bit matches bf16 on the COCO photo benchmark
    ///   (category F1 0.557 vs 0.550) and lowers the indexing peak by about 0.4 GB.
    /// - Parameter idleUnload: release the model after this long without any embedding;
    ///   the next call reloads it (`nil`: keep it loaded).
    public init(
        directory: URL, towers: EG2Towers = .all, dimensions: Int = 512, quantization: EG2Quantization = .int8,
        mediaQuantization: EG2Quantization = .int8, idleUnload: Duration? = nil
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
            directory: directory, config: config, tokenizer: tokenizer, towers: towers, quantization: quantization,
            mediaQuantization: mediaQuantization, textIdleUnload: idleUnload)
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
///
/// The text tower stays loaded while Glint is in use and is released after `textIdleUnload`
/// without any embedding (about 0.3 GB back to the system); the next call reloads it, which
/// takes a second or two.
actor EG2Runtime {
    private var model: EG2Model?
    /// `model`'s compiled text path, created with it and dropped with it.
    private var compiledText: (@Sendable (MLXArray, MLXArray) -> MLXArray)?
    private let processor: EG2Processor
    private let directory: URL
    private let config: EG2Configuration
    private let towers: EG2Towers
    private let quantized: EG2Towers
    /// Text sequences are batched together; media inputs run one at a time to bound memory.
    private let textBatchSize = 16
    /// Images, frames and audio embedded per model call.
    private let mediaBatchSize = 4
    /// Media towers unload after this long without media input.
    private let idleUnload: Duration = .seconds(120)
    private var lastMediaUse = ContinuousClock.now
    private var unloadTask: Task<Void, Never>?
    /// The whole model unloads after this long without any embedding (`nil`: never).
    private let textIdleUnload: Duration?
    private var lastUse = ContinuousClock.now
    private var textUnloadTask: Task<Void, Never>?

    init(
        directory: URL, config: EG2Configuration, tokenizer: any Tokenizer, towers: EG2Towers,
        quantization: EG2Quantization = .none, mediaQuantization: EG2Quantization = .none,
        textIdleUnload: Duration? = nil
    ) throws {
        // Return freed buffers to the system instead of caching them for reuse. Set before
        // loading: otherwise the freed bf16 weights stay cached (about 0.5 GB for the text tower).
        Memory.cacheLimit = 64 * 1_024 * 1_024
        var quantized: EG2Towers = []
        if quantization == .int8 { quantized.insert(.text) }
        if mediaQuantization == .int8 { quantized.formUnion([.vision, .audio]) }
        self.quantized = quantized
        self.config = config
        self.towers = towers
        self.directory = directory
        self.textIdleUnload = textIdleUnload
        processor = EG2Processor(tokenizer: tokenizer, config: config)
        model = try Self.load(config: config, towers: towers, from: directory, quantized: quantized)
    }

    private static func load(config: EG2Configuration, towers: EG2Towers, from directory: URL, quantized: EG2Towers) throws -> EG2Model {
        let model = EG2Model(config, towers: towers)
        try model.loadWeights(from: directory, quantized: quantized)
        return model
    }

    /// The model, reloaded (text tower only) if it was released while idle.
    private func loadedModel() throws -> EG2Model {
        lastUse = .now
        scheduleTextUnload()
        if let model { return model }
        let reloaded = try Self.load(config: config, towers: towers.intersection(.text), from: directory, quantized: quantized)
        model = reloaded
        warmUp()
        Log.embedding.info("Reloaded the model after idle")
        return reloaded
    }

    private func scheduleTextUnload() {
        guard let textIdleUnload, textUnloadTask == nil else { return }
        textUnloadTask = Task { [textIdleUnload] in
            while !Task.isCancelled {
                try? await Task.sleep(for: textIdleUnload)
                if self.unloadModelIfIdle() { return }
            }
        }
    }

    private func unloadModelIfIdle() -> Bool {
        guard let textIdleUnload, ContinuousClock.now - lastUse >= textIdleUnload else { return false }
        compiledText = nil
        model = nil
        unloadTask?.cancel()
        unloadTask = nil
        textUnloadTask = nil
        Memory.clearCache()
        Log.embedding.info("Unloaded the idle model")
        return true
    }

    var loadedTowers: EG2Towers { model?.loadedTowers ?? [] }

    private func compiled(_ model: EG2Model) -> @Sendable (MLXArray, MLXArray) -> MLXArray {
        if let compiledText { return compiledText }
        let made = model.compileText()
        compiledText = made
        return made
    }

    /// Loads the towers `inputs` need and schedules unloading when media stops arriving.
    private func prepareTowers(for inputs: [EmbeddingInput], model: EG2Model) throws {
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
            try model.attach(missing, from: directory, quantized: quantized.intersection([.vision, .audio]))
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
        guard let model else { return }
        for length in [16, 32, 48, 64] {
            let ids = MLXArray([Int32](repeating: Int32(EG2Processor.eosToken), count: length), [1, length])
            let mask = MLXArray.ones([1, length], type: Int32.self)
            eval(compiled(model)(ids, mask))
        }
    }

    func detachMediaForTesting() {
        model?.detach([.vision, .audio])
    }

    private func unloadIfIdle() -> Bool {
        guard ContinuousClock.now - lastMediaUse >= idleUnload else { return false }
        model?.detach([.vision, .audio])
        unloadTask = nil
        Log.embedding.info("Unloaded idle media towers")
        return true
    }

    func embed(_ inputs: [EmbeddingInput], purpose: EmbeddingPurpose) throws -> [[Float]] {
        let model = try loadedModel()
        try prepareTowers(for: inputs, model: model)
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
            for (index, vector) in zip(indices, try run(items, model: model)) { results[index] = vector }
        }
        for start in stride(from: 0, to: textIndices.count, by: textBatchSize) {
            let indices = Array(textIndices[start..<min(start + textBatchSize, textIndices.count)])
            let items = try indices.map { try processor.prepare(inputs[$0], purpose: purpose) }
            for (index, vector) in zip(indices, runText(items, model: model)) { results[index] = vector }
        }
        return results.map { $0 ?? [] }
    }

    func embedRaw(_ texts: [String]) throws -> [[Float]] {
        let model = try loadedModel()
        let items = texts.map { text in
            EG2Processor.Item(
                ids: [Int32(EG2Processor.bosToken)] + processor.tokenizer.encode(text: text, addSpecialTokens: false).map(Int32.init)
                    + [Int32(EG2Processor.eosToken)])
        }
        return runText(items, model: model)
    }

    /// Runs a prepared batch (parity tests feed reference tensors directly).
    func embed(batch: EG2Batch) throws -> [Float] {
        let output = try loadedModel()(batch)
        eval(output)
        return output[0].asArray(Float.self)
    }

    /// Text-only batches go through the compiled graph with bucketed lengths and batch sizes.
    private func runText(_ items: [EG2Processor.Item], model: EG2Model) -> [[Float]] {
        let length = EG2Processor.bucketed(items.map(\.ids.count).max() ?? 1)
        var padded = items
        // Pad the batch to a power of two so a few compiled shapes cover every call.
        let rows = max(1, 1 << Int(ceil(log2(Double(items.count)))))
        while padded.count < rows { padded.append(EG2Processor.Item(ids: [Int32(EG2Processor.eosToken)])) }
        let batch = processor.batch(padded, padTo: length)
        let output = compiled(model)(batch.inputIDs, batch.attentionMask)
        eval(output)
        let width = output.dim(1)
        let flat = output.asArray(Float.self)
        return (0..<items.count).map { Array(flat[($0 * width)..<(($0 + 1) * width)]) }
    }

    private func run(_ items: [EG2Processor.Item], model: EG2Model) throws -> [[Float]] {
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

