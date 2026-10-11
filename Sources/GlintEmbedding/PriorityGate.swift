import Foundation
import GlintCore

/// Arbitrates the GPU and model between the interactive search path and the indexer.
/// Search always wins: the indexer waits while a search is running and for a short quiet
/// period after it, and shrinks its batches while the user is typing.
public actor PriorityGate {
    private var activeSearches = 0
    private var lastSearch: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    /// How long after the last search the indexer keeps waiting.
    public let quietPeriod: Duration
    /// How long after the last search batches stay small.
    public let typingWindow: Duration

    public init(quietPeriod: Duration = .milliseconds(150), typingWindow: Duration = .seconds(2)) {
        self.quietPeriod = quietPeriod
        self.typingWindow = typingWindow
    }

    /// Runs a search-path operation at top priority.
    public func withSearchPriority<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        activeSearches += 1
        lastSearch = clock.now
        defer {
            activeSearches -= 1
            lastSearch = clock.now
        }
        return try await operation()
    }

    /// Suspends the indexer until no search is running and the quiet period has passed.
    public func waitForIndexingTurn() async {
        while !Task.isCancelled {
            if activeSearches == 0 {
                guard let lastSearch else { return }
                let remaining = quietPeriod - (clock.now - lastSearch)
                if remaining <= .zero { return }
                try? await Task.sleep(for: remaining)
            } else {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    /// The batch size the indexer should use right now.
    public func recommendedBatchSize(_ base: Int) -> Int {
        guard let lastSearch, clock.now - lastSearch < typingWindow else { return base }
        return max(1, base / 4)
    }

    public var isSearchActive: Bool { activeSearches > 0 }
}

/// Encodes search queries through the priority gate. This is the only object the search
/// path uses to reach a model, so the query encoder can stay warm and small.
public struct GatedQueryEncoder: QueryEncoding {
    private let provider: any EmbeddingProvider
    private let gate: PriorityGate

    public init(provider: any EmbeddingProvider, gate: PriorityGate) {
        self.provider = provider
        self.gate = gate
    }

    public var space: VectorSpace { provider.descriptor.space }
    public var minimumSimilarity: Float { provider.descriptor.minimumSimilarity ?? 0.25 }
    public var similarityMargin: Float? { provider.descriptor.similarityMargin }
    public var minimumZScore: Float? { provider.descriptor.minimumZScore }

    public func encode(query: String) async throws -> Embedding {
        let provider = provider
        let state = Signposts.search.beginInterval(Signposts.Name.queryEmbedding)
        defer { Signposts.search.endInterval(Signposts.Name.queryEmbedding, state) }
        return try await gate.withSearchPriority {
            guard let embedding = try await provider.embed([.text(query)], purpose: .query).first else {
                throw EmbeddingError.encodingFailed
            }
            return embedding
        }
    }

    public func encode(_ inputs: [EmbeddingInput]) async throws -> [Embedding] {
        let provider = provider
        return try await gate.withSearchPriority {
            try await provider.embed(inputs, purpose: .query)
        }
    }
}
