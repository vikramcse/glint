import Foundation
import UniformTypeIdentifiers

/// Encodes inputs into one shared vector space. Adding a model means adding one conformance.
public protocol EmbeddingProvider: Sendable {
    /// Id, version, dimensions, modalities and license of the model.
    var descriptor: ModelDescriptor { get }
    /// Encodes a batch. The result has one embedding per input, in order, all in `descriptor.space`.
    func embed(_ batch: [EmbeddingInput], purpose: EmbeddingPurpose) async throws -> [Embedding]
}

/// Turns a file into chunks. Adding a file type means adding one conformance.
public protocol ContentExtractor: Sendable {
    /// Content types this extractor handles (conformance is checked, so `.image` covers PNG and HEIC).
    static var contentTypes: Set<UTType> { get }
    /// Streams the chunks of `file`. Finishes with an error if the file cannot be read.
    func chunks(of file: FileRef) -> AsyncThrowingStream<Chunk, any Error>
}

extension ContentExtractor {
    public func canExtract(_ type: UTType) -> Bool {
        Self.contentTypes.contains { type.conforms(to: $0) }
    }
}

/// Nearest-neighbour index over chunk vectors.
public protocol VectorIndex: Sendable {
    func upsert(_ vectors: [StoredVector]) async throws
    func remove(fileID: FileID) async throws
    func search(_ query: Embedding, limit: Int, filter: SearchFilter) async throws -> [ScoredChunk]
}

/// Embeds an example file for "find similar" when the file is not in the index yet.
public protocol ExampleEncoder: Sendable {
    func embeddings(forFileAt url: URL) async throws -> [Embedding]
}

/// What the UI may ask of the indexer. Defined here so the UI never imports the indexer.
public protocol IndexingService: Sendable {
    func statusUpdates() async -> AsyncStream<IndexStatus>
    func currentStatus() async -> IndexStatus
    func sources() async throws -> [SourceInfo]
    @discardableResult
    func addSource(_ url: URL) async throws -> SourceInfo
    func removeSource(_ id: SourceID) async throws
    func setExclusions(_ rules: ExclusionRules) async throws
    func exclusions() async -> ExclusionRules
    func pause() async
    func resume() async
    /// Called after a license change so locked files get indexed (or paused) accordingly.
    func entitlementsDidChange() async
    /// Removes everything Glint derived from the user's files.
    func deleteIndex() async throws
}
