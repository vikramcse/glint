import Dispatch
import Foundation
import GlintCore
import GlintEmbedding
import GlintStore

/// Runs blocking file I/O (hashing) on a GCD queue, never on Swift's cooperative pool, where a
/// few slow disk reads would starve every other task in the process.
enum BlockingIO {
    private static let queue = DispatchQueue(label: "app.glint.indexer.io", qos: .utility, attributes: .concurrent)

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}

/// The embedding lanes. Files submit windows of inputs; the batcher packs windows from
/// different files into one model call (up to `maxBatch` inputs, waiting at most `maxWait` for
/// more to arrive), so a GPU model sees full batches even when files are small. Up to `lanes`
/// calls run at once: one suits a batched GPU model; providers that work input by input gain
/// from overlapping calls. It waits for the `PriorityGate` before every call and shrinks
/// batches while the user is typing.
actor EmbeddingBatcher {
    private struct Request {
        var inputs: [EmbeddingInput]
        var continuation: CheckedContinuation<[Embedding], any Error>
    }

    private let provider: any EmbeddingProvider
    private let gate: PriorityGate
    private let maxBatch: Int
    private let maxWait: Duration
    private let lanes: Int
    private var queue: [Request] = []
    private var queuedInputs = 0
    private var activeLanes = 0

    init(provider: any EmbeddingProvider, gate: PriorityGate, maxBatch: Int, maxWait: Duration, lanes: Int = 1) {
        self.provider = provider
        self.gate = gate
        self.maxBatch = max(1, maxBatch)
        self.maxWait = maxWait
        self.lanes = max(1, lanes)
    }

    /// Embeds `inputs` (at most `maxBatch`) as documents, possibly batched with other files.
    func embed(_ inputs: [EmbeddingInput]) async throws -> [Embedding] {
        guard !inputs.isEmpty else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            queue.append(Request(inputs: inputs, continuation: continuation))
            queuedInputs += inputs.count
            if activeLanes < lanes {
                activeLanes += 1
                Task { await drain() }
            }
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            await gate.waitForIndexingTurn()
            let limit = await gate.recommendedBatchSize(maxBatch)
            if queuedInputs < limit, maxWait > Duration.zero {
                // Give other files a moment to join this batch.
                try? await Task.sleep(for: maxWait)
            }
            var batch: [Request] = []
            var count = 0
            while let next = queue.first, batch.isEmpty || count + next.inputs.count <= limit {
                batch.append(queue.removeFirst())
                count += next.inputs.count
            }
            queuedInputs -= count
            guard !batch.isEmpty else { continue }
            await run(batch)
        }
        activeLanes -= 1
    }

    private func run(_ batch: [Request]) async {
        do {
            let inputs = batch.flatMap(\.inputs)
            let embeddings = try await provider.embed(inputs, purpose: .document)
            // With a missing embedding there is no telling which request it belonged to; the
            // retry below gives each request its own answer instead of shifting vectors.
            guard embeddings.count == inputs.count else { throw EmbeddingError.encodingFailed }
            var offset = 0
            for request in batch {
                let end = offset + request.inputs.count
                request.continuation.resume(returning: Array(embeddings[offset..<end]))
                offset = end
            }
        } catch {
            guard batch.count > 1 else {
                batch.first?.continuation.resume(throwing: error)
                return
            }
            // One bad input must not fail the other files in the batch: retry each alone.
            for request in batch {
                do {
                    let embeddings = try await provider.embed(request.inputs, purpose: .document)
                    guard embeddings.count == request.inputs.count else { throw EmbeddingError.encodingFailed }
                    request.continuation.resume(returning: embeddings)
                } catch {
                    request.continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Group commit for the single writer. When the writer is idle a file commits at once; while
/// a commit runs, finished files queue up and the next transaction takes all of them (bounded
/// by `maxFiles`). Small files stop paying a transaction each, and nothing waits on a timer.
actor CommitBatcher {
    private struct Request {
        var file: FileCommit
        var continuation: CheckedContinuation<[CommittedVector], any Error>
    }

    private let writer: IndexWriter
    private let maxFiles: Int
    private var queue: [Request] = []
    private var isCommitting = false

    init(writer: IndexWriter, maxFiles: Int) {
        self.writer = writer
        self.maxFiles = max(1, maxFiles)
    }

    func commit(_ file: FileCommit) async throws -> [CommittedVector] {
        try await withCheckedThrowingContinuation { continuation in
            queue.append(Request(file: file, continuation: continuation))
            if !isCommitting {
                isCommitting = true
                Task { await flush() }
            }
        }
    }

    private func flush() async {
        while !queue.isEmpty {
            let batch = Array(queue.prefix(maxFiles))
            queue.removeFirst(batch.count)
            do {
                let results = try await writer.commitMany(batch.map(\.file))
                for request in batch { request.continuation.resume(returning: results[request.file.fileID] ?? []) }
            } catch {
                // Isolate the failure to the file that caused it.
                for request in batch {
                    let file = request.file
                    do {
                        let vectors = try await writer.commit(
                            fileID: file.fileID, contentHash: file.contentHash, space: file.space, chunks: file.chunks, media: file.media,
                            version: file.version)
                        request.continuation.resume(returning: vectors)
                    } catch {
                        request.continuation.resume(throwing: error)
                    }
                }
            }
        }
        isCommitting = false
    }
}
