import Foundation
import MLX
import MLXNN

// Swift port of mlx-vlm `models/embedding_gemma2/language.py` (MIT): a bidirectional Gemma 4
// encoder with alternating sliding/full attention, projection-only per-layer inputs and a
// final projection into the 768-d shared space.

/// Keeps the reference's float32 angles and activation-dtype cos/sin rounding.
final class EG2RotaryEmbedding {
    let frequencies: MLXArray

    init(dimensions: Int, base: Float) {
        let exponents = MLXArray(stride(from: 0, to: dimensions, by: 2).map { Float($0) / Float(dimensions) })
        frequencies = 1.0 / pow(MLXArray(base), exponents)
    }

    /// `x`: (batch, heads, length, headDim); `positions`: (batch, length).
    func callAsFunction(_ x: MLXArray, positions: MLXArray) -> MLXArray {
        var angles = positions.asType(.float32).expandedDimensions(axis: -1) * frequencies
        angles = concatenated([angles, angles], axis: -1).expandedDimensions(axis: 1)
        let cosine = cos(angles).asType(x.dtype)
        let sine = sin(angles).asType(x.dtype)
        let half = x.dim(-1) / 2
        let rotated = concatenated([-x[.ellipsis, half...], x[.ellipsis, ..<half]], axis: -1)
        return x * cosine + rotated * sine
    }
}

/// RMS normalization without a learned scale.
final class EG2RMSNormNoScale: Module, UnaryLayer {
    let eps: Float

    init(eps: Float) {
        self.eps = eps
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLXFast.rmsNorm(x, weight: MLXArray.mlxNone, eps: eps)
    }
}

final class EG2TextAttention: Module {
    let heads: Int
    let kvHeads: Int
    let headDim: Int
    let rope: EG2RotaryEmbedding

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm
    let vNorm: EG2RMSNormNoScale

    init(_ config: EG2TextConfiguration, layer: Int) {
        let override = config.override(for: layer)
        headDim = override?.headDim ?? config.headDim
        heads = override?.numAttentionHeads ?? config.numAttentionHeads
        kvHeads = override?.numKeyValueHeads ?? config.numKeyValueHeads
        _qProj.wrappedValue = Linear(config.hiddenSize, heads * headDim, bias: false)
        _kProj.wrappedValue = Linear(config.hiddenSize, kvHeads * headDim, bias: false)
        _vProj.wrappedValue = Linear(config.hiddenSize, kvHeads * headDim, bias: false)
        _oProj.wrappedValue = Linear(heads * headDim, config.hiddenSize, bias: false)
        _qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.rmsNormEps)
        _kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.rmsNormEps)
        vNorm = EG2RMSNormNoScale(eps: config.rmsNormEps)
        let theta = config.ropeParameters[config.layerTypes[layer]]?.ropeTheta ?? 10_000
        rope = EG2RotaryEmbedding(dimensions: headDim, base: theta)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray, positions: MLXArray) -> MLXArray {
        let (batch, length) = (x.dim(0), x.dim(1))
        let q = qNorm(qProj(x).reshaped(batch, length, heads, -1))
        let k = kNorm(kProj(x).reshaped(batch, length, kvHeads, -1))
        let v = vNorm(vProj(x).reshaped(batch, length, kvHeads, -1))
        let queries = rope(q.transposed(0, 2, 1, 3), positions: positions)
        let keys = rope(k.transposed(0, 2, 1, 3), positions: positions)
        let values = v.transposed(0, 2, 1, 3)
        let output = MLXFast.scaledDotProductAttention(
            queries: queries, keys: keys, values: values, scale: 1.0, mask: .array(mask))
        return oProj(output.transposed(0, 2, 1, 3).reshaped(batch, length, -1))
    }
}

final class EG2TextMLP: Module, UnaryLayer {
    @ModuleInfo(key: "gate_proj") var gateProj: Linear
    @ModuleInfo(key: "up_proj") var upProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear

    init(_ config: EG2TextConfiguration) {
        _gateProj.wrappedValue = Linear(config.hiddenSize, config.intermediateSize, bias: false)
        _upProj.wrappedValue = Linear(config.hiddenSize, config.intermediateSize, bias: false)
        _downProj.wrappedValue = Linear(config.intermediateSize, config.hiddenSize, bias: false)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProj(geluApproximate(gateProj(x)) * upProj(x))
    }
}

final class EG2PerLayerInputs: Module {
    let layers: Int
    let width: Int
    let scale: Float

    @ModuleInfo(key: "per_layer_model_projection") var projection: Linear
    @ModuleInfo(key: "per_layer_projection_norm") var norm: RMSNorm

    init(_ config: EG2TextConfiguration) {
        layers = config.numHiddenLayers
        width = config.hiddenSizePerLayerInput
        scale = pow(Float(config.hiddenSize), -0.5)
        _projection.wrappedValue = Linear(config.hiddenSize, layers * width, bias: false)
        _norm.wrappedValue = RMSNorm(dimensions: width, eps: config.rmsNormEps)
        super.init()
    }

    /// (batch, length, hidden) → (batch, length, layers, width).
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let projected = projection(x) * scale
        return norm(projected.reshaped(x.dim(0), x.dim(1), layers, width))
    }
}

final class EG2PerLayerBlock: Module {
    @ModuleInfo(key: "per_layer_input_gate") var gate: Linear
    @ModuleInfo(key: "per_layer_projection") var projection: Linear
    @ModuleInfo(key: "post_per_layer_input_norm") var norm: RMSNorm

    init(_ config: EG2TextConfiguration) {
        _gate.wrappedValue = Linear(config.hiddenSize, config.hiddenSizePerLayerInput, bias: false)
        _projection.wrappedValue = Linear(config.hiddenSizePerLayerInput, config.hiddenSize, bias: false)
        _norm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, perLayerInput: MLXArray) -> MLXArray {
        x + norm(projection(geluApproximate(gate(x)) * perLayerInput))
    }
}

final class EG2EncoderLayer: Module {
    @ModuleInfo(key: "self_attn") var attention: EG2TextAttention
    @ModuleInfo var mlp: EG2TextMLP
    @ModuleInfo(key: "input_layernorm") var inputNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionNorm: RMSNorm
    @ModuleInfo(key: "pre_feedforward_layernorm") var preFeedforwardNorm: RMSNorm
    @ModuleInfo(key: "post_feedforward_layernorm") var postFeedforwardNorm: RMSNorm
    @ModuleInfo(key: "ple_block") var perLayerBlock: EG2PerLayerBlock?
    @ParameterInfo(key: "layer_scalar") var layerScalar: MLXArray

    init(_ config: EG2TextConfiguration, layer: Int) {
        _attention.wrappedValue = EG2TextAttention(config, layer: layer)
        _mlp.wrappedValue = EG2TextMLP(config)
        _inputNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        _postAttentionNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        _preFeedforwardNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        _postFeedforwardNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        _perLayerBlock.wrappedValue = config.hiddenSizePerLayerInput > 0 ? EG2PerLayerBlock(config) : nil
        _layerScalar.wrappedValue = MLXArray.ones([1])
        super.init()
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray, positions: MLXArray, perLayerInput: MLXArray?) -> MLXArray {
        var h = x + postAttentionNorm(attention(inputNorm(x), mask: mask, positions: positions))
        h = h + postFeedforwardNorm(mlp(preFeedforwardNorm(h)))
        if let perLayerBlock, let perLayerInput {
            h = perLayerBlock(h, perLayerInput: perLayerInput)
        }
        return h * layerScalar
    }
}

final class EG2TextModel: Module {
    let config: EG2TextConfiguration

    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo var ple: EG2PerLayerInputs?
    @ModuleInfo var layers: [EG2EncoderLayer]
    @ModuleInfo var norm: RMSNorm
    @ModuleInfo(key: "embedding_projection") var embeddingProjection: Linear

    init(_ config: EG2TextConfiguration) {
        self.config = config
        _embedTokens.wrappedValue = Embedding(embeddingCount: config.vocabSize, dimensions: config.hiddenSize)
        _ple.wrappedValue = config.hiddenSizePerLayerInput > 0 ? EG2PerLayerInputs(config) : nil
        _layers.wrappedValue = (0..<config.numHiddenLayers).map { EG2EncoderLayer(config, layer: $0) }
        _norm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        _embeddingProjection.wrappedValue = Linear(config.hiddenSize, config.embeddingDim, bias: false)
        super.init()
    }

    /// Scaled token embeddings (Gemma multiplies by √hidden).
    func embed(_ ids: MLXArray) -> MLXArray {
        let embeddings = embedTokens(ids)
        return embeddings * MLXArray(Float(config.hiddenSize).squareRoot()).asType(embeddings.dtype)
    }

    /// `inputs`: (batch, length, hidden) embeddings; `attentionMask`: (batch, length) of 0/1.
    /// Returns projected token states (batch, length, embeddingDim).
    func callAsFunction(_ inputs: MLXArray, attentionMask: MLXArray) -> MLXArray {
        let length = inputs.dim(1)
        let fullMask = attentionMask.asType(.bool).reshaped(attentionMask.dim(0), 1, 1, length)
        let positions = MLXArray(0..<Int32(length))
        let distance = abs(positions.expandedDimensions(axis: 1) - positions.expandedDimensions(axis: 0))
        let slidingMask = logicalAnd(fullMask, distance .<= Int32(config.slidingWindow))
        let positionIDs = broadcast(positions.expandedDimensions(axis: 0), to: [inputs.dim(0), length])

        let perLayerInputs = ple?(inputs)
        var h = inputs
        for (index, layer) in layers.enumerated() {
            let mask = config.layerTypes[index] == "sliding_attention" ? slidingMask : fullMask
            h = layer(h, mask: mask, positions: positionIDs, perLayerInput: perLayerInputs?[0..., 0..., index])
        }
        return embeddingProjection(norm(h))
    }
}
