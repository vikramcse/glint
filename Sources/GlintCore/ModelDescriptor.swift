import Foundation

/// Everything the app needs to know about an embedding model before loading it.
public struct ModelDescriptor: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var version: String
    public var displayName: String
    /// Output dimension this build of the model produces (after any Matryoshka truncation).
    public var dimensions: Int
    /// Dimensions the model supports via Matryoshka truncation, largest first.
    public var supportedDimensions: [Int]
    public var modalities: Set<Modality>
    /// SPDX identifier or short license name.
    public var license: String
    /// Only models whose license allows commercial distribution may ship in the app.
    public var allowsCommercialUse: Bool
    /// Bytes to download before the model can run, or `nil` when it ships with the OS.
    public var downloadSize: Int64?
    /// SHA-256 of the weights archive, hex encoded.
    public var checksum: String?
    /// Cosine similarity below which a semantic match is noise for this model. Models differ:
    /// EmbeddingGemma 2 scores unrelated text around 0.5–0.65, the built-in model near 0.
    public var minimumSimilarity: Float?
    /// Semantic matches scoring more than this below a query's best match are dropped. Scores
    /// from one model bunch together (EmbeddingGemma 2 puts unrelated photos within ~0.1 of a
    /// real match), so the gap from the best match separates matches better than any fixed
    /// cutoff. `nil` keeps everything above `minimumSimilarity`.
    public var similarityMargin: Float?
    /// Semantic matches fewer than this many standard deviations above the query's mean score
    /// over the library are dropped. Adapts to each query, so it separates real matches from
    /// the model's crowded background better than a fixed cutoff or margin; used instead of
    /// `similarityMargin` once the library is large enough for stable statistics.
    public var minimumZScore: Float?
    /// Semantic matches at least this many robust deviations (median absolute deviation) above
    /// the query's median score are kept even below `minimumZScore`. When many files match, they
    /// lift the mean and standard deviation until none of them stands out; the median doesn't move.
    public var minimumRobustZScore: Float?
    /// Semantic matches at or above this cosine similarity, and within `similarityMargin` of the
    /// query's best match, are kept even when calibration would drop them. A library that is
    /// mostly one trip's train photos makes every train photo the "background", so "two people
    /// near a train" stands out from nothing; a high absolute score still means a real match.
    public var confidentSimilarity: Float?
    /// Whether semantic matches are reliable enough that partial (any-word) keyword matches
    /// should only add a few files instead of boosting files already found. True for
    /// EmbeddingGemma 2 (SciFact MRR 0.61 -> 0.80); the built-in model needs the keyword boost
    /// (sample set: "revenue" lifts the Q3 summary above unrelated screenshots).
    public var limitsLooseKeywords: Bool

    public init(
        id: String,
        version: String,
        displayName: String,
        dimensions: Int,
        supportedDimensions: [Int],
        modalities: Set<Modality>,
        license: String,
        allowsCommercialUse: Bool,
        downloadSize: Int64? = nil,
        checksum: String? = nil,
        minimumSimilarity: Float? = nil,
        similarityMargin: Float? = nil,
        minimumZScore: Float? = nil,
        minimumRobustZScore: Float? = nil,
        confidentSimilarity: Float? = nil,
        limitsLooseKeywords: Bool = false
    ) {
        self.id = id
        self.version = version
        self.displayName = displayName
        self.dimensions = dimensions
        self.supportedDimensions = supportedDimensions
        self.modalities = modalities
        self.license = license
        self.allowsCommercialUse = allowsCommercialUse
        self.downloadSize = downloadSize
        self.checksum = checksum
        self.minimumSimilarity = minimumSimilarity
        self.similarityMargin = similarityMargin
        self.minimumZScore = minimumZScore
        self.minimumRobustZScore = minimumRobustZScore
        self.confidentSimilarity = confidentSimilarity
        self.limitsLooseKeywords = limitsLooseKeywords
    }

    /// The vector space stored vectors are tagged with. Includes the version so a new model
    /// build never mixes with vectors from an older one.
    public var space: VectorSpace {
        VectorSpace(modelID: "\(id)/\(version)", dimension: dimensions)
    }
}
