import Foundation

/// `config.json` of an EmbeddingGemma 2 checkpoint (MLX layout).
struct EG2Configuration: Decodable, Sendable {
    var textConfig: EG2TextConfiguration
    var visionConfig: EG2VisionConfiguration?
    var audioConfig: EG2AudioConfiguration?
    var imageTokenId: Int = 258_880
    var audioTokenId: Int = 258_881
    var videoTokenId: Int = 258_884
    var boiTokenId: Int = 255_999
    var eoiTokenId: Int = 258_882
    var boaTokenId: Int = 256_000
    var eoaTokenIndex: Int = 258_883
    var visionSoftTokensPerImage: Int = 280

    enum CodingKeys: String, CodingKey {
        case textConfig = "text_config"
        case visionConfig = "vision_config"
        case audioConfig = "audio_config"
        case imageTokenId = "image_token_id"
        case audioTokenId = "audio_token_id"
        case videoTokenId = "video_token_id"
        case boiTokenId = "boi_token_id"
        case eoiTokenId = "eoi_token_id"
        case boaTokenId = "boa_token_id"
        case eoaTokenIndex = "eoa_token_index"
        case visionSoftTokensPerImage = "vision_soft_tokens_per_image"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        textConfig = try container.decode(EG2TextConfiguration.self, forKey: .textConfig)
        visionConfig = try container.decodeIfPresent(EG2VisionConfiguration.self, forKey: .visionConfig)
        audioConfig = try container.decodeIfPresent(EG2AudioConfiguration.self, forKey: .audioConfig)
        imageTokenId = try container.decodeIfPresent(Int.self, forKey: .imageTokenId) ?? imageTokenId
        audioTokenId = try container.decodeIfPresent(Int.self, forKey: .audioTokenId) ?? audioTokenId
        videoTokenId = try container.decodeIfPresent(Int.self, forKey: .videoTokenId) ?? videoTokenId
        boiTokenId = try container.decodeIfPresent(Int.self, forKey: .boiTokenId) ?? boiTokenId
        eoiTokenId = try container.decodeIfPresent(Int.self, forKey: .eoiTokenId) ?? eoiTokenId
        boaTokenId = try container.decodeIfPresent(Int.self, forKey: .boaTokenId) ?? boaTokenId
        eoaTokenIndex = try container.decodeIfPresent(Int.self, forKey: .eoaTokenIndex) ?? eoaTokenIndex
        visionSoftTokensPerImage =
            try container.decodeIfPresent(Int.self, forKey: .visionSoftTokensPerImage)
            ?? visionSoftTokensPerImage
    }

    static func load(from directory: URL) throws -> EG2Configuration {
        try JSONDecoder().decode(EG2Configuration.self, from: Data(contentsOf: directory.appendingPathComponent("config.json")))
    }
}

struct EG2TextConfiguration: Decodable, Sendable {
    struct LayerOverride: Decodable, Sendable {
        var headDim: Int?
        var numKeyValueHeads: Int?
        var numAttentionHeads: Int?

        enum CodingKeys: String, CodingKey {
            case headDim = "head_dim"
            case numKeyValueHeads = "num_key_value_heads"
            case numAttentionHeads = "num_attention_heads"
        }
    }

    struct Rope: Decodable, Sendable {
        var ropeTheta: Float

        enum CodingKeys: String, CodingKey { case ropeTheta = "rope_theta" }
    }

    var vocabSize: Int
    var hiddenSize: Int
    var intermediateSize: Int
    var numHiddenLayers: Int
    var numAttentionHeads: Int
    var numKeyValueHeads: Int
    var headDim: Int
    var hiddenSizePerLayerInput: Int
    var embeddingDim: Int
    var rmsNormEps: Float
    var slidingWindow: Int
    var padTokenId: Int
    var layerTypes: [String]
    var perLayerConfig: [String: LayerOverride]
    var ropeParameters: [String: Rope]

    enum CodingKeys: String, CodingKey {
        case vocabSize = "vocab_size"
        case hiddenSize = "hidden_size"
        case intermediateSize = "intermediate_size"
        case numHiddenLayers = "num_hidden_layers"
        case numAttentionHeads = "num_attention_heads"
        case numKeyValueHeads = "num_key_value_heads"
        case headDim = "head_dim"
        case hiddenSizePerLayerInput = "hidden_size_per_layer_input"
        case embeddingDim = "embedding_dim"
        case rmsNormEps = "rms_norm_eps"
        case slidingWindow = "sliding_window"
        case padTokenId = "pad_token_id"
        case layerTypes = "layer_types"
        case perLayerConfig = "per_layer_config"
        case ropeParameters = "rope_parameters"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vocabSize = try container.decode(Int.self, forKey: .vocabSize)
        hiddenSize = try container.decode(Int.self, forKey: .hiddenSize)
        intermediateSize = try container.decode(Int.self, forKey: .intermediateSize)
        numHiddenLayers = try container.decode(Int.self, forKey: .numHiddenLayers)
        numAttentionHeads = try container.decode(Int.self, forKey: .numAttentionHeads)
        numKeyValueHeads = try container.decode(Int.self, forKey: .numKeyValueHeads)
        headDim = try container.decode(Int.self, forKey: .headDim)
        hiddenSizePerLayerInput = try container.decodeIfPresent(Int.self, forKey: .hiddenSizePerLayerInput) ?? 0
        embeddingDim = try container.decode(Int.self, forKey: .embeddingDim)
        rmsNormEps = try container.decodeIfPresent(Float.self, forKey: .rmsNormEps) ?? 1e-6
        slidingWindow = try container.decodeIfPresent(Int.self, forKey: .slidingWindow) ?? 512
        padTokenId = try container.decodeIfPresent(Int.self, forKey: .padTokenId) ?? 0
        var types =
            try container.decodeIfPresent([String].self, forKey: .layerTypes)
            ?? (0..<numHiddenLayers).map { ($0 + 1) % 6 == 0 ? "full_attention" : "sliding_attention" }
        if !types.isEmpty { types[types.count - 1] = "full_attention" }
        layerTypes = types
        let overrides = try container.decodeIfPresent([String: LayerOverride].self, forKey: .perLayerConfig) ?? [:]
        // Normalize keys to two digits, as the reference does.
        perLayerConfig = Dictionary(
            overrides.map { (key, value) in (String(format: "%02d", Int(key) ?? -1), value) }, uniquingKeysWith: { first, _ in first })
        ropeParameters =
            try container.decodeIfPresent([String: Rope].self, forKey: .ropeParameters) ?? [
                "full_attention": Rope(ropeTheta: 1_000_000), "sliding_attention": Rope(ropeTheta: 10_000),
            ]
    }

    func override(for layer: Int) -> LayerOverride? { perLayerConfig[String(format: "%02d", layer)] }
}
