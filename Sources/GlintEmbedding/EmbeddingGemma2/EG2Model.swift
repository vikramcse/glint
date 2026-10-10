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
/// The vision tower and its projection, loaded and released independently of the text tower.
final class EG2VisionPart: Module {
    @ModuleInfo(key: "vision_tower") var tower: EG2VisionModel
    @ModuleInfo(key: "embed_vision") var embedder: EG2MultimodalEmbedder

    init(_ config: EG2Configuration, _ vision: EG2VisionConfiguration) {
        _tower.wrappedValue = EG2VisionModel(vision)
        _embedder.wrappedValue = EG2MultimodalEmbedder(
            inputDimension: vision.hiddenSize, outputDimension: config.textConfig.hiddenSize, eps: vision.rmsNormEps)
        super.init()
    }

    static let prefixes = ["vision_tower.", "embed_vision."]
}

/// The audio tower and its projection, loaded and released independently of the text tower.
final class EG2AudioPart: Module {
    @ModuleInfo(key: "audio_tower") var tower: EG2AudioEncoder
    @ModuleInfo(key: "embed_audio") var embedder: EG2MultimodalEmbedder

    init(_ config: EG2Configuration, _ audio: EG2AudioConfiguration) {
        _tower.wrappedValue = EG2AudioEncoder(audio)
        _embedder.wrappedValue = EG2MultimodalEmbedder(
            inputDimension: audio.outputProjDims ?? audio.hiddenSize, outputDimension: config.textConfig.hiddenSize,
            eps: audio.rmsNormEps)
        super.init()
    }

    static let prefixes = ["audio_tower.", "embed_audio."]
}

/// Holds the optional media parts outside the text model's parameter tree, so attaching or
/// dropping one never changes the (compiled) text model.
final class EG2MediaParts {
    var vision: EG2VisionPart?
    var audio: EG2AudioPart?
}

/// EmbeddingGemma 2: text plus optional Gemma 4 vision and audio towers, mean-pooled and
/// L2-normalized into one 768-d space. Port of mlx-vlm `embedding_gemma2.py` (MIT).
final class EG2Model: Module {
    let config: EG2Configuration
    let media = EG2MediaParts()

    @ModuleInfo(key: "language_model") var languageModel: EG2TextModel

    init(_ config: EG2Configuration, towers: EG2Towers) {
        self.config = config
        _languageModel.wrappedValue = EG2TextModel(config.textConfig)
        super.init()
        createParts(towers)
    }

    private func createParts(_ towers: EG2Towers) {
        if towers.contains(.vision), media.vision == nil, let vision = config.visionConfig {
            media.vision = EG2VisionPart(config, vision)
        }
        if towers.contains(.audio), media.audio == nil, let audio = config.audioConfig {
            media.audio = EG2AudioPart(config, audio)
        }
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
        guard let vision = media.vision else { throw EmbeddingError.unsupportedModality(.image) }
        return vision.embedder(vision.tower(pixels, positions: positions))
    }

    func audioFeatures(_ features: MLXArray, mask: MLXArray) throws -> MLXArray {
        guard let audio = media.audio else { throw EmbeddingError.unsupportedModality(.audio) }
        let (encoded, invalid) = audio.tower(features, invalid: logicalNot(mask.asType(.bool)))
        let projected = audio.embedder(encoded)
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

    /// Creates and loads the vision and/or audio parts (indexing needs them; search does not).
    func attach(_ towers: EG2Towers, from directory: URL) throws {
        let missing = towers.subtracting(loadedTowers)
        guard !missing.isEmpty else { return }
        createParts(missing)
        try loadWeights(from: directory, towers: missing)
    }

    /// Converts the text tower's linear and embedding layers to affine 8-bit (group 64).
    func quantizeText() {
        quantize(model: languageModel, groupSize: 64, bits: 8)
        eval(self)
    }

    /// Drops the vision and/or audio parts and frees their GPU memory.
    func detach(_ towers: EG2Towers) {
        if towers.contains(.vision) { media.vision = nil }
        if towers.contains(.audio) { media.audio = nil }
        Memory.clearCache()
    }

    var loadedTowers: EG2Towers {
        var towers: EG2Towers = .text
        if media.vision != nil { towers.insert(.vision) }
        if media.audio != nil { towers.insert(.audio) }
        return towers
    }

    /// Loads weights from `model*.safetensors` in `directory` into the text model and whichever
    /// media parts exist, each verified on its own (`towers` limits which ones are loaded).
    func loadWeights(from directory: URL, towers: EG2Towers = .all) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }
        guard !files.isEmpty else { throw EG2Error.missingWeights }
        var text: [String: MLXArray] = [:]
        var vision: [String: MLXArray] = [:]
        var audio: [String: MLXArray] = [:]
        for file in files {
            for (key, value) in try loadArrays(url: file) {
                guard let (name, array) = sanitize(key: key, value: value) else { continue }
                if EG2VisionPart.prefixes.contains(where: name.hasPrefix) {
                    vision[name] = array
                } else if EG2AudioPart.prefixes.contains(where: name.hasPrefix) {
                    audio[name] = array
                } else {
                    text[name] = array
                }
            }
        }
        if towers.contains(.text) {
            try update(parameters: ModuleParameters.unflattened(text), verify: [.noUnusedKeys])
            eval(self)
        }
        if towers.contains(.vision), let part = media.vision {
            try part.update(parameters: ModuleParameters.unflattened(vision), verify: [.noUnusedKeys])
            eval(part)
        }
        if towers.contains(.audio), let part = media.audio {
            try part.update(parameters: ModuleParameters.unflattened(audio), verify: [.noUnusedKeys])
            eval(part)
        }
    }

    /// Mirrors the reference `sanitize`: drops unused towers and rotary caches, and converts
    /// PyTorch conv layouts to MLX's channels-last layout.
    private func sanitize(key rawKey: String, value: MLXArray) -> (String, MLXArray)? {
        let key = rawKey.hasPrefix("model.") ? String(rawKey.dropFirst("model.".count)) : rawKey
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
