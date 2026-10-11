import Foundation
import GlintCore
import GlintEmbedding
import GlintExtractors
import GlintIndexer
import GlintSearch
import GlintUI
import Observation

/// Owns the search model's lifecycle: EmbeddingGemma 2 when it's downloaded (the default),
/// the built-in fallback until then. Switching models re-embeds files in the background
/// while keyword search keeps working.
@MainActor
@Observable
final class ModelController: ModelControlling {
    private(set) var state: ModelUIState
    private(set) var activeModelName: String
    private(set) var reembedding = 0

    @ObservationIgnored private let store: ModelStore
    @ObservationIgnored private let artifact: ModelArtifact
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let engine: SearchEngine
    @ObservationIgnored private let indexer: Indexer
    @ObservationIgnored private let gate: PriorityGate
    @ObservationIgnored private let registry: () -> ExtractorRegistry
    @ObservationIgnored private let fallback: any EmbeddingProvider
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var active: EmbeddingGemma2Provider?

    init(
        store: ModelStore, artifact: ModelArtifact, settings: AppSettings, engine: SearchEngine, indexer: Indexer,
        gate: PriorityGate, fallback: any EmbeddingProvider, registry: @escaping () -> ExtractorRegistry
    ) {
        self.store = store
        self.artifact = artifact
        self.settings = settings
        self.engine = engine
        self.indexer = indexer
        self.gate = gate
        self.fallback = fallback
        self.registry = registry
        state = .notInstalled(downloadBytes: artifact.totalBytes)
        activeModelName = fallback.descriptor.displayName
    }

    var dimensions: Int { settings.modelDimensions }

    /// Called at launch before indexing starts: activates EmbeddingGemma 2 if it's installed.
    func activateIfInstalled() async {
        if case .installed(let directory) = await store.state(of: artifact) {
            await activate(directory: directory)
        }
        followProgress()
    }

    func download() {
        guard !state.isBusy, active == nil else { return }
        state = .downloading(received: 0, total: artifact.totalBytes)
        Task {
            do {
                let directory = try await store.install(artifact)
                await activate(directory: directory)
            } catch {
                if error.glintCategory != .cancelled { state = .failed(ErrorPresenter.message(for: error)) }
            }
        }
    }

    func cancelDownload() {
        Task { await store.cancel() }
        state = .notInstalled(downloadBytes: artifact.totalBytes)
    }

    /// Deletes the weights and returns to the built-in fallback.
    func remove() {
        Task {
            await switchTo(fallback, name: fallback.descriptor.displayName)
            active = nil
            try? await store.remove(artifact)
            state = .notInstalled(downloadBytes: artifact.totalBytes)
        }
    }

    func setDimensions(_ newDimensions: Int) {
        guard newDimensions != settings.modelDimensions else { return }
        settings.modelDimensions = newDimensions
        Task {
            guard case .installed(let directory) = await store.state(of: artifact) else { return }
            await activate(directory: directory)
        }
    }

    /// Loads EmbeddingGemma 2 (text tower only; media towers load when indexing needs them)
    /// and switches search and indexing to its space.
    private func activate(directory: URL) async {
        state = .loading
        do {
            // After an hour without searching or indexing, give the model's memory back; the
            // next search reloads it in a second or two.
            let provider = try await EmbeddingGemma2Provider(
                directory: directory, towers: .text, dimensions: settings.modelDimensions, idleUnload: .seconds(3_600))
            active = provider
            await switchTo(provider, name: provider.descriptor.displayName)
            state = .active
        } catch {
            Log.embedding.error("EmbeddingGemma 2 failed to load: \(String(describing: error), privacy: .public)")
            state = .failed(ErrorPresenter.message(for: error))
        }
    }

    private func switchTo(_ provider: any EmbeddingProvider, name: String) async {
        let index = FlatVectorIndex(space: provider.descriptor.space)
        let encoder = GatedQueryEncoder(provider: provider, gate: gate)
        do {
            try await engine.switchModel(
                encoder: encoder, exampleEncoder: FileExampleEncoder(registry: registry(), provider: provider), vectorIndex: index)
        } catch {
            Log.search.error("Loading vectors for the new model failed: \(String(describing: error), privacy: .public)")
        }
        reembedding = await indexer.switchModel(to: provider, vectorIndex: index)
        activeModelName = name
    }

    private func followProgress() {
        guard progressTask == nil else { return }
        progressTask = Task { [weak self, store] in
            for await update in await store.updates() {
                guard let self else { return }
                switch update {
                case .downloading(let received, let total): self.state = .downloading(received: received, total: total)
                case .verifying: self.state = .verifying
                case .failed(let message): self.state = .failed(message)
                case .notInstalled, .installed: break
                }
            }
        }
    }
}
