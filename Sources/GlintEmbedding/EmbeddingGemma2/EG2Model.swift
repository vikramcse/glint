import Foundation
import GlintCore
import MLX
import MLXNN

/// Which towers to load. The search path keeps only the text tower resident (about 270M
/// parameters); indexing loads vision and audio on demand and unloads them when idle.
public struct EG2Towers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let text = EG2Towers(rawValue: 1 << 0)
    public static let vision = EG2Towers(rawValue: 1 << 1)
    public static let audio = EG2Towers(rawValue: 1 << 2)
    public static let all: EG2Towers = [.text, .vision, .audio]
}

/// EmbeddingGemma 2: text plus optional Gemma 4 vision and audio towers, mean-pooled and
/// L2-normalized into one 768-d space. Port of mlx-vlm `embedding_gemma2.py` (MIT).
final class EG2Model: Module {
    let config: EG2Configuration

    @ModuleInfo(key: "language_model") var languageModel: EG2TextModel
    @ModuleInfo(key: "vision_tower") var visionTower: EG2VisionModel?
    @ModuleInfo(key: "embed_vision") var embedVision: EG2MultimodalEmbedder?
    @ModuleInfo(key: "audio_tower") var audioTower: EG2AudioEncoder?
    @ModuleInfo(key: "embed_audio") var embedAudio: EG2MultimodalEmbedder?

    init(_ config: EG2Configuration, towers: EG2Towers) {
        self.config = config
        _languageModel.wrappedValue = EG2TextModel(config.textConfig)
        if towers.contains(.vision), let vision = config.visionConfig {
            _visionTower.wrappedValue = EG2VisionModel(vision)
            _embedVision.wrappedValue = EG2MultimodalEmbedder(
                inputDimension: vision.hiddenSize, outputDimension: config.textConfig.hiddenSize, eps: vision.rmsNormEps)
        }
        if towers.contains(.audio), let audio = config.audioConfig {
            _audioTower.wrappedValue = EG2AudioEncoder(audio)
            _embedAudio.wrappedValue = EG2MultimodalEmbedder(
                inputDimension: audio.outputProjDims ?? audio.hiddenSize, outputDimension: config.textConfig.hiddenSize,
                eps: audio.rmsNormEps)
        }
        super.init()
    }

    /// Embeds a batch of token sequences in which media placeholders have been expanded.
    /// Returns L2-normalized float32 embeddings (batch, 768).
    func callAsFunction(_ batch: EG2Batch) throws -> MLXArray {
        let ids = batch.inputIDs
        let mediaMask = logicalOr(
            logicalOr(ids .== Int32(config.imageTokenId), ids .== Int32(config.videoTokenId)),
            ids .== Int32(config.audioTokenId))
        let textIDs = which(mediaMask, MLXArray(Int32(config.textConfig.padTokenId)), ids)
        var embeddings = languageModel.embed(textIDs)

        if let pixels = batch.pixelValues, let positions = batch.imagePositionIDs {
            embeddings = try scatter(embeddings, ids: ids, token: config.imageTokenId, features: imageFeatures(pixels, positions))
        }
        if let pixels = batch.videoPixelValues, let positions = batch.videoPositionIDs {
            embeddings = try scatter(embeddings, ids: ids, token: config.videoTokenId, features: imageFeatures(pixels, positions))
        }
        if let features = batch.audioFeatures, let mask = batch.audioFeaturesMask {
            embeddings = try scatter(embeddings, ids: ids, token: config.audioTokenId, features: audioFeatures(features, mask: mask))
        }

        let hidden = languageModel(embeddings, attentionMask: batch.attentionMask)
        return Self.meanPoolAndNormalize(hidden, mask: batch.attentionMask)
    }

    /// Text-only forward pass (no media scatter), used through `compiledText`.
    func embedText(_ ids: MLXArray, mask: MLXArray) -> MLXArray {
        let hidden = languageModel(languageModel.embed(ids), attentionMask: mask)
        return Self.meanPoolAndNormalize(hidden, mask: mask)
    }

    /// The text path compiled into fused kernels. Compiled graphs are cached per input shape,
    /// so callers pad lengths to a few buckets (see `EG2Processor.bucketed`).
    lazy var compiledText: @Sendable (MLXArray, MLXArray) -> MLXArray = compile(inputs: [self], outputs: []) {
        [unowned self] ids, mask in self.embedText(ids, mask: mask)
    }

    func imageFeatures(_ pixels: MLXArray, _ positions: MLXArray) throws -> MLXArray {
        guard let visionTower, let embedVision else { throw EmbeddingError.unsupportedModality(.image) }
        return embedVision(visionTower(pixels, positions: positions))
    }

    func audioFeatures(_ features: MLXArray, mask: MLXArray) throws -> MLXArray {
        guard let audioTower, let embedAudio else { throw EmbeddingError.unsupportedModality(.audio) }
        let (encoded, invalid) = audioTower(features, invalid: logicalNot(mask.asType(.bool)))
        let projected = embedAudio(encoded)
        // Keep only valid frames of each item, concatenated in order.
        var pieces: [MLXArray] = []
        for item in 0..<projected.dim(0) {
            let valid = Int(logicalNot(invalid[item]).asType(.int32).sum().item(Int32.self))
            pieces.append(projected[item, ..<valid])
        }
        return concatenated(pieces, axis: 0)
    }

    /// Replaces each `token` position with the next feature row, in order.
    func scatter(_ embeddings: MLXArray, ids: MLXArray, token: Int, features: MLXArray) throws -> MLXArray {
        let mask = ids .== Int32(token)
        let count = Int(mask.asType(.int32).sum().item(Int32.self))
        guard count == features.dim(0) else {
            throw EG2Error.mediaTokenMismatch(tokens: count, features: features.dim(0))
        }
        guard count > 0 else { return embeddings }
        let indices = maximum(cumsum(mask.reshaped(-1).asType(.int32)) - 1, 0)
        let aligned = features[indices].reshaped(embeddings.shape)
        return which(mask.expandedDimensions(axis: -1), aligned.asType(embeddings.dtype), embeddings)
    }

    /// Mask-aware mean pooling (prompts and media tokens count, padding does not), then L2.
    static func meanPoolAndNormalize(_ hidden: MLXArray, mask: MLXArray) -> MLXArray {
        let weights = mask.asType(.float32).expandedDimensions(axis: -1)
        let summed = (hidden.asType(.float32) * weights).sum(axis: 1)
        let pooled = summed / maximum(weights.sum(axis: 1), 1e-9)
        let norm = sqrt((pooled * pooled).sum(axis: -1, keepDims: true))
        return pooled / maximum(norm, 1e-12)
    }

    // MARK: Loading

    /// Attaches and loads the vision and/or audio towers after creation (indexing needs them;
    /// search does not).
    func attach(_ towers: EG2Towers, from directory: URL) throws {
        var prefixes: [String] = []
        if towers.contains(.vision), visionTower == nil, let vision = config.visionConfig {
            visionTower = EG2VisionModel(vision)
            embedVision = EG2MultimodalEmbedder(
                inputDimension: vision.hiddenSize, outputDimension: config.textConfig.hiddenSize, eps: vision.rmsNormEps)
            prefixes += ["vision_tower.", "embed_vision."]
        }
        if towers.contains(.audio), audioTower == nil, let audio = config.audioConfig {
            audioTower = EG2AudioEncoder(audio)
            embedAudio = EG2MultimodalEmbedder(
                inputDimension: audio.outputProjDims ?? audio.hiddenSize, outputDimension: config.textConfig.hiddenSize,
                eps: audio.rmsNormEps)
            prefixes += ["audio_tower.", "embed_audio."]
        }
        guard !prefixes.isEmpty else { return }
        try loadWeights(from: directory) { key in prefixes.contains { key.hasPrefix($0) } }
    }

    /// Drops the vision and/or audio towers and their GPU memory.
    func detach(_ towers: EG2Towers) {
        if towers.contains(.vision) {
            visionTower = nil
            embedVision = nil
        }
        if towers.contains(.audio) {
            audioTower = nil
            embedAudio = nil
        }
        Memory.clearCache()
    }

    var loadedTowers: EG2Towers {
        var towers: EG2Towers = .text
        if visionTower != nil { towers.insert(.vision) }
        if audioTower != nil { towers.insert(.audio) }
        return towers
    }

    /// Loads weights for the configured towers from `model*.safetensors` in `directory`.
    /// `including` limits loading to some keys (attaching a tower later).
    func loadWeights(from directory: URL, including: ((String) -> Bool)? = nil) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }
        guard !files.isEmpty else { throw EG2Error.missingWeights }
        var weights: [String: MLXArray] = [:]
        for file in files {
            for (key, value) in try loadArrays(url: file) {
                guard let kept = sanitize(key: key, value: value) else { continue }
                if let including, !including(kept.0) { continue }
                weights[kept.0] = kept.1
            }
        }
        try update(parameters: ModuleParameters.unflattened(weights), verify: [.noUnusedKeys])
        eval(self)
    }

    /// Mirrors the reference `sanitize`: drops unused towers and rotary caches, and converts
    /// PyTorch conv layouts to MLX's channels-last layout.
    private func sanitize(key rawKey: String, value: MLXArray) -> (String, MLXArray)? {
        let key = rawKey.hasPrefix("model.") ? String(rawKey.dropFirst("model.".count)) : rawKey
        if visionTower == nil, key.hasPrefix("vision_tower.") || key.hasPrefix("embed_vision.") { return nil }
        if audioTower == nil, key.hasPrefix("audio_tower.") || key.hasPrefix("embed_audio.") { return nil }
        if key.contains("rotary_emb.inv_freq") { return nil }
        var value = value
        if key.contains("subsample_conv_projection"), key.hasSuffix("conv.weight"), let audio = config.audioConfig {
            let channels = key.contains(".layer0.") ? 1 : audio.subsamplingConvChannels[0]
            if value.dim(-1) != channels { value = value.transposed(0, 2, 3, 1) }
        }
        if key.hasSuffix("depthwise_conv1d.weight"), value.dim(-1) != 1 { value = value.transposed(0, 2, 1) }
        return (key, value)
    }
}

/// Model-ready inputs for one batch.
struct EG2Batch {
    var inputIDs: MLXArray
    var attentionMask: MLXArray
    var pixelValues: MLXArray?
    var imagePositionIDs: MLXArray?
    var videoPixelValues: MLXArray?
    var videoPositionIDs: MLXArray?
    var audioFeatures: MLXArray?
    var audioFeaturesMask: MLXArray?
}

enum EG2Error: GlintError, Equatable {
    case missingWeights
    case mediaTokenMismatch(tokens: Int, features: Int)
    case inputTooLong(tokens: Int)

    var category: ErrorCategory { .model }

    var description: String {
        switch self {
        case .missingWeights: "No model weights were found"
        case .mediaTokenMismatch(let tokens, let features): "Media tokens (\(tokens)) do not match features (\(features))"
        case .inputTooLong(let tokens): "Input of \(tokens) tokens exceeds the model window"
        }
    }
}
