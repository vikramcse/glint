import Foundation
import MLX
import MLXNN

// Gemma 4 vision encoder for EmbeddingGemma 2. Adapted from mlx-swift-lm
// `Libraries/MLXVLM/Models/Gemma4.swift` (MIT, © ml-explore) and checked against mlx-vlm
// `models/gemma4/vision.py`: takes pre-patchified pixels with explicit (x, y) patch positions,
// where position (-1, -1) marks padding.

struct EG2VisionConfiguration: Decodable, Sendable {
    var hiddenLayers: Int
    var hiddenSize: Int
    var intermediateSize: Int
    var attentionHeads: Int
    var keyValueHeads: Int
    var headDim: Int
    var patchSize: Int
    var rmsNormEps: Float
    var defaultOutputLength: Int
    var positionEmbeddingSize: Int
    var poolingKernelSize: Int
    var useClippedLinears: Bool
    var standardize: Bool
    var ropeTheta: Float

    enum CodingKeys: String, CodingKey {
        case hiddenLayers = "num_hidden_layers"
        case hiddenSize = "hidden_size"
        case intermediateSize = "intermediate_size"
        case attentionHeads = "num_attention_heads"
        case keyValueHeads = "num_key_value_heads"
        case headDim = "head_dim"
        case patchSize = "patch_size"
        case rmsNormEps = "rms_norm_eps"
        case defaultOutputLength = "default_output_length"
        case positionEmbeddingSize = "position_embedding_size"
        case poolingKernelSize = "pooling_kernel_size"
        case useClippedLinears = "use_clipped_linears"
        case standardize
        case ropeParameters = "rope_parameters"
    }

    private struct Rope: Decodable { var ropeTheta: Float?; enum CodingKeys: String, CodingKey { case ropeTheta = "rope_theta" } }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hiddenLayers = try c.decodeIfPresent(Int.self, forKey: .hiddenLayers) ?? 16
        hiddenSize = try c.decodeIfPresent(Int.self, forKey: .hiddenSize) ?? 768
        intermediateSize = try c.decodeIfPresent(Int.self, forKey: .intermediateSize) ?? 3_072
        attentionHeads = try c.decodeIfPresent(Int.self, forKey: .attentionHeads) ?? 12
        keyValueHeads = try c.decodeIfPresent(Int.self, forKey: .keyValueHeads) ?? attentionHeads
        headDim = try c.decodeIfPresent(Int.self, forKey: .headDim) ?? 64
        patchSize = try c.decodeIfPresent(Int.self, forKey: .patchSize) ?? 16
        rmsNormEps = try c.decodeIfPresent(Float.self, forKey: .rmsNormEps) ?? 1e-6
        defaultOutputLength = try c.decodeIfPresent(Int.self, forKey: .defaultOutputLength) ?? 280
        positionEmbeddingSize = try c.decodeIfPresent(Int.self, forKey: .positionEmbeddingSize) ?? 10_240
        poolingKernelSize = try c.decodeIfPresent(Int.self, forKey: .poolingKernelSize) ?? 3
        useClippedLinears = try c.decodeIfPresent(Bool.self, forKey: .useClippedLinears) ?? false
        standardize = try c.decodeIfPresent(Bool.self, forKey: .standardize) ?? false
        ropeTheta = (try c.decodeIfPresent(Rope.self, forKey: .ropeParameters))?.ropeTheta ?? 100
    }
}

/// Linear with optional input/output clamping (bounds are checkpoint buffers).
final class EG2ClippableLinear: Module, UnaryLayer {
    @ModuleInfo var linear: Linear
    @ParameterInfo(key: "input_min") var inputMin: MLXArray?
    @ParameterInfo(key: "input_max") var inputMax: MLXArray?
    @ParameterInfo(key: "output_min") var outputMin: MLXArray?
    @ParameterInfo(key: "output_max") var outputMax: MLXArray?

    init(_ inFeatures: Int, _ outFeatures: Int, clipping: Bool) {
        _linear.wrappedValue = Linear(inFeatures, outFeatures, bias: false)
        if clipping {
            _inputMin.wrappedValue = MLXArray(-Float.infinity)
            _inputMax.wrappedValue = MLXArray(Float.infinity)
            _outputMin.wrappedValue = MLXArray(-Float.infinity)
            _outputMax.wrappedValue = MLXArray(Float.infinity)
        }
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var input = x
        if let inputMin, let inputMax { input = clip(input, min: inputMin, max: inputMax) }
        let output = linear(input)
        if let outputMin, let outputMax { return clip(output, min: outputMin, max: outputMax) }
        return output
    }
}

/// Float32 RMS norm with a learned scale (vision attention q/k norms).
final class EG2Float32RMSNorm: Module, UnaryLayer {
    let eps: Float
    @ParameterInfo var weight: MLXArray

    init(dimensions: Int, eps: Float) {
        self.eps = eps
        _weight.wrappedValue = MLXArray.ones([dimensions])
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let value = x.asType(.float32)
        let normalized = value * rsqrt(mean(value.square(), axis: -1, keepDims: true) + eps)
        return (normalized * weight.asType(.float32)).asType(x.dtype)
    }
}

/// Float32 RMS norm without a scale.
final class EG2Float32RMSNormNoScale: Module, UnaryLayer {
    let eps: Float

    init(eps: Float) {
        self.eps = eps
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let value = x.asType(.float32)
        return (value * rsqrt(mean(value.square(), axis: -1, keepDims: true) + eps)).asType(x.dtype)
    }
}

private func rotateHalf(_ x: MLXArray) -> MLXArray {
    let half = x.dim(-1) / 2
    return concatenated([-x[.ellipsis, half...], x[.ellipsis, ..<half]], axis: -1)
}

/// 2-D RoPE: the head is split per spatial axis and each part is rotated independently.
/// `inputs`: (batch, length, heads, headDim); `positions`: (batch, length, 2).
func eg2ApplyAxialRoPE(_ inputs: MLXArray, positions: MLXArray, base: Float) -> MLXArray {
    let headDim = inputs.dim(-1)
    let axes = positions.dim(-1)
    let channels = 2 * (headDim / (2 * axes))
    let half = channels / 2
    let exponents = (2.0 / Float(channels)) * MLXArray(0..<half).asType(.float32)
    let timescale = pow(MLXArray(base), exponents)
    var parts: [MLXArray] = []
    for axis in 0..<axes {
        let part = inputs[.ellipsis, (axis * channels)..<((axis + 1) * channels)]
        let sinusoid = positions[.ellipsis, axis..<(axis + 1)].asType(.float32) / timescale
        let cosine = concatenated([cos(sinusoid), cos(sinusoid)], axis: -1).asType(inputs.dtype).expandedDimensions(axis: 2)
        let sine = concatenated([sin(sinusoid), sin(sinusoid)], axis: -1).asType(inputs.dtype).expandedDimensions(axis: 2)
        parts.append(part * cosine + rotateHalf(part) * sine)
    }
    return concatenated(parts, axis: -1)
}

final class EG2VisionAttention: Module {
    let heads: Int
    let kvHeads: Int
    let headDim: Int
    let ropeTheta: Float

    @ModuleInfo(key: "q_proj") var qProj: EG2ClippableLinear
    @ModuleInfo(key: "k_proj") var kProj: EG2ClippableLinear
    @ModuleInfo(key: "v_proj") var vProj: EG2ClippableLinear
    @ModuleInfo(key: "o_proj") var oProj: EG2ClippableLinear
    @ModuleInfo(key: "q_norm") var qNorm: EG2Float32RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: EG2Float32RMSNorm
    let vNorm: EG2Float32RMSNormNoScale

    init(_ config: EG2VisionConfiguration) {
        heads = config.attentionHeads
        kvHeads = config.keyValueHeads
        headDim = config.headDim
        ropeTheta = config.ropeTheta
        let clip = config.useClippedLinears
        _qProj.wrappedValue = EG2ClippableLinear(config.hiddenSize, heads * headDim, clipping: clip)
        _kProj.wrappedValue = EG2ClippableLinear(config.hiddenSize, kvHeads * headDim, clipping: clip)
        _vProj.wrappedValue = EG2ClippableLinear(config.hiddenSize, kvHeads * headDim, clipping: clip)
        _oProj.wrappedValue = EG2ClippableLinear(heads * headDim, config.hiddenSize, clipping: clip)
        _qNorm.wrappedValue = EG2Float32RMSNorm(dimensions: headDim, eps: config.rmsNormEps)
        _kNorm.wrappedValue = EG2Float32RMSNorm(dimensions: headDim, eps: config.rmsNormEps)
        vNorm = EG2Float32RMSNormNoScale(eps: config.rmsNormEps)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, positions: MLXArray, mask: MLXArray) -> MLXArray {
        let (batch, length) = (x.dim(0), x.dim(1))
        var q = qNorm(qProj(x).reshaped(batch, length, heads, headDim))
        var k = kNorm(kProj(x).reshaped(batch, length, kvHeads, headDim))
        let v = vNorm(vProj(x).reshaped(batch, length, kvHeads, headDim))
        q = eg2ApplyAxialRoPE(q, positions: positions, base: ropeTheta)
        k = eg2ApplyAxialRoPE(k, positions: positions, base: ropeTheta)
        let output = MLXFast.scaledDotProductAttention(
            queries: q.transposed(0, 2, 1, 3), keys: k.transposed(0, 2, 1, 3), values: v.transposed(0, 2, 1, 3),
            scale: 1.0, mask: .array(mask))
        return oProj(output.transposed(0, 2, 1, 3).reshaped(batch, length, -1))
    }
}

final class EG2VisionMLP: Module, UnaryLayer {
    @ModuleInfo(key: "gate_proj") var gateProj: EG2ClippableLinear
    @ModuleInfo(key: "up_proj") var upProj: EG2ClippableLinear
    @ModuleInfo(key: "down_proj") var downProj: EG2ClippableLinear

    init(_ config: EG2VisionConfiguration) {
        let clip = config.useClippedLinears
        _gateProj.wrappedValue = EG2ClippableLinear(config.hiddenSize, config.intermediateSize, clipping: clip)
        _upProj.wrappedValue = EG2ClippableLinear(config.hiddenSize, config.intermediateSize, clipping: clip)
        _downProj.wrappedValue = EG2ClippableLinear(config.intermediateSize, config.hiddenSize, clipping: clip)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProj(geluApproximate(gateProj(x)) * upProj(x))
    }
}

final class EG2VisionBlock: Module {
    @ModuleInfo(key: "self_attn") var attention: EG2VisionAttention
    @ModuleInfo var mlp: EG2VisionMLP
    @ModuleInfo(key: "input_layernorm") var inputNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionNorm: RMSNorm
    @ModuleInfo(key: "pre_feedforward_layernorm") var preFeedforwardNorm: RMSNorm
    @ModuleInfo(key: "post_feedforward_layernorm") var postFeedforwardNorm: RMSNorm

    init(_ config: EG2VisionConfiguration) {
        _attention.wrappedValue = EG2VisionAttention(config)
        _mlp.wrappedValue = EG2VisionMLP(config)
        _inputNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        _postAttentionNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        _preFeedforwardNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        _postFeedforwardNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, positions: MLXArray, mask: MLXArray) -> MLXArray {
        let h = x + postAttentionNorm(attention(inputNorm(x), positions: positions, mask: mask))
        return h + postFeedforwardNorm(mlp(preFeedforwardNorm(h)))
    }
}

final class EG2VisionPatchEmbedder: Module {
    let positionEmbeddingSize: Int

    @ModuleInfo(key: "input_proj") var inputProjection: Linear
    @ParameterInfo(key: "position_embedding_table") var positionTable: MLXArray

    init(_ config: EG2VisionConfiguration) {
        positionEmbeddingSize = config.positionEmbeddingSize
        _inputProjection.wrappedValue = Linear(3 * config.patchSize * config.patchSize, config.hiddenSize, bias: false)
        _positionTable.wrappedValue = MLXArray.ones([2, config.positionEmbeddingSize, config.hiddenSize])
        super.init()
    }

    /// `pixels`: (batch, patches, patchDim) in 0...1; `positions`: (batch, patches, 2).
    func callAsFunction(_ pixels: MLXArray, positions: MLXArray, padding: MLXArray) -> MLXArray {
        let hidden = inputProjection((2 * (pixels - 0.5)).asType(inputProjection.weight.dtype))
        // Gather each axis's embedding; padded positions (-1) are zeroed below.
        let clamped = maximum(positions, 0).asType(.int32)
        let x = take(positionTable[0], clamped[0..., 0..., 0].flattened(), axis: 0)
        let y = take(positionTable[1], clamped[0..., 0..., 1].flattened(), axis: 0)
        let embeddings = (x + y).reshaped(hidden.shape).asType(hidden.dtype)
        return hidden + which(padding.expandedDimensions(axis: -1), MLXArray(0, dtype: hidden.dtype), embeddings)
    }
}

final class EG2VisionEncoder: Module {
    @ModuleInfo var layers: [EG2VisionBlock]

    init(_ config: EG2VisionConfiguration) {
        _layers.wrappedValue = (0..<config.hiddenLayers).map { _ in EG2VisionBlock(config) }
        super.init()
    }
}

final class EG2VisionModel: Module {
    let config: EG2VisionConfiguration

    @ModuleInfo(key: "patch_embedder") var patchEmbedder: EG2VisionPatchEmbedder
    @ModuleInfo var encoder: EG2VisionEncoder
    @ParameterInfo(key: "std_bias") var standardizationBias: MLXArray?
    @ParameterInfo(key: "std_scale") var standardizationScale: MLXArray?

    init(_ config: EG2VisionConfiguration) {
        self.config = config
        _patchEmbedder.wrappedValue = EG2VisionPatchEmbedder(config)
        _encoder.wrappedValue = EG2VisionEncoder(config)
        if config.standardize {
            _standardizationBias.wrappedValue = MLXArray.zeros([config.hiddenSize])
            _standardizationScale.wrappedValue = MLXArray.ones([config.hiddenSize])
        }
        super.init()
    }

    /// `pixels`: (images, patches, patchDim) or (batch, frames, patches, patchDim);
    /// `positions`: matching (…, patches, 2) with -1 for padding.
    /// Returns the valid pooled tokens of every image, concatenated: (tokens, hidden).
    func callAsFunction(_ pixelValues: MLXArray, positions positionValues: MLXArray) -> MLXArray {
        var pixels = pixelValues
        var positions = positionValues
        if pixels.ndim == 2 { pixels = pixels.expandedDimensions(axis: 0) }
        if positions.ndim == 2 { positions = positions.expandedDimensions(axis: 0) }
        if pixels.ndim == 4 {
            pixels = pixels.reshaped(-1, pixels.dim(2), pixels.dim(3))
            positions = positions.reshaped(-1, positions.dim(2), 2)
        }
        let poolSquare = config.poolingKernelSize * config.poolingKernelSize
        let outputLength = pixels.dim(1) / poolSquare
        let padding = all(positions .== -1, axis: -1)

        let inputs = patchEmbedder(pixels, positions: positions, padding: padding)
        let valid = logicalNot(padding)
        let pairs = logicalAnd(valid.expandedDimensions(axis: 1), valid.expandedDimensions(axis: 2))
        let mask = which(pairs, MLXArray(0, dtype: inputs.dtype), MLXArray(-1e4, dtype: inputs.dtype))
            .expandedDimensions(axis: 1)

        var hidden = inputs
        for layer in encoder.layers { hidden = layer(hidden, positions: positions, mask: mask) }

        let (pooled, validPooled) = pool(hidden, positions: positions, padding: padding, length: outputLength)
        var pieces: [MLXArray] = []
        for item in 0..<pooled.dim(0) {
            let count = Int(validPooled[item].asType(.int32).sum().item(Int32.self))
            pieces.append(pooled[item, ..<count])
        }
        var result = concatenated(pieces, axis: 0)
        if let standardizationBias, let standardizationScale {
            result = (result - standardizationBias) * standardizationScale
        }
        return result
    }

    /// Average-pools k×k patch neighbourhoods by position; returns pooled states and which
    /// pooled slots received any real patch.
    private func pool(_ states: MLXArray, positions: MLXArray, padding: MLXArray, length: Int) -> (MLXArray, MLXArray) {
        let root = MLXArray(Float(config.hiddenSize).squareRoot())
        let hidden = which(padding.expandedDimensions(axis: -1), MLXArray(0, dtype: states.dtype), states)
        if hidden.dim(1) == length {
            return ((hidden * root).asType(states.dtype), logicalNot(padding))
        }
        let kernel = Int(Double(hidden.dim(1) / length).squareRoot())
        let clamped = maximum(positions, 0)
        let maxX = clamped[0..., 0..., 0].max(axis: -1, keepDims: true) + 1
        let kernelXY = floor(clamped.asType(.float32) / Float(kernel)).asType(.int32)
        let index = kernelXY[0..., 0..., 0] + (maxX / Int32(kernel)) * kernelXY[0..., 0..., 1]
        let oneHot =
            (index.expandedDimensions(axis: -1) .== MLXArray(0..<Int32(length))).asType(.float32)
            / Float(kernel * kernel)
        let output = einsum("bLl,bLd->bld", oneHot, hidden).asType(hidden.dtype)
        let filled = logicalNot(all(oneHot .== 0, axis: 1))
        return ((output * root).asType(hidden.dtype), filled)
    }
}

/// Projects tower outputs into the text model's input space.
final class EG2MultimodalEmbedder: Module, UnaryLayer {
    @ModuleInfo(key: "embedding_projection") var projection: Linear
    let norm: EG2RMSNormNoScale

    init(inputDimension: Int, outputDimension: Int, eps: Float) {
        _projection.wrappedValue = Linear(inputDimension, outputDimension, bias: false)
        norm = EG2RMSNormNoScale(eps: eps)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        projection(norm(x))
    }
}
