import Foundation
import GlintCore
import GlintEmbedding
import GlintExtractors
import GlintStore

/// The background indexer: scans sources, watches them for changes, and works through the
/// pending queue (documents and images first, then audio, then video), pausing for battery,
/// Low Power Mode, heat, the Free item limit, or the user.
public actor Indexer: IndexingService {
    let writer: IndexWriter
    var pipeline: FilePipeline
    var vectorIndex: any VectorIndex
    private let thumbnails: ThumbnailStore
    let features: FeatureGateBox
    let power: any PowerMonitoring
    var options: IndexerOptions
    let watcher = FileSystemWatcher()

    var rules = ExclusionRules.default
    var phase: IndexStatus.Phase = .idle
    var userPaused = false
    var inaccessibleSources = 0
    private var lastSnapshot: FeatureGateSnapshot
    private var loopTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    var wakeContinuation: CheckedContinuation<Void, Never>?
    var wakePending = false
    private var subscribers: [UUID: AsyncStream<IndexStatus>.Continuation] = [:]
    private var lastPublish: ContinuousClock.Instant?
    let photos: (any PhotoLibraryProviding)?
    var photosTask: Task<Void, Never>?
    /// Claimed files waiting for a worker, in queue order.
    var prefetched: [FileRecord] = []
    /// Claimed files not yet finished (prefetched or being processed); excluded from claims.
    var inFlight: Set<FileID> = []
    var refill: Task<Void, Never>?
    var queueExhausted = false
    /// Pools running right now (the queue loop and `drain()` may overlap).
    var activePools = 0

    private static let exclusionsKey = "exclusions"

    public init(
        writer: IndexWriter,
        extractors: [any ContentExtractor],
        provider: any EmbeddingProvider,
        vectorIndex: any VectorIndex,
        gate: PriorityGate,
        thumbnails: ThumbnailStore,
        features: FeatureGateBox,
        power: any PowerMonitoring = SystemPowerMonitor(),
        options: IndexerOptions = IndexerOptions(),
        stats: IndexingStats? = nil,
        photos: (any PhotoLibraryProviding)? = nil
    ) {
        self.photos = photos
        self.writer = writer
        self.vectorIndex = vectorIndex
        self.thumbnails = thumbnails
        self.features = features
        self.power = power
        self.options = options
        lastSnapshot = features.current
        pipeline = FilePipeline(
            writer: writer, extractors: extractors, provider: provider, vectorIndex: vectorIndex, gate: gate,
            thumbnails: thumbnails, features: features, options: options,
            embedder: EmbeddingBatcher(
                provider: provider, gate: gate, maxBatch: options.embeddingBatchSize, maxWait: options.embeddingBatchWait,
                lanes: options.embeddingLanes),
            committer: CommitBatcher(writer: writer, maxFiles: options.commitBatchSize),
            stats: stats
        )
        pipeline.photos = photos
    }

    // MARK: Lifecycle

    /// Catches up with changes made while the app was closed, then starts watching and indexing.
    public func start() async {
        if let json = try? await writer.setting(Self.exclusionsKey),
            let stored = try? JSONDecoder().decode(ExclusionRules.self, from: Data(json.utf8))
        {
            rules = stored
        }
        let requeued = (try? await writer.requeueFiles(notIn: pipeline.space)) ?? 0
        if requeued > 0 { Log.indexer.info("Re-embedding \(requeued, privacy: .public) files for a new model") }
        await rescanAllSources()
        await restartWatcher()
        watchTask = Task { [weak self, changes = watcher.changes] in
            for await change in changes { await self?.handle(change) }
        }
        loopTask = Task { [weak self] in await self?.runLoop() }
        startObservingPhotos()
    }

    /// Stops indexing; in-flight files return to the queue.
    public func stop() {
        loopTask?.cancel()
        watchTask?.cancel()
        photosTask?.cancel()
        watcher.stop()
        wake()
    }

    /// Applies new extractors (for example with transcription turned on) and options to files
    /// indexed from now on.
    public func reconfigure(extractors: [any ContentExtractor]? = nil, options newOptions: IndexerOptions? = nil) {
        if let newOptions { options = newOptions }
        pipeline = FilePipeline(
            writer: writer, extractors: extractors ?? pipeline.extractors, provider: pipeline.provider,
            vectorIndex: vectorIndex, gate: pipeline.gate, thumbnails: thumbnails, features: features, options: options,
            embedder: EmbeddingBatcher(
                provider: pipeline.provider, gate: pipeline.gate, maxBatch: options.embeddingBatchSize,
                maxWait: options.embeddingBatchWait, lanes: options.embeddingLanes),
            committer: CommitBatcher(writer: writer, maxFiles: options.commitBatchSize),
            stats: pipeline.stats
        )
        pipeline.photos = photos
        wake()
    }

    /// Switches to another embedding model: new vectors go into `vectorIndex`, and every file
    /// embedded in a different space goes back to the queue to be re-embedded in the background.
    /// Returns how many files were re-queued.
    @discardableResult
    public func switchModel(to provider: any EmbeddingProvider, vectorIndex newIndex: any VectorIndex) async -> Int {
        vectorIndex = newIndex
        pipeline = FilePipeline(
            writer: writer, extractors: pipeline.extractors, provider: provider, vectorIndex: newIndex, gate: pipeline.gate,
            thumbnails: thumbnails, features: features, options: options,
            embedder: EmbeddingBatcher(
                provider: provider, gate: pipeline.gate, maxBatch: options.embeddingBatchSize,
                maxWait: options.embeddingBatchWait, lanes: options.embeddingLanes),
            committer: CommitBatcher(writer: writer, maxFiles: options.commitBatchSize),
            stats: pipeline.stats
        )
        pipeline.photos = photos
        let requeued = (try? await writer.requeueFiles(notIn: provider.descriptor.space)) ?? 0
        Log.indexer.info("Switched model; re-embedding \(requeued, privacy: .public) files")
        wake()
        await publishStatus(force: true)
        return requeued
    }

    /// Indexes everything pending and returns when the queue is empty (used by tests and the eval harness).
    public func drain() async {
        await runPool()
        // Files another pool (the queue loop) claimed are still in flight; wait for them, then
        // sweep once more for anything they left behind.
        while !inFlight.isEmpty, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await runPool()
        _ = try? await writer.failExhausted()
        await publishStatus(force: true)
    }

    // MARK: IndexingService

    public func statusUpdates() async -> AsyncStream<IndexStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: IndexStatus.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        continuation.yield(await currentStatus())
        return stream
    }

    public func currentStatus() async -> IndexStatus {
        let counts = (try? await writer.counts()) ?? IndexCounts()
        let gate = features.current
        let locked = counts.pending.filter { !gate.allows($0.key) }.values.reduce(0, +)
        let sourceCount = (try? await writer.sources().count) ?? 0
        return IndexStatus(
            phase: phase, indexed: counts.indexed, pending: counts.totalPending - locked, locked: locked,
            failed: counts.failed, sourceCount: sourceCount, inaccessibleSources: inaccessibleSources
        )
    }

    public func sources() async throws -> [SourceInfo] {
        let counts = try await writer.sourceCounts()
        let gate = features.current
        return try await writer.sources().map { record in
            let source = counts[record.id] ?? IndexCounts()
            let locked = source.pending.filter { !gate.allows($0.key) }.values.reduce(0, +)
            return SourceInfo(
                id: record.id, path: record.path, isExternalVolume: Self.isExternal(URL(fileURLWithPath: record.path)),
                isAccessible: isAccessible(record.path),
                itemCount: source.totalIndexed + source.totalPending + source.failed,
                indexed: source.totalIndexed, pending: source.totalPending - locked, locked: locked, failed: source.failed
            )
        }
    }

    @discardableResult
    public func addSource(_ url: URL) async throws -> SourceInfo {
        if url.scheme == PhotosLibraryPath.scheme { return try await addPhotosLibrary() }
        let path = FileScanner.canonicalPath(url)
        let gate = features.current
        let existing = try await writer.sources()
        if let found = existing.first(where: { $0.path == path }) {
            return try await sources().first { $0.id == found.id }
                ?? SourceInfo(
                    id: found.id, path: path, isExternalVolume: false, isAccessible: true, itemCount: 0
                )
        }
        if let limit = gate.sourceLimit, existing.count >= limit { throw EntitlementError.sourceLimitReached(limit: limit) }
        let external = Self.isExternal(url)
        if external, !gate.allows(.externalDrives) { throw EntitlementError.externalDrivesRequirePro }
        guard await Self.canList(path) else { throw IndexerError.sourceUnreadable }

        let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let id = try await writer.addSource(path: path, bookmark: bookmark)
        await rescan(sourceID: id, root: path)
        await restartWatcher()
        wake()
        return try await sources().first { $0.id == id }
            ?? SourceInfo(id: id, path: path, isExternalVolume: external, isAccessible: true, itemCount: 0)
    }

    public func removeSource(_ id: SourceID) async throws {
        let removed = try await writer.removeSource(id)
        for fileID in removed.files { try await vectorIndex.remove(fileID: fileID) }
        thumbnails.delete(relativePaths: removed.orphanedThumbnails)
        await restartWatcher()
        await publishStatus(force: true)
    }

    public func reindexSource(_ id: SourceID) async throws {
        guard let source = try await writer.sources().first(where: { $0.id == id }) else { return }
        let requeued = try await writer.requeueSource(id)
        Log.indexer.info("Re-indexing \(requeued, privacy: .public) files in a source")
        // Picks up files added or removed while the watcher missed them.
        await rescan(sourceID: id, root: source.path)
        wake()
        await publishStatus(force: true)
    }

    public func exclusions() async -> ExclusionRules { rules }

    public func setExclusions(_ newRules: ExclusionRules) async throws {
        let data = try JSONEncoder().encode(newRules)
        // JSONEncoder always writes UTF-8.
        guard let json = String(bytes: data, encoding: .utf8) else { return }
        try await writer.setSetting(Self.exclusionsKey, value: json)
        rules = newRules
        await rescanAllSources()
        wake()
    }

    public func pause() async {
        userPaused = true
        phase = .paused(.user)
        await publishStatus(force: true)
    }

    public func resume() async {
        userPaused = false
        wake()
    }

    public func entitlementsDidChange() async {
        let snapshot = features.current
        if snapshot.allows(.pdfVisualSearch), !lastSnapshot.allows(.pdfVisualSearch) {
            try? await writer.requeue(kinds: [.pdf])
        }
        lastSnapshot = snapshot
        wake()
        await publishStatus(force: true)
    }

    public func deleteIndex() async throws {
        try await writer.deleteDerivedData()
        try thumbnails.deleteAll()
        try await vectorIndex.removeAll()
        await rescanAllSources()
        wake()
    }

    // MARK: Status

    func setPhase(_ newPhase: IndexStatus.Phase) {
        phase = newPhase
    }

    func publishStatus(force: Bool = false) async {
        guard !subscribers.isEmpty else { return }
        let now = ContinuousClock.now
        if !force, let lastPublish, now - lastPublish < .milliseconds(500) { return }
        lastPublish = now
        let status = await currentStatus()
        for continuation in subscribers.values { continuation.yield(status) }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    /// Lists the folder once. For folders macOS protects (Desktop, Documents, Downloads,
    /// removable drives) this is what shows the privacy prompt, and a denial surfaces here
    /// instead of as an empty index. Runs off the cooperative pool because the prompt blocks.
    private static func canList(_ path: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil)
            }
        }
    }

    private static func isExternal(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey])
        return values?.volumeIsInternal == false
    }
}
