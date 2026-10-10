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

/// Indexes one file: hash, reuse vectors of an identical file, extract chunks and display
/// data, embed through the priority gate, then commit everything in one transaction.
/// Stateless and `Sendable`, so several files can run through it concurrently.
struct FilePipeline: Sendable {
    let writer: IndexWriter
    let extractors: [any ContentExtractor]
    let provider: any EmbeddingProvider
    let vectorIndex: any VectorIndex
    let gate: PriorityGate
    let thumbnails: ThumbnailStore
    let features: FeatureGateBox
    let options: IndexerOptions

    var space: VectorSpace { provider.descriptor.space }

    func process(_ record: FileRecord) async -> FileOutcome {
        do {
            guard FileManager.default.fileExists(atPath: record.path) else {
                let removed = try await writer.removeFiles(atOrBelow: record.path)
                for id in removed { try await vectorIndex.remove(fileID: id) }
                return .vanished
            }
            let hash = try ContentHasher.hash(of: record.url)
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
            let chunks = try await collect(extractor.chunks(of: record.fileRef))
            Signposts.indexing.endInterval(Signposts.Name.extractFile, extractState)

            let writes = try await embed(chunks, contentHash: hash)
            let first = chunks.first?.preview
            let commitState = Signposts.indexing.beginInterval(Signposts.Name.commitFile)
            let vectors = try await writer.commit(
                fileID: record.id, contentHash: hash, space: space, chunks: writes,
                media: FileMedia(duration: first?.duration, waveform: first?.waveform)
            )
            Signposts.indexing.endInterval(Signposts.Name.commitFile, commitState)
            try await publish(vectors, for: record)
            return .indexed(chunks: writes.count, vectors: vectors.count)
        } catch is CancellationError {
            try? await writer.release(record.id)
            return .cancelled
        } catch {
            let category = error.glintCategory
            if category == .cancelled {
                try? await writer.release(record.id)
                return .cancelled
            }
            Log.indexer.notice("Indexing failed (\(category.rawValue, privacy: .public)) for \(record.path, privacy: .private)")
            try? await writer.markFailed(record.id, category: category)
            return .failed(category)
        }
    }

    private func collect(_ stream: AsyncThrowingStream<Chunk, any Error>) async throws -> [Chunk] {
        var chunks: [Chunk] = []
        let gate = features.current
        for try await chunk in stream {
            try Task.checkCancellation()
            var chunk = chunk
            if let required = chunk.requiredFeature, !gate.allows(required) {
                chunk.input = nil
                // A gated chunk with nothing to keyword-index is dropped entirely.
                if chunk.text?.isEmpty ?? true, chunk.preview.thumbnail == nil { continue }
            }
            chunks.append(chunk)
            if chunks.count >= options.maxChunksPerFile { break }
        }
        return chunks
    }

    /// Saves thumbnails and embeds inputs in batches, yielding to search between batches.
    private func embed(_ chunks: [Chunk], contentHash: String) async throws -> [ChunkWrite] {
        var writes: [ChunkWrite] = []
        var pending: [(index: Int, input: EmbeddingInput)] = []
        for chunk in chunks {
            var thumbnail: String?
            let key = chunk.preview.thumbnailKey ?? "c\(chunk.ordinal)"
            if let image = chunk.preview.thumbnail {
                thumbnail = try? thumbnails.save(image, contentHash: contentHash, key: key)
            } else if chunk.preview.thumbnailKey != nil {
                let path = thumbnails.relativePath(contentHash: contentHash, key: key)
                if FileManager.default.fileExists(atPath: thumbnails.url(forRelativePath: path).path) { thumbnail = path }
            }
            if let input = composedInput(for: chunk) { pending.append((writes.count, input)) }
            writes.append(ChunkWrite(ordinal: chunk.ordinal, locator: chunk.locator, text: chunk.text, thumbnail: thumbnail, vector: nil))
        }

        var start = 0
        while start < pending.count {
            try Task.checkCancellation()
            await gate.waitForIndexingTurn()
            let size = await gate.recommendedBatchSize(options.embeddingBatchSize)
            let batch = pending[start..<min(start + size, pending.count)]
            let state = Signposts.indexing.beginInterval(Signposts.Name.embedBatch)
            let embeddings = try await provider.embed(batch.map(\.input), purpose: .document)
            Signposts.indexing.endInterval(Signposts.Name.embedBatch, state)
            for (item, embedding) in zip(batch, embeddings) where embedding.values.contains(where: { $0 != 0 }) {
                writes[item.index].vector = embedding.values
            }
            start += batch.count
        }
        return writes
    }

    private func composedInput(for chunk: Chunk) -> EmbeddingInput? {
        guard let input = chunk.input else { return nil }
        guard options.fuseTextIntoMedia, let text = chunk.text, !text.isEmpty else { return input }
        switch input {
        case .image, .video: return .interleaved([input, .text(String(text.prefix(600)))])
        case .text, .audio, .interleaved: return input
        }
    }

    private func publish(_ vectors: [CommittedVector], for record: FileRecord) async throws {
        try await vectorIndex.remove(fileID: record.id)
        guard !vectors.isEmpty else { return }
        let attributes = record.attributes
        try await vectorIndex.upsert(vectors.map {
            StoredVector(chunkID: $0.chunkID, fileID: record.id, values: $0.values, attributes: attributes)
        })
    }
}
