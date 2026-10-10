import Foundation
import GlintCore
import GlintEmbedding
import GlintExtractors
import GlintSearch
import GlintStore
import GlintTestSupport
import Testing
import UniformTypeIdentifiers

@testable import GlintIndexer

/// Records batch sizes and fails any batch containing the text "poison".
private actor RecordingProvider: EmbeddingProvider {
    nonisolated let descriptor = PipelineEmbeddingProvider().descriptor
    private(set) var batchSizes: [Int] = []
    let delay: Duration

    init(delay: Duration = .zero) { self.delay = delay }

    func embed(_ batch: [EmbeddingInput], purpose: EmbeddingPurpose) async throws -> [Embedding] {
        batchSizes.append(batch.count)
        if delay > .zero { try await Task.sleep(for: delay) }
        for input in batch {
            if case .text(let text) = input, text.contains("poison") { throw EmbeddingError.encodingFailed }
        }
        return try await PipelineEmbeddingProvider().embed(batch, purpose: purpose)
    }
}

@Suite("Embedding lane")
struct EmbeddingBatcherTests {
    @Test func packsWindowsFromSeveralFilesIntoOneCall() async throws {
        let provider = RecordingProvider(delay: .milliseconds(30))
        let batcher = EmbeddingBatcher(
            provider: provider, gate: PriorityGate(quietPeriod: .zero), maxBatch: 32, maxWait: .milliseconds(20))
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for file in 0..<8 {
                group.addTask {
                    try await batcher.embed((0..<3).map { .text("file \(file) chunk \($0)") }).count
                }
            }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(results == Array(repeating: 3, count: 8))
        let sizes = await provider.batchSizes
        #expect(sizes.reduce(0, +) == 24)
        #expect(sizes.count < 8, "windows from different files should share calls, got \(sizes)")
    }

    @Test func oneBadFileDoesNotFailTheOthers() async throws {
        let provider = RecordingProvider()
        let batcher = EmbeddingBatcher(
            provider: provider, gate: PriorityGate(quietPeriod: .zero), maxBatch: 32, maxWait: .milliseconds(20))
        let good = Task { try await batcher.embed([.text("fine"), .text("also fine")]) }
        let bad = Task { try await batcher.embed([.text("poison")]) }
        #expect(try await good.value.count == 2)
        await #expect(throws: EmbeddingError.self) { _ = try await bad.value }
    }

    @Test func respectsTheBatchLimit() async throws {
        let provider = RecordingProvider()
        let batcher = EmbeddingBatcher(
            provider: provider, gate: PriorityGate(quietPeriod: .zero), maxBatch: 4, maxWait: .milliseconds(5))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 { group.addTask { _ = try await batcher.embed([.text("a"), .text("b"), .text("c")]) } }
            try await group.waitForAll()
        }
        #expect(await provider.batchSizes.allSatisfy { $0 <= 4 })
    }
}

@Suite("Group commit")
struct CommitBatcherTests {
    private func pendingFiles(_ count: Int, writer: IndexWriter) async throws -> [FileRecord] {
        let source = try await writer.addSource(path: "/s", bookmark: nil)
        _ = try await writer.reconcile(
            sourceID: source,
            scanned: (0..<count).map {
                ScannedFile(path: "/s/\($0).txt", kind: .document, contentType: .plainText, size: 1, modified: Date())
            })
        return try await writer.claimPending(limit: count, kinds: [.document])
    }

    @Test func commitsEveryFileWholeAndReturnsItsVectors() async throws {
        let directory = try TemporaryDirectory()
        let writer = try IndexWriter(url: directory.url.appendingPathComponent("index.sqlite"))
        let files = try await pendingFiles(20, writer: writer)
        let space = VectorSpace(modelID: "t", dimension: 2)
        let batcher = CommitBatcher(writer: writer, maxFiles: 8)
        let counts = try await withThrowingTaskGroup(of: Int.self) { group in
            for file in files {
                group.addTask {
                    try await batcher.commit(
                        FileCommit(
                            fileID: file.id, contentHash: "h\(file.id.rawValue)", space: space,
                            chunks: [ChunkWrite(ordinal: 0, locator: .whole, text: "t", thumbnail: nil, vector: [1, 0])])
                    ).count
                }
            }
            return try await group.reduce(0, +)
        }
        #expect(counts == 20)
        #expect(try await writer.counts().indexed[.document] == 20)
    }

    @Test func claimsSkipFilesAlreadyInFlight() async throws {
        let directory = try TemporaryDirectory()
        let writer = try IndexWriter(url: directory.url.appendingPathComponent("index.sqlite"))
        let first = try await pendingFiles(4, writer: writer)
        let again = try await writer.claimPending(limit: 10, kinds: [.document], excluding: [first[0].id])
        #expect(!again.contains { $0.id == first[0].id })
        #expect(again.count == 3)
    }
}

@Suite("OCR lane")
struct LaneTests {
    @Test func widthLimitsConcurrency() async {
        let lane = Lane(width: 2)
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global().async {
                            lane.run {
                                counter.enter()
                                Thread.sleep(forTimeInterval: 0.01)
                                counter.leave()
                            }
                            continuation.resume()
                        }
                    }
                }
            }
        }
        #expect(counter.peak <= 2)
        lane.setWidth(5)
        #expect(lane.currentWidth == 5)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var peak = 0

    func enter() {
        lock.withLock {
            current += 1
            peak = max(peak, current)
        }
    }

    func leave() { lock.withLock { current -= 1 } }
}
