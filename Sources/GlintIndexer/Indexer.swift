import Foundation
import GlintCore
import GlintEmbedding
import GlintExtractors
import GlintStore

/// The background indexer: scans sources, watches them for changes, and works through the
/// pending queue (documents and images first, then audio, then video), pausing for battery,
/// Low Power Mode, heat, the Free item limit, or the user.
public actor Indexer: IndexingService {
    private let writer: IndexWriter
    private var pipeline: FilePipeline
    private var vectorIndex: any VectorIndex
    private let thumbnails: ThumbnailStore
    private let features: FeatureGateBox
    private let power: any PowerMonitoring
    private var options: IndexerOptions
    private let watcher = FileSystemWatcher()

    private var rules = ExclusionRules.default
    private var phase: IndexStatus.Phase = .idle
    private var userPaused = false
    private var inaccessibleSources = 0
    private var lastSnapshot: FeatureGateSnapshot
    private var loopTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var wakeContinuation: CheckedContinuation<Void, Never>?
    private var wakePending = false
    private var subscribers: [UUID: AsyncStream<IndexStatus>.Continuation] = [:]
    private var lastPublish: ContinuousClock.Instant?
    private let photos: (any PhotoLibraryProviding)?
    private var photosTask: Task<Void, Never>?
    /// Claimed files waiting for a worker, in queue order.
    private var prefetched: [FileRecord] = []
    /// Claimed files not yet finished (prefetched or being processed); excluded from claims.
    private var inFlight: Set<FileID> = []
    private var refill: Task<Void, Never>?
    private var queueExhausted = false
    /// Pools running right now (the queue loop and `drain()` may overlap).
    private var activePools = 0

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
        for fileID in removed { try await vectorIndex.remove(fileID: fileID) }
        await restartWatcher()
        await publishStatus(force: true)
    }

    public func exclusions() async -> ExclusionRules { rules }

    public func setExclusions(_ newRules: ExclusionRules) async throws {
        let data = try JSONEncoder().encode(newRules)
        try await writer.setSetting(Self.exclusionsKey, value: String(decoding: data, as: UTF8.self))
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

    // MARK: Queue loop

    private func runLoop() async {
        while !Task.isCancelled {
            if userPaused {
                setPhase(.paused(.user))
                await waitForWake()
                continue
            }
            if let reason = power.pauseReason() {
                setPhase(.paused(reason))
                await waitForWake(timeout: .seconds(30))
                continue
            }
            setPhase(.indexing)
            await runPool()
            if userPaused || power.pauseReason() != nil { continue }
            _ = try? await writer.failExhausted()
            if case .paused(.itemLimitReached) = phase {} else { setPhase(.idle) }
            await publishStatus(force: true)
            await waitForWake(timeout: .seconds(300))
        }
    }

    /// Runs a pool of workers until the queue is empty, indexing pauses, or the task is
    /// cancelled. Each worker takes the next file as soon as it finishes one, so a long video
    /// never holds up the files behind it. On battery or when warm, fewer workers and OCR
    /// lanes run instead of pausing.
    private func runPool() async {
        let constrained = power.isConstrained
        let workers = options.workers(constrained: constrained)
        ExtractionLanes.ocr.setWidth(options.ocrLanes(constrained: constrained))
        queueExhausted = false
        activePools += 1
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workers {
                group.addTask { [weak self] in
                    while let self, !Task.isCancelled, let record = await self.claimNext() {
                        _ = await self.pipelineSnapshot().process(record)
                        await self.finished(record.id)
                    }
                }
            }
        }
        activePools -= 1
        guard activePools == 0 else { return }
        // Return anything prefetched but not started (pause or cancel) to the queue.
        let unstarted = prefetched
        prefetched.removeAll()
        for record in unstarted {
            inFlight.remove(record.id)
            try? await writer.release(record.id)
        }
    }

    private func pipelineSnapshot() -> FilePipeline { pipeline }

    private func finished(_ id: FileID) async {
        inFlight.remove(id)
        await publishStatus()
    }

    /// The next file for a worker, or `nil` when the worker should stop (queue empty, paused,
    /// item limit reached).
    private func claimNext() async -> FileRecord? {
        while true {
            if Task.isCancelled || userPaused || power.pauseReason() != nil { return nil }
            if !prefetched.isEmpty { return prefetched.removeFirst() }
            if queueExhausted { return nil }
            // One refill at a time; it clears `refill` itself before finishing, so waiters never
            // spin on a completed task.
            let task = refill ?? Task { await self.refillQueue() }
            refill = task
            await task.value
        }
    }

    /// Claims the next few files in queue order, skipping files already in flight.
    private func refillQueue() async {
        defer { refill = nil }
        let gate = features.current
        var limit = max(2, options.concurrentFiles * 2)
        if let itemLimit = gate.itemLimit {
            let indexed = (try? await writer.counts().totalIndexed) ?? 0
            let remaining = itemLimit - indexed - inFlight.count
            if remaining <= 0 {
                if indexed >= itemLimit { setPhase(.paused(.itemLimitReached)) }
                queueExhausted = true
                return
            }
            limit = min(limit, remaining)
        }
        var kinds = Set(MediaKind.allCases.filter { gate.allows($0) })
        if options.videoOnlyOnPower, power.isOnBattery { kinds.remove(.video) }
        let claimed = (try? await writer.claimPending(limit: limit, kinds: kinds, excluding: inFlight)) ?? []
        if claimed.isEmpty {
            queueExhausted = true
            return
        }
        for record in claimed { inFlight.insert(record.id) }
        prefetched.append(contentsOf: claimed)
    }

    private func waitForWake(timeout: Duration? = nil) async {
        if wakePending {
            wakePending = false
            return
        }
        let timer = timeout.map { duration in
            Task { [weak self] in
                try? await Task.sleep(for: duration)
                await self?.wake()
            }
        }
        await withCheckedContinuation { wakeContinuation = $0 }
        timer?.cancel()
    }

    private func wake() {
        if let continuation = wakeContinuation {
            wakeContinuation = nil
            continuation.resume()
        } else {
            wakePending = true
        }
    }

    // MARK: Scanning and watching

    private func rescanAllSources() async {
        setPhase(.scanning)
        await publishStatus(force: true)
        let sources = (try? await writer.sources()) ?? []
        var inaccessible = 0
        for source in sources where !(await rescan(sourceID: source.id, root: source.path)) {
            inaccessible += 1
        }
        inaccessibleSources = inaccessible
        setPhase(.idle)
    }

    /// Reconciles one source (or a folder inside it). Returns false when the root is not
    /// readable; an unplugged drive must never look like "every file was deleted".
    @discardableResult
    private func rescan(sourceID: SourceID, root: String, scope: String? = nil) async -> Bool {
        if PhotosLibraryPath.isLibrary(root) { return await rescanPhotos(sourceID: sourceID) }
        guard FileManager.default.isReadableFile(atPath: root) else { return false }
        let scanner = FileScanner(exclusions: rules)
        let target = URL(fileURLWithPath: scope ?? root)
        let scanned = await Task.detached(priority: .utility) { (try? scanner.scan(target)) ?? [] }.value
        guard let result = try? await writer.reconcile(sourceID: sourceID, scanned: scanned, scope: scope) else { return true }
        await apply(result)
        return true
    }

    private func restartWatcher() async {
        let paths = ((try? await writer.sources()) ?? []).map(\.path).filter { !PhotosLibraryPath.isLibrary($0) }
        watcher.watch(paths, latency: options.watcherLatency)
    }

    private func handle(_ change: FileSystemChange) async {
        let sources = (try? await writer.sources()) ?? []
        func source(for path: String) -> SourceRecord? {
            sources.filter { path == $0.path || path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
                .max { $0.path.count < $1.path.count }
        }
        for root in change.rescanRoots.map(FileScanner.canonicalPath) {
            if let owner = source(for: root) {
                await rescan(sourceID: owner.id, root: owner.path, scope: root == owner.path ? nil : root)
            }
        }

        let scanner = FileScanner(exclusions: rules)
        var upserts: [(SourceID, ScannedFile)] = []
        var removed: [String] = []
        for path in change.paths.map(FileScanner.canonicalPath).sorted() {
            guard let owner = source(for: path) else { continue }
            var isDirectory: ObjCBool = false
            if rules.excludes(path: path) || !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
                removed.append(path)
            } else if isDirectory.boolValue {
                let files = (try? scanner.scan(URL(fileURLWithPath: path))) ?? []
                upserts += files.map { (owner.id, $0) }
            } else if let file = scanner.scannedFile(at: URL(fileURLWithPath: path)) {
                upserts.append((owner.id, file))
            }
        }
        guard !upserts.isEmpty || !removed.isEmpty,
            let result = try? await writer.applyChanges(upserts: upserts, removedPaths: removed)
        else { return }
        await apply(result)
    }

    private func apply(_ result: IndexWriter.ReconcileResult) async {
        for id in result.removed { try? await vectorIndex.remove(fileID: id) }
        for moved in result.moved { await vectorIndex.updateAttributes(moved.attributes, for: moved.id) }
        if result.added + result.changed > 0 { wake() }
        if !result.isEmpty { await publishStatus() }
    }

    // MARK: Status

    private func setPhase(_ newPhase: IndexStatus.Phase) {
        phase = newPhase
    }

    private func publishStatus(force: Bool = false) async {
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

    // MARK: Photos library

    /// Adds the Photos library as a source (Pro). Asks for Photos access the first time.
    private func addPhotosLibrary() async throws -> SourceInfo {
        guard features.current.allows(.photosLibrary) else { throw EntitlementError.photosLibraryRequiresPro }
        guard let photos else { throw IndexerError.sourceUnreadable }
        var status = photos.authorizationStatus()
        if status == .notDetermined { status = await photos.requestAuthorization() }
        guard status == .authorized else { throw IndexerError.sourceUnreadable }

        let id = try await writer.addSource(path: PhotosLibraryPath.library, bookmark: nil)
        await rescanPhotos(sourceID: id)
        startObservingPhotos()
        wake()
        return try await sources().first { $0.id == id }
            ?? SourceInfo(id: id, path: PhotosLibraryPath.library, isExternalVolume: false, isAccessible: true, itemCount: 0)
    }

    /// Lists local assets and reconciles them like a folder scan. Returns false when Photos
    /// access is unavailable; the existing rows are kept, never treated as deleted.
    @discardableResult
    private func rescanPhotos(sourceID: SourceID) async -> Bool {
        guard let photos, photos.authorizationStatus() == .authorized,
            let assets = try? await photos.localAssets()
        else { return false }
        let scanned = assets.map { asset in
            ScannedFile(path: asset.path, kind: asset.kind, contentType: asset.contentType, size: asset.size, modified: asset.modified)
        }
        if let result = try? await writer.reconcile(sourceID: sourceID, scanned: scanned) { await apply(result) }
        return true
    }

    /// Re-scans the library when Photos reports a change, while it is a source.
    private func startObservingPhotos() {
        guard photosTask == nil, let photos else { return }
        // Subscribe before spawning the task so no change between now and its start is missed.
        let changes = photos.changes()
        photosTask = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                await self.rescanPhotosIfSource()
            }
        }
    }

    private func rescanPhotosIfSource() async {
        guard let source = try? await writer.sources().first(where: { PhotosLibraryPath.isLibrary($0.path) }) else { return }
        await rescanPhotos(sourceID: source.id)
    }

    private func isAccessible(_ path: String) -> Bool {
        if PhotosLibraryPath.isLibrary(path) { return photos?.authorizationStatus() == .authorized }
        return FileManager.default.isReadableFile(atPath: path)
    }
}
