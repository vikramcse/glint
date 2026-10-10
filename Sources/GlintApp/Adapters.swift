import Foundation
import GlintCore
import GlintExtractors
import GlintStore
import GlintTelemetry
import GlintUI
import UniformTypeIdentifiers

/// Maps UI events to the opt-in telemetry schema.
enum TelemetryBridge {
    static func event(for event: UIEvent) -> TelemetryEvent? {
        switch event {
        case .searchPerformed(let latency, let count, let kinds):
            .searchPerformed(latencyMilliseconds: latency, resultCount: count, kinds: kinds)
        case .resultOpened(let rank, let kind):
            .resultOpened(rank: rank, kind: kind)
        case .paywallViewed(let reason):
            PaywallTrigger(rawValue: reason.rawValue).map(TelemetryEvent.paywallViewed)
        case .onboardingCompleted(let sources, let duration):
            .onboardingCompleted(sourceCount: sources, duration: duration)
        }
    }
}

/// Embeds a dropped file for "find similar" when it is not in the index.
struct FileExampleEncoder: ExampleEncoder {
    let registry: ExtractorRegistry
    let provider: any EmbeddingProvider
    var maxInputs = 8

    func embeddings(forFileAt url: URL) async throws -> [Embedding] {
        let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .contentModificationDateKey])
        guard let type = values.contentType, let kind = MediaKind(contentType: type), let extractor = registry.extractor(for: type) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let file = FileRef(
            id: FileID(-1), url: url, kind: kind, contentType: type, size: Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate ?? Date()
        )
        var inputs: [EmbeddingInput] = []
        for try await chunk in extractor.chunks(of: file) {
            if let input = chunk.input { inputs.append(input) }
            if inputs.count >= maxInputs { break }
        }
        guard !inputs.isEmpty else { return [] }
        return try await provider.embed(inputs, purpose: .document)
    }
}

/// Saved searches on top of the index store.
struct AppSavedSearches: SavedSearchProviding {
    let writer: IndexWriter
    let reader: IndexReader

    func savedSearches() async -> [SavedSearchItem] {
        ((try? await reader.savedSearches()) ?? []).map { SavedSearchItem(id: $0.id, name: $0.name, query: $0.query) }
    }

    func save(name: String, query: String) async throws -> SavedSearchItem {
        let saved = try await writer.saveSearch(name: name, query: query, filter: .none)
        return SavedSearchItem(id: saved.id, name: saved.name, query: saved.query)
    }

    func delete(id: Int64) async throws {
        try await writer.deleteSavedSearch(id: id)
    }
}
