import Foundation
import MLX
import MLXNN

// Gemma 4 conformer audio encoder, ported from mlx-vlm `models/gemma4/audio.py` (MIT):
// subsampling convolutions, 12 macaron conformer blocks with chunked local attention and
// relative positions, and an output projection.

struct EG2AudioConfiguration: Decodable, Sendable {
    var hiddenSize: Int
    var numHiddenLayers: Int
    var numAttentionHeads: Int
    var subsamplingConvChannels: [Int]
    var convKernelSize: Int
    var residualWeight: Float
    var attentionChunkSize: Int
    var attentionContextLeft: Int
    var attentionContextRight: Int
    var attentionLogitCap: Float
    var attentionInvalidLogitsValue: Float
    var useClippedLinears: Bool
    var rmsNormEps: Float
    var gradientClipping: Float
    var outputProjDims: Int?

    enum CodingKeys: String, CodingKey {
        case hiddenSize = "hidden_size"
        case numHiddenLayers = "num_hidden_layers"
        case numAttentionHeads = "num_attention_heads"
        case subsamplingConvChannels = "subsampling_conv_channels"
        case convKernelSize = "conv_kernel_size"
        case residualWeight = "residual_weight"
        case attentionChunkSize = "attention_chunk_size"
        case attentionContextLeft = "attention_context_left"
        case attentionContextRight = "attention_context_right"
        case attentionLogitCap = "attention_logit_cap"
        case attentionInvalidLogitsValue = "attention_invalid_logits_value"
        case useClippedLinears = "use_clipped_linears"
        case rmsNormEps = "rms_norm_eps"
        case gradientClipping = "gradient_clipping"
        case outputProjDims = "output_proj_dims"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hiddenSize = try c.decodeIfPresent(Int.self, forKey: .hiddenSize) ?? 1_024
        numHiddenLayers = try c.decodeIfPresent(Int.self, forKey: .numHiddenLayers) ?? 12
        numAttentionHeads = try c.decodeIfPresent(Int.self, forKey: .numAttentionHeads) ?? 8
        subsamplingConvChannels = try c.decodeIfPresent([Int].self, forKey: .subsamplingConvChannels) ?? [128, 32]
        convKernelSize = try c.decodeIfPresent(Int.self, forKey: .convKernelSize) ?? 5
        residualWeight = try c.decodeIfPresent(Float.self, forKey: .residualWeight) ?? 0.5
        attentionChunkSize = try c.decodeIfPresent(Int.self, forKey: .attentionChunkSize) ?? 12
        attentionContextLeft = try c.decodeIfPresent(Int.self, forKey: .attentionContextLeft) ?? 13
        attentionContextRight = try c.decodeIfPresent(Int.self, forKey: .attentionContextRight) ?? 0
        attentionLogitCap = try c.decodeIfPresent(Float.self, forKey: .attentionLogitCap) ?? 50
        attentionInvalidLogitsValue = try c.decodeIfPresent(Float.self, forKey: .attentionInvalidLogitsValue) ?? -1e9
        useClippedLinears = try c.decodeIfPresent(Bool.self, forKey: .useClippedLinears) ?? true
        rmsNormEps = try c.decodeIfPresent(Float.self, forKey: .rmsNormEps) ?? 1e-6
        gradientClipping = try c.decodeIfPresent(Float.self, forKey: .gradientClipping) ?? 1e10
        outputProjDims = try c.decodeIfPresent(Int.self, forKey: .outputProjDims)
    }
}

// MARK: Subsampling

final class EG2SSCPConvBlock: Module {
    @ModuleInfo var conv: Conv2d
    @ModuleInfo var norm: LayerNorm

    init(_ config: EG2AudioConfiguration, index: Int) {
        let input = index == 0 ? 1 : config.subsamplingConvChannels[index - 1]
        let output = config.subsamplingConvChannels[index]
        _conv.wrappedValue = Conv2d(
            inputChannels: input, outputChannels: output, kernelSize: [3, 3], stride: [2, 2], padding: 0, bias: false)
        _norm.wrappedValue = LayerNorm(dimensions: output, eps: config.rmsNormEps, affine: true, bias: false)
        super.init()
    }

    /// `x`: (batch, time, freq, channels); `mask`: (batch, time), true = padding.
    func callAsFunction(_ x: MLXArray, mask: MLXArray) -> (MLXArray, MLXArray) {
        var h = which(mask[0..., 0..., .newAxis, .newAxis], MLXArray(0, dtype: x.dtype), x)
        h = padded(h, widths: [0, [1, 1], [1, 1], 0])
        h = conv(h)
        let outputLength = h.dim(1)
        let outputMask = mask[0..., .stride(by: 2)][0..., ..<outputLength]
        return (relu(norm(h)), outputMask)
    }
}

final class EG2SubSampleConvProjection: Module {
    @ModuleInfo var layer0: EG2SSCPConvBlock
    @ModuleInfo var layer1: EG2SSCPConvBlock
    @ModuleInfo(key: "input_proj_linear") var inputProjection: Linear

    init(_ config: EG2AudioConfiguration) {
        _layer0.wrappedValue = EG2SSCPConvBlock(config, index: 0)
        _layer1.wrappedValue = EG2SSCPConvBlock(config, index: 1)
        var frequencies = 128
        for _ in 0..<2 { frequencies = (frequencies + 2 - 3) / 2 + 1 }
        _inputProjection.wrappedValue = Linear(
            frequencies * config.subsamplingConvChannels.last.unsafelyUnwrapped, config.hiddenSize, bias: false)
        super.init()
    }

    func callAsFunction(_ mel: MLXArray, mask: MLXArray) -> (MLXArray, MLXArray) {
        var (h, m) = layer0(mel.expandedDimensions(axis: -1), mask: mask)
        (h, m) = layer1(h, mask: m)
        return (inputProjection(h.reshaped(h.dim(0), h.dim(1), -1)), m)
    }
}

// MARK: Conformer

final class EG2ConformerFeedForward: Module {
    let clipping: Float
    let residualWeight: Float
    @ModuleInfo(key: "pre_layer_norm") var preNorm: RMSNorm
    @ModuleInfo(key: "ffw_layer_1") var layer1: EG2ClippableLinear
    @ModuleInfo(key: "ffw_layer_2") var layer2: EG2ClippableLinear
    @ModuleInfo(key: "post_layer_norm") var postNorm: RMSNorm

    init(_ config: EG2AudioConfiguration) {
        clipping = config.gradientClipping
        residualWeight = config.residualWeight
        _preNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: 1e-6)
        _layer1.wrappedValue = EG2ClippableLinear(config.hiddenSize, config.hiddenSize * 4, clipping: config.useClippedLinears)
        _layer2.wrappedValue = EG2ClippableLinear(config.hiddenSize * 4, config.hiddenSize, clipping: config.useClippedLinears)
        _postNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: 1e-6)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = preNorm(clip(x, min: -clipping, max: clipping))
        h = layer2(silu(layer1(h)))
        h = postNorm(clip(h, min: -clipping, max: clipping))
        return x + h * residualWeight
    }
}

final class EG2AudioAttention: Module {
    let heads: Int
    let headDim: Int
    let chunk: Int
    let pastHorizon: Int
    let futureHorizon: Int
    let context: Int
    let invalidLogit: Float
    let softcap: Float
    let qScale: Float
    let kScale: Float
    let inverseTimescales: MLXArray

    @ModuleInfo(key: "relative_k_proj") var relativeKProj: Linear
    @ParameterInfo(key: "per_dim_scale") var perDimScale: MLXArray
    @ModuleInfo(key: "q_proj") var qProj: EG2ClippableLinear
    @ModuleInfo(key: "k_proj") var kProj: EG2ClippableLinear
    @ModuleInfo(key: "v_proj") var vProj: EG2ClippableLinear
    @ModuleInfo var post: EG2ClippableLinear

    init(_ config: EG2AudioConfiguration) {
        heads = config.numAttentionHeads
        headDim = config.hiddenSize / heads
        chunk = config.attentionChunkSize
        futureHorizon = config.attentionContextRight
        pastHorizon = max(0, config.attentionContextLeft - 1)
        context = chunk + pastHorizon + futureHorizon
        invalidLogit = config.attentionInvalidLogitsValue
        softcap = config.attentionLogitCap
        qScale = pow(Float(headDim), -0.5) / log(2)
        kScale = log(1 + Float(M_E)) / log(2)
        let timescales = config.hiddenSize / 2
        let increment = log(Float(10_000)) / Float(max(timescales - 1, 1))
        inverseTimescales = exp(MLXArray(0..<timescales).asType(.float32) * -increment).reshaped(1, 1, timescales)
        let clip = config.useClippedLinears
        _relativeKProj.wrappedValue = Linear(config.hiddenSize, heads * headDim, bias: false)
        _perDimScale.wrappedValue = MLXArray.zeros([headDim])
        _qProj.wrappedValue = EG2ClippableLinear(config.hiddenSize, heads * headDim, clipping: clip)
        _kProj.wrappedValue = EG2ClippableLinear(config.hiddenSize, heads * headDim, clipping: clip)
        _vProj.wrappedValue = EG2ClippableLinear(config.hiddenSize, heads * headDim, clipping: clip)
        _post.wrappedValue = EG2ClippableLinear(config.hiddenSize, config.hiddenSize, clipping: clip)
        super.init()
    }

    /// [B, T, …] → [B, blocks, chunk, …], right-padding T to a multiple of the chunk.
    private func toBlocks(_ x: MLXArray) -> MLXArray {
        let length = x.dim(1)
        let blocks = (length + chunk - 1) / chunk
        var h = x
        if blocks * chunk > length { h = pad(dimension1: h, left: 0, right: blocks * chunk - length) }
        return h.reshaped([x.dim(0), blocks, chunk] + Array(x.shape.dropFirst(2)))
    }

    /// [B, T, …] → [B, blocks, context, …]: each block's past, own and future frames.
    private func blockContext(_ x: MLXArray) -> MLXArray {
        let h = pad(dimension1: x, left: pastHorizon, right: futureHorizon + chunk - 1)
        let blocks = (h.dim(1) - context) / chunk + 1
        let starts = MLXArray(0..<Int32(blocks)) * Int32(chunk)
        let indices = (starts.expandedDimensions(axis: 1) + MLXArray(0..<Int32(context)).expandedDimensions(axis: 0)).flattened()
        let gathered = take(h, indices, axis: 1)
        return gathered.reshaped([x.dim(0), blocks, context] + Array(x.shape.dropFirst(2)))
    }

    private func pad(dimension1 x: MLXArray, left: Int, right: Int) -> MLXArray {
        var widths = [IntOrPair](repeating: 0, count: x.ndim)
        widths[1] = [left, right]
        return padded(x, widths: widths)
    }

    /// Content and relative-position logits: (B, heads, blocks, chunk, context).
    private func relativeLogits(queries: MLXArray, keys: MLXArray) -> MLXArray {
        let (batch, blocks, width) = (queries.dim(0), queries.dim(1), queries.dim(2))
        let positions = MLXArray(stride(from: Int32(pastHorizon), through: Int32(-futureHorizon), by: -1)).expandedDimensions(axis: 0)
        let span = positions.dim(1)
        let scaled = positions.asType(.float32).expandedDimensions(axis: -1) * inverseTimescales
        var signal = concatenated([sin(scaled), cos(scaled)], axis: -1).asType(queries.dtype)
        signal = relativeKProj(signal.asType(relativeKProj.inputType)).reshaped(span, heads, headDim).asType(queries.dtype)

        let q = queries.transposed(0, 3, 1, 2, 4)  // B N U W H
        let k = keys.transposed(0, 3, 1, 4, 2)  // B N U H C
        let contentTerm = matmul(q, k)
        var positionTerm = matmul(q.reshaped(batch, heads, blocks * width, headDim), signal.transposed(1, 2, 0))
            .reshaped(batch, heads, blocks, width, span)
        // Relative shift.
        positionTerm = padded(positionTerm, widths: [0, 0, 0, 0, [0, (context + 1) - span]])
        positionTerm = positionTerm.reshaped(batch, heads, blocks, width * (context + 1))[.ellipsis, ..<(width * context)]
        positionTerm = positionTerm.reshaped(batch, heads, blocks, width, context)
        return contentTerm + positionTerm
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray, causalValid: MLXArray) -> MLXArray {
        let (batch, length) = (x.dim(0), x.dim(1))
        var q = qProj(x).asType(.float32).reshaped(batch, length, heads, headDim)
        var k = kProj(x).asType(.float32).reshaped(batch, length, heads, headDim)
        let v = vProj(x).asType(.float32).reshaped(batch, length, heads, headDim)
        q = q * (qScale * softplus(perDimScale))
        k = k * kScale

        let queryBlocks = toBlocks(q)
        let keyBlocks = blockContext(k)
        let valueBlocks = blockContext(v)
        let validContext = blockContext(logicalNot(mask))
        let condition = logicalAnd(
            validContext[0..., .newAxis, 0..., .newAxis, 0...], causalValid[.newAxis, .newAxis, .newAxis, 0..., 0...])

        var logits = relativeLogits(queries: queryBlocks, keys: keyBlocks)
        logits = tanh(logits / softcap) * softcap
        logits = which(condition, logits, MLXArray(invalidLogit))
        let probabilities = softmax(logits, axis: -1)
        let contextValues = einsum("bnuwc,bucnh->buwnh", probabilities, valueBlocks)
        let flat = contextValues.reshaped(batch, -1, heads, headDim)[0..., ..<length]
        return post(flat.reshaped(batch, length, heads * headDim).asType(x.dtype))
    }
}

final class EG2DepthwiseConv: Module {
    @ParameterInfo var weight: MLXArray

    init(channels: Int, kernel: Int) {
        _weight.wrappedValue = MLXArray.zeros([channels, kernel, 1])
        super.init()
    }
}

final class EG2LightConv1d: Module {
    let clipping: Float
    let causalPadding: Int
    @ModuleInfo(key: "pre_layer_norm") var preNorm: RMSNorm
    @ModuleInfo(key: "linear_start") var linearStart: EG2ClippableLinear
    @ModuleInfo(key: "depthwise_conv1d") var depthwise: EG2DepthwiseConv
    @ModuleInfo(key: "conv_norm") var convNorm: RMSNorm
    @ModuleInfo(key: "linear_end") var linearEnd: EG2ClippableLinear

    init(_ config: EG2AudioConfiguration) {
        clipping = config.gradientClipping
        causalPadding = config.convKernelSize - 1
        _preNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        _linearStart.wrappedValue = EG2ClippableLinear(config.hiddenSize, config.hiddenSize * 2, clipping: config.useClippedLinears)
        _depthwise.wrappedValue = EG2DepthwiseConv(channels: config.hiddenSize, kernel: config.convKernelSize)
        _convNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        _linearEnd.wrappedValue = EG2ClippableLinear(config.hiddenSize, config.hiddenSize, clipping: config.useClippedLinears)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let h = linearStart(preNorm(x))
        let parts = split(h, parts: 2, axis: -1)
        var gated = parts[0] * sigmoid(parts[1])
        gated = padded(gated, widths: [0, [causalPadding, 0], 0])
        var convolved = conv1d(gated, depthwise.weight, stride: 1, padding: 0, groups: gated.dim(-1))
        convolved = convNorm(clip(convolved, min: -clipping, max: clipping))
        return linearEnd(silu(convolved)) + x
    }
}

final class EG2ConformerBlock: Module {
    let clipping: Float
    @ModuleInfo(key: "feed_forward1") var feedForward1: EG2ConformerFeedForward
    @ModuleInfo(key: "self_attn") var attention: EG2AudioAttention
    @ModuleInfo var lconv1d: EG2LightConv1d
    @ModuleInfo(key: "feed_forward2") var feedForward2: EG2ConformerFeedForward
    @ModuleInfo(key: "norm_pre_attn") var normPreAttention: RMSNorm
    @ModuleInfo(key: "norm_post_attn") var normPostAttention: RMSNorm
    @ModuleInfo(key: "norm_out") var normOut: RMSNorm

    init(_ config: EG2AudioConfiguration) {
        clipping = config.gradientClipping
        _feedForward1.wrappedValue = EG2ConformerFeedForward(config)
        _attention.wrappedValue = EG2AudioAttention(config)
        _lconv1d.wrappedValue = EG2LightConv1d(config)
        _feedForward2.wrappedValue = EG2ConformerFeedForward(config)
        _normPreAttention.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: 1e-6)
        _normPostAttention.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: 1e-6)
        _normOut.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: 1e-6)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray, causalValid: MLXArray) -> MLXArray {
        var h = feedForward1(x)
        let residual = h
        var attended = attention(normPreAttention(clip(h, min: -clipping, max: clipping)), mask: mask, causalValid: causalValid)
        attended = clip(attended, min: -clipping, max: clipping)
        h = residual + normPostAttention(attended)
        h = h * logicalNot(mask).expandedDimensions(axis: -1).asType(h.dtype)
        h = feedForward2(lconv1d(h))
        return normOut(clip(h, min: -clipping, max: clipping))
    }
}

final class EG2AudioEncoder: Module {
    let config: EG2AudioConfiguration

    @ModuleInfo(key: "subsample_conv_projection") var subsample: EG2SubSampleConvProjection
    @ModuleInfo var layers: [EG2ConformerBlock]
    @ModuleInfo(key: "output_proj") var outputProjection: Linear?

    init(_ config: EG2AudioConfiguration) {
        self.config = config
        _subsample.wrappedValue = EG2SubSampleConvProjection(config)
        _layers.wrappedValue = (0..<config.numHiddenLayers).map { _ in EG2ConformerBlock(config) }
        _outputProjection.wrappedValue = config.outputProjDims.map { Linear(config.hiddenSize, $0, bias: true) }
        super.init()
    }

    /// Local causal + validity mask for chunked attention: (chunk, context).
    private var causalValidMask: MLXArray {
        let chunk = config.attentionChunkSize
        let future = config.attentionContextRight
        let past = max(0, config.attentionContextLeft - 1)
        let context = chunk + past + future
        let query = MLXArray(0..<Int32(chunk)).expandedDimensions(axis: 1)
        let key = MLXArray(0..<Int32(context)).expandedDimensions(axis: 0)
        let distance = query + Int32(past) - key
        let pastValid = logicalAnd(distance .>= 0, distance .< Int32(past))
        let futureValid = logicalAnd(distance .< 0, -distance .< Int32(future))
        return logicalOr(pastValid, futureValid)
    }

    /// `mel`: (batch, frames, 128); `invalid`: (batch, frames), true = padding.
    /// Returns encodings with padded frames zeroed, and the subsampled invalid mask.
    func callAsFunction(_ mel: MLXArray, invalid: MLXArray) -> (MLXArray, MLXArray) {
        var (h, mask) = subsample(mel, mask: invalid)
        let causal = causalValidMask
        for layer in layers { h = layer(h, mask: mask, causalValid: causal) }
        if let outputProjection { h = outputProjection(h) }
        if mask.dim(1) != h.dim(1) { mask = mask[0..., ..<h.dim(1)] }
        return (which(mask.expandedDimensions(axis: -1), MLXArray(0, dtype: h.dtype), h), mask)
    }
}
