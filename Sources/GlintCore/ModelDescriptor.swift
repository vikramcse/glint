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
        checksum: String? = nil
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
    }

    /// The vector space stored vectors are tagged with. Includes the version so a new model
    /// build never mixes with vectors from an older one.
    public var space: VectorSpace {
        VectorSpace(modelID: "\(id)/\(version)", dimension: dimensions)
    }
}
