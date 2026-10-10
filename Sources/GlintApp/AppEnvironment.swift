import Foundation
import GlintCore
import GlintEmbedding
import GlintExtractors
import GlintIndexer
import GlintLicensing
import GlintSearch
import GlintStore
import GlintTelemetry
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
    let features: FeatureGateBox
    let vectorIndex: FlatVectorIndex
    let thumbnails: ThumbnailStore
    let engine: SearchEngine
    let indexer: Indexer
    let license: LicenseManager
    let telemetry: OptInTelemetryClient
    let telemetrySender: QueuedTelemetryClient
    let metricKit: MetricKitReporter
    let services: GlintServices
    let savedSearches: AppSavedSearches

    init(settings: AppSettings) throws {
        self.settings = settings
        paths = try AppPaths.standard()
        try paths.createDirectories()

        writer = try Self.openWriter(at: paths.database)
        reader = try IndexReader(url: paths.database)
        provider = Self.makeProvider()
        thumbnails = ThumbnailStore(directory: paths.thumbnails)

        license = LicenseManager(
            verifier: try LicenseVerifier.production(),
            store: SecureStoreFactory.make(fallbackDirectory: paths.root),
            // The M3 license server is not deployed yet; signed keys activate offline until then.
            activationService: AppLinks.licenseServer.map { HTTPActivationService(baseURL: $0) }
        )
        features = FeatureGateBox(license.entitlements.snapshot)

        vectorIndex = FlatVectorIndex(space: provider.descriptor.space)
        let registry = ExtractorRegistry.standard(options: Self.extractionOptions(settings))
        engine = SearchEngine(
            reader: reader,
            vectorIndex: vectorIndex,
            encoder: GatedQueryEncoder(provider: provider, gate: priorityGate),
            exampleEncoder: FileExampleEncoder(registry: registry, provider: provider),
            thumbnails: thumbnails,
            gate: features
        )
        indexer = Indexer(
            writer: writer, extractors: registry.extractors, provider: provider, vectorIndex: vectorIndex,
            gate: priorityGate, thumbnails: thumbnails, features: features,
            options: IndexerOptions(videoOnlyOnPower: settings.videoOnlyOnPower)
        )

        telemetrySender = QueuedTelemetryClient(
            queueURL: paths.telemetryQueue,
            transport: HTTPTelemetryTransport(endpoint: AppLinks.telemetryEndpoint),
            keyValueStore: UserDefaultsKeyValueStore()
        )
        telemetry = OptInTelemetryClient(sender: telemetrySender, isEnabled: settings.analyticsEnabled)
        metricKit = MetricKitReporter(directory: paths.diagnostics)
        savedSearches = AppSavedSearches(writer: writer, reader: reader)

        let telemetry = telemetry
        let paths = paths
        let thumbnails = thumbnails
        services = GlintServices(
            engine: engine,
            indexing: indexer,
            license: license,
            settings: settings,
            modelDescription: Self.modelDescription(active: provider.descriptor),
            report: { event in
                guard let mapped = TelemetryBridge.event(for: event) else { return }
                Task { await telemetry.record(mapped) }
            },
            storageUsage: {
                let database = (try? FileManager.default.attributesOfItem(atPath: paths.database.path)[.size] as? Int64) ?? 0
                return database + thumbnails.diskUsage()
            },
            analyticsPreview: { await telemetry.pendingPayloadPreview() }
        )
    }

    /// Loads vectors into the resident index, then starts the indexer.
    func start() async {
        let stopwatch = Stopwatch()
        _ = try? await engine.loadVectors()
        Log.app.info("Search ready in \(Int(stopwatch.milliseconds), privacy: .public) ms")
        await indexer.start()
    }

    /// Re-applies settings that change how files are extracted.
    func applyIndexingSettings() async {
        let registry = ExtractorRegistry.standard(options: Self.extractionOptions(settings))
        await indexer.reconfigure(extractors: registry.extractors, options: IndexerOptions(videoOnlyOnPower: settings.videoOnlyOnPower))
    }

    // MARK: Factories

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
            Log.embedding.error("On-device embedding unavailable, using keyword-only fallback: \(String(describing: error), privacy: .public)")
            return HashingEmbeddingProvider()
        }
    }

    private static func extractionOptions(_ settings: AppSettings) -> ExtractionOptions {
        var options = ExtractionOptions.default
        options.transcriptionEnabled = settings.transcribeAudio
        return options
    }

    private static func modelDescription(active: ModelDescriptor) -> ModelDescription {
        ModelDescription(options: ModelCatalog.all.map { entry in
            let descriptor = entry.descriptor
            let detail = "\(descriptor.dimensions) dimensions · \(descriptor.license)"
            return ModelDescription.Option(
                id: descriptor.id, name: descriptor.displayName, detail: detail,
                isAvailable: entry.isAvailable, isActive: descriptor.id == active.id
            )
        })
    }
}

/// External endpoints, in one place.
enum AppLinks {
    static let purchasePage = URL(string: "https://glint.app/buy")
    /// `nil` until the license server ships in M3.
    static let licenseServer: URL? = nil
    // swiftlint:disable:next force_unwrapping
    static let telemetryEndpoint = URL(string: "https://telemetry.glint.app/v1/events") ?? URL(fileURLWithPath: "/dev/null")
    static let fullDiskAccessSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
}
