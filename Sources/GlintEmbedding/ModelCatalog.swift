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
        // 3.0 once camera photos stopped carrying their OCR noise: COCO negative queries 5.3 -> 3.0
        // results and precision +3 points for 1.4 points of recall; themed trains and SciFact
        // keep their recall within 0.4 points with better precision.
        minimumZScore: 3.0,
        // Keeps a folder of train photos for "train" (best z 2.4 against the mean, 4.1 against
        // the median). COCO: Recall@10 0.770 -> 0.779 and F1 unchanged; 3.25 costs 0.02 precision.
        minimumRobustZScore: 3.5,
        // A library that is mostly one trip's train photos hides every match for "two people near
        // a train" from calibration. Themed COCO benchmark (coco_theme_bench.py): Recall@10
        // 0.24 -> 0.54 at 0.72. 0.68 keeps a real trip library's sunglasses photos (best 0.701,
        // z 2.7) and all three backpack videos (0.736, 0.706, 0.695) that 0.72 dropped:
        // coco-train Recall@10 0.637 -> 0.784 for precision 0.47 -> 0.38; media photos 0.863 ->
        // 0.883 and videos 0.838 -> 0.850 for video precision 0.29 -> 0.26; sample, mixed,
        // SciFact and COCO within a point, negative queries unchanged. Audio keeps 0.72
        // (`HybridRanker.confidentSimilarityByKind`). 0.66 costs mixed F1 a point.
        confidentSimilarity: 0.68,
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
