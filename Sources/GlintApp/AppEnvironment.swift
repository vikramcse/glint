import AppKit
import Foundation
import GlintCore
import GlintEmbedding
import GlintExtractors
import GlintIndexer
import GlintRemote
import GlintSearch
import GlintStore
import GlintUI

/// The composition root: builds the object graph once and owns it for the app's lifetime.
/// Nothing else in the codebase creates services or holds global state.
@MainActor
final class AppEnvironment {
    let paths: AppPaths
    let settings: AppSettings
    let writer: IndexWriter
    let reader: IndexReader
    let provider: any EmbeddingProvider
    let priorityGate = PriorityGate()
    let vectorIndex: FlatVectorIndex
    let thumbnails: ThumbnailStore
    let engine: SearchEngine
    let indexer: Indexer
    let metricKit: MetricKitReporter
    let services: GlintServices
    let savedSearches: AppSavedSearches
    let photos = PhotoKitLibrary()
    /// S3 buckets. Secret keys live in the Keychain (UI tests use memory).
    let remotes: RemoteStorageFactory
    let models: ModelController
    let isUITest: Bool
    let localAPI: LocalAPIController
    private var volumeObservers: [any NSObjectProtocol] = []

    init(settings: AppSettings, launch: LaunchOptions = .current) throws {
        self.settings = settings
        isUITest = launch.isUITest
        paths = try launch.testRoot.map(AppPaths.init(root:)) ?? AppPaths.standard()
        try paths.createDirectories()

        writer = try Self.openWriter(at: paths.database)
        reader = try IndexReader(url: paths.database)
        provider = Self.makeProvider()
        thumbnails = ThumbnailStore(directory: paths.thumbnails)

        vectorIndex = FlatVectorIndex(space: provider.descriptor.space)
        let registry = ExtractorRegistry.standard(options: Self.extractionOptions(settings))
        engine = SearchEngine(
            reader: reader, vectorIndex: vectorIndex, encoder: GatedQueryEncoder(provider: provider, gate: priorityGate),
            exampleEncoder: FileExampleEncoder(registry: registry, provider: provider), thumbnails: thumbnails
        )
        remotes = RemoteStorageFactory(secrets: launch.isUITest ? InMemorySecretStore() : KeychainSecretStore())
        indexer = Indexer(
            writer: writer, extractors: registry.extractors, provider: provider, vectorIndex: vectorIndex,
            gate: priorityGate, thumbnails: thumbnails,
            options: IndexerOptions(videoOnlyOnPower: settings.videoOnlyOnPower),
            photos: photos, remotes: remotes
        )

        metricKit = MetricKitReporter(directory: paths.diagnostics)
        savedSearches = AppSavedSearches(writer: writer, reader: reader)

        services = GlintServices(
            engine: engine, indexing: indexer, settings: settings,
            modelDescription: Self.modelDescription(active: provider.descriptor),
            storageUsage: Self.storageUsage(paths: paths, thumbnails: thumbnails)
        )

        let options = Self.extractionOptions(settings)
        models = ModelController(
            store: ModelStore(directory: paths.models), artifact: .embeddingGemma2(baseURL: Self.modelBaseURL), settings: settings,
            engine: engine, indexer: indexer, gate: priorityGate, fallback: provider,
            registry: { ExtractorRegistry.standard(options: options) }
        )
        services.models = models
        services.people = AppPeople(engine: engine, writer: writer, reader: reader, indexer: indexer)
        localAPI = LocalAPIController(paths: paths, engine: engine, indexing: indexer, settings: settings)
        services.localAPI = localAPI.control
    }

    /// Loads vectors into the resident index, then starts the indexer.
    func start() async {
        let stopwatch = Stopwatch()
        // Remote files opened last session; they are downloaded again when opened.
        try? FileManager.default.removeItem(at: AppResultActions.remoteDownloads)
        // Activate EmbeddingGemma 2 first (when downloaded) so indexing starts in its space.
        // UI tests use the built-in model so they don't depend on a 1.5 GB download.
        if !isUITest { await models.activateIfInstalled() }
        _ = try? await engine.loadVectors()
        Log.app.info("Search ready in \(Int(stopwatch.milliseconds), privacy: .public) ms")
        await indexer.start()
        observeVolumes()
    }

    /// Network shares and drives come and go: rescan them when a volume mounts or unmounts and
    /// when the Mac wakes (a share may have changed, or dropped, while it slept).
    private func observeVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        let names = [
            NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didWakeNotification,
        ]
        volumeObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [indexer] _ in
                Task { await indexer.refreshSources() }
            }
        }
    }

    /// Re-applies settings that change how files are extracted.
    func applyIndexingSettings() async {
        let registry = ExtractorRegistry.standard(options: Self.extractionOptions(settings))
        await indexer.reconfigure(extractors: registry.extractors, options: IndexerOptions(videoOnlyOnPower: settings.videoOnlyOnPower))
    }

    // MARK: Factories

    /// Where EmbeddingGemma 2 downloads from (Info.plist `GlintModelBaseURL`), if overridden.
    private static var modelBaseURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "GlintModelBaseURL") as? String).flatMap(URL.init(string:))
    }

    private static func storageUsage(paths: AppPaths, thumbnails: ThumbnailStore) -> @Sendable () async -> Int64 {
        {
            let database = (try? FileManager.default.attributesOfItem(atPath: paths.database.path)[.size] as? Int64) ?? 0
            return database + thumbnails.diskUsage()
        }
    }

    private static func openWriter(at url: URL) throws -> IndexWriter {
        do {
            return try IndexWriter(url: url)
        } catch StoreError.corrupt {
            // A corrupt index is derived data: move it aside and rebuild rather than failing.
            Log.store.error("Index database is corrupt; rebuilding")
            let aside = url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).sqlite")
            try? FileManager.default.moveItem(at: url, to: aside)
            return try IndexWriter(url: url)
        }
    }

    private static func makeProvider() -> any EmbeddingProvider {
        do {
            return try AppleOnDeviceEmbeddingProvider()
        } catch {
            Log.embedding.error(
                "On-device embedding unavailable, using keyword-only fallback: \(String(describing: error), privacy: .public)")
            return HashingEmbeddingProvider()
        }
    }

    private static func extractionOptions(_ settings: AppSettings) -> ExtractionOptions {
        var options = ExtractionOptions.default
        options.transcriptionEnabled = settings.transcribeAudio
        return options
    }

    private static func modelDescription(active: ModelDescriptor) -> ModelDescription {
        ModelDescription(
            options: ModelCatalog.all.map { entry in
                let descriptor = entry.descriptor
                let detail = "\(descriptor.dimensions) dimensions · \(descriptor.license)"
                return ModelDescription.Option(
                    id: descriptor.id, name: descriptor.displayName, detail: detail,
                    isAvailable: entry.isAvailable, isActive: descriptor.id == active.id
                )
            })
    }
}
