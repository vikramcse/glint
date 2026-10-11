import CoreGraphics
import Foundation
import GlintCore
import GlintEmbedding
import GlintStore

/// What happened to one file.
public enum FileOutcome: Sendable, Hashable {
    case indexed(chunks: Int, vectors: Int)
    case deduplicated
    case vanished
    case failed(ErrorCategory)
    case cancelled
}

/// Indexes one file: hash, reuse vectors of an identical file, stream chunks out of the
/// extractor while earlier windows are already being embedded in the shared embedding lane,
/// then commit the whole file through the group-commit lane. Stateless and `Sendable`, so many
/// files run through it concurrently.
struct FilePipeline: Sendable {
    let writer: IndexWriter
    let extractors: [any ContentExtractor]
    let provider: any EmbeddingProvider
    let vectorIndex: any VectorIndex
    let gate: PriorityGate
    let thumbnails: ThumbnailStore
    let features: FeatureGateBox
    let options: IndexerOptions
    let embedder: EmbeddingBatcher
    let committer: CommitBatcher
    var stats: IndexingStats?
    /// The Photos library, when it is a source.
    var photos: (any PhotoLibraryProviding)?

    var space: VectorSpace { provider.descriptor.space }

    func process(_ record: FileRecord) async -> FileOutcome {
        do {
            guard let resolved = try await resolve(record) else {
                let removed = try await writer.removeFiles(atOrBelow: record.path)
                for id in removed { try await vectorIndex.remove(fileID: id) }
                return .vanished
            }
            defer { if let copy = resolved.temporaryCopy { try? FileManager.default.removeItem(at: copy) } }
            return try await index(record, from: resolved)
        } catch {
            return await outcome(of: error, for: record)
        }
    }

    private func index(_ record: FileRecord, from resolved: ResolvedFile) async throws -> FileOutcome {
        var clock = Stopwatch()
        let url = resolved.fileRef.url
        let precomputed = resolved.contentHash
        let hash = try await BlockingIO.run { try precomputed ?? ContentHasher.hash(of: url) }
        await time(.hash, record, seconds: clock.seconds)
        try Task.checkCancellation()

        if let duplicate = try await writer.indexedDuplicate(contentHash: hash, space: space, excluding: record.id) {
            let vectors = try await writer.copyIndex(from: duplicate, to: record.id, contentHash: hash, space: space)
            try await publish(vectors, for: record)
            return .deduplicated
        }

        guard let extractor = extractors.first(where: { $0.canExtract(record.contentType) }) else {
            try await writer.markFailed(record.id, category: .unsupported)
            return .failed(.unsupported)
        }
        let extractState = Signposts.indexing.beginInterval(Signposts.Name.extractFile)
        let streamed = try await extractAndEmbed(extractor.chunks(of: resolved.fileRef), record: record, contentHash: hash)
        Signposts.indexing.endInterval(Signposts.Name.extractFile, extractState)
        await time(.extract, record, seconds: streamed.extractSeconds)
        await time(.embed, record, seconds: streamed.embedWaitSeconds)

        clock = Stopwatch()
        let commitState = Signposts.indexing.beginInterval(Signposts.Name.commitFile)
        let vectors = try await committer.commit(
            FileCommit(fileID: record.id, contentHash: hash, space: space, chunks: streamed.writes, media: streamed.media))
        Signposts.indexing.endInterval(Signposts.Name.commitFile, commitState)
        try await publish(vectors, for: record)
        await time(.commit, record, seconds: clock.seconds)
        await stats?.finish(record.kind, bytes: record.size, chunks: streamed.writes.count, vectors: vectors.count)
        return .indexed(chunks: streamed.writes.count, vectors: vectors.count)
    }

    /// A cancelled file goes back to the queue; any other failure is recorded against it.
    private func outcome(of error: any Error, for record: FileRecord) async -> FileOutcome {
        let category = error is CancellationError ? .cancelled : error.glintCategory
        if category == .cancelled {
            try? await writer.release(record.id)
            return .cancelled
        }
        let errorType = String(describing: type(of: error))
        Log.indexer.notice(
            "Indexing failed (\(category.rawValue, privacy: .public), \(errorType, privacy: .public)) for \(record.path, privacy: .private)"
        )
        try? await writer.markFailed(record.id, category: category)
        return .failed(category)
    }

    private func time(_ stage: IndexingStage, _ record: FileRecord, seconds: Double) async {
        await stats?.record(record.kind, stage: stage, seconds: seconds)
    }

    // MARK: Streaming extraction and embedding

    private struct Streamed {
        var writes: [ChunkWrite] = []
        var media = FileMedia()
        /// Time spent waiting on the extractor.
        var extractSeconds = 0.0
        /// Time spent waiting on embeddings after extraction could not run ahead any further.
        var embedWaitSeconds = 0.0
    }

    private typealias Window = Task<[(index: Int, values: [Float]?)], any Error>

    /// Pulls chunks from the extractor and hands them to the embedding lane in windows, so
    /// extraction of later chunks overlaps embedding of earlier ones, and at most
    /// `embeddingWindowsInFlight` windows of media are alive at once.
    private func extractAndEmbed(
        _ stream: AsyncThrowingStream<Chunk, any Error>, record: FileRecord, contentHash: String
    ) async throws -> Streamed {
        var result = Streamed()
        let snapshot = features.current
        var windows = EmbeddingWindows(
            embedder: embedder, size: max(1, options.embeddingBatchSize), maxInFlight: max(1, options.embeddingWindowsInFlight))
        var iterator = stream.makeAsyncIterator()

        func settle(_ task: Window) async throws {
            let clock = Stopwatch()
            for (index, values) in try await task.value { result.writes[index].vector = values }
            result.embedWaitSeconds += clock.seconds
        }

        do {
            while true {
                let clock = Stopwatch()
                let next = try await iterator.next()
                result.extractSeconds += clock.seconds
                guard let next else { break }
                try Task.checkCancellation()
                guard let chunk = admitted(next, snapshot: snapshot) else { continue }
                if result.writes.isEmpty {
                    result.media = FileMedia(duration: chunk.preview.duration, waveform: chunk.preview.waveform)
                }
                let index = result.writes.count
                let overflow = composedInput(for: chunk, record: record).flatMap { windows.append(index, $0) }
                result.writes.append(
                    ChunkWrite(
                        ordinal: chunk.ordinal, locator: chunk.locator, text: chunk.text,
                        thumbnail: saveThumbnail(chunk, contentHash: contentHash), vector: nil))
                if let overflow { try await settle(overflow) }
                if result.writes.count >= options.maxChunksPerFile { break }
            }
            // Extractor streams finish quietly when the consuming task is cancelled; never commit
            // a half-read file as done.
            try Task.checkCancellation()
            for task in windows.flush() { try await settle(task) }
        } catch {
            windows.cancel()
            throw error
        }
        return result
    }

    /// The chunk as stored. Media the license doesn't cover loses its embedding input; a gated
    /// chunk with nothing to keyword-index is dropped entirely.
    private func admitted(_ chunk: Chunk, snapshot: FeatureGateSnapshot) -> Chunk? {
        guard let required = chunk.requiredFeature, !snapshot.allows(required) else { return chunk }
        var chunk = chunk
        chunk.input = nil
        if chunk.text?.isEmpty ?? true, chunk.preview.thumbnail == nil { return nil }
        return chunk
    }

    /// One file's embedding inputs, sent to the embedding lane a window at a time.
    private struct EmbeddingWindows {
        let embedder: EmbeddingBatcher
        let size: Int
        let maxInFlight: Int
        private var pending: [(index: Int, input: EmbeddingInput)] = []
        private var inFlight: [Window] = []

        init(embedder: EmbeddingBatcher, size: Int, maxInFlight: Int) {
            self.embedder = embedder
            self.size = size
            self.maxInFlight = maxInFlight
        }

        /// Queues the input of chunk `index`. Returns the oldest window, for the caller to wait
        /// on, once too many are in flight.
        mutating func append(_ index: Int, _ input: EmbeddingInput) -> Window? {
            pending.append((index, input))
            guard pending.count >= size else { return nil }
            submit()
            return inFlight.count > maxInFlight ? inFlight.removeFirst() : nil
        }

        /// Submits what is left and returns every window still in flight.
        mutating func flush() -> [Window] {
            submit()
            return inFlight
        }

        func cancel() {
            for task in inFlight { task.cancel() }
        }

        private mutating func submit() {
            guard !pending.isEmpty else { return }
            let items = pending
            pending = []
            let embedder = embedder
            inFlight.append(
                Task {
                    let embeddings = try await embedder.embed(items.map(\.input))
                    return zip(items, embeddings).map { item, embedding in
                        (item.index, embedding.values.contains { $0 != 0 } ? embedding.values : nil)
                    }
                })
        }
    }

    private func saveThumbnail(_ chunk: Chunk, contentHash: String) -> String? {
        let key = chunk.preview.thumbnailKey ?? "c\(chunk.ordinal)"
        if let image = chunk.preview.thumbnail {
            return try? thumbnails.save(image, contentHash: contentHash, key: key)
        }
        guard chunk.preview.thumbnailKey != nil else { return nil }
        let path = thumbnails.relativePath(contentHash: contentHash, key: key)
        return FileManager.default.fileExists(atPath: thumbnails.url(forRelativePath: path).path) ? path : nil
    }

    private func composedInput(for chunk: Chunk, record: FileRecord) -> EmbeddingInput? {
        guard let input = chunk.input else { return nil }
        if options.documentTitles, case .text(let text) = input {
            return .document(title: (record.name as NSString).deletingPathExtension, text: text)
        }
        guard options.fuseTextIntoMedia, let text = chunk.text, !text.isEmpty else { return input }
        switch input {
        case .image, .video: return .interleaved([input, .text(String(text.prefix(600)))])
        case .text, .document, .audio, .interleaved: return input
        }
    }

    private func publish(_ vectors: [CommittedVector], for record: FileRecord) async throws {
        try await vectorIndex.remove(fileID: record.id)
        guard !vectors.isEmpty else { return }
        let attributes = record.attributes
        try await vectorIndex.upsert(
            vectors.map {
                StoredVector(chunkID: $0.chunkID, fileID: record.id, values: $0.values, attributes: attributes)
            })
    }
}

extension Stopwatch {
    var seconds: Double { milliseconds / 1_000 }
}
