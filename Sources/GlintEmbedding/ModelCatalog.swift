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
        minimumSimilarity: 0.60,
        // Tuned with glint-eval. The margin (0.04–0.06 keeps sample recall at 1.0 while precision
        // rises from 0.46 to 0.94) applies to small libraries; from 200 vectors the z-score takes
        // over (COCO photo benchmark: category F1 0.55 -> 0.59, negative queries 35 -> 3.4 results).
        similarityMargin: 0.05,
        minimumZScore: 2.75,
        // Keeps a folder of train photos for "train" (best z 2.4 against the mean, 4.1 against
        // the median). COCO: Recall@10 0.770 -> 0.779 and F1 unchanged; 3.25 costs 0.02 precision.
        minimumRobustZScore: 3.5,
        // A library that is mostly one trip's train photos hides every match for "two people near
        // a train" from calibration. Themed COCO benchmark (coco_theme_bench.py): Recall@10
        // 0.24 -> 0.54; COCO and SciFact unchanged, negative queries unchanged. 0.70 costs
        // SciFact 0.4 points of recall; 0.75 keeps only half the themed gain.
        confidentSimilarity: 0.72,
        limitsLooseKeywords: true
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
