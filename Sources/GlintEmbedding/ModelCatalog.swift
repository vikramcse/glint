import Foundation
import GlintCore

/// Every model the app knows about. Only models with a license that allows commercial
/// distribution are listed; spaces never mix because each descriptor tags its vectors.
public enum ModelCatalog {
    /// Interim provider built only from frameworks that ship with macOS (see ADR 0002).
    public static let appleOnDevice = ModelDescriptor(
        id: "apple.on-device-descriptors",
        version: "1",
        displayName: "Built-in (basic)",
        dimensions: 512,
        supportedDimensions: [512],
        modalities: [.text, .image, .audio, .video],
        license: "macOS system frameworks",
        allowsCommercialUse: true
    )

    /// EmbeddingGemma 2, the 1.0 default once the M0 MLX-Swift port passes the parity gate
    /// (cosine ≥ 0.999 against the Python reference). Weights download from our CDN.
    public static let embeddingGemma2 = ModelDescriptor(
        id: "google.embeddinggemma-2",
        version: "2.0",
        displayName: "EmbeddingGemma 2",
        dimensions: 512,
        supportedDimensions: [768, 512, 256, 128],
        modalities: [.text, .image, .audio, .video],
        license: "Apache-2.0",
        allowsCommercialUse: true,
        minimumSimilarity: 0.60
    )

    /// Deterministic text-only hashing model for tests and the eval harness's smoke mode.
    public static let hashing = ModelDescriptor(
        id: "glint.hashing",
        version: "1",
        displayName: "Hashing (tests)",
        dimensions: 256,
        supportedDimensions: [256],
        modalities: [.text],
        license: "Proprietary",
        allowsCommercialUse: true
    )

    /// Models shown in Settings > Models, with whether they can run on this build.
    public static let all: [(descriptor: ModelDescriptor, isAvailable: Bool)] = [
        (embeddingGemma2, true),
        (appleOnDevice, true),
    ]
}
