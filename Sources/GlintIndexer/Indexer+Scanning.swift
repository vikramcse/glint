import Foundation
import GlintCore
import GlintEmbedding
import GlintExtractors
import GlintStore

// MARK: Scanning and watching

extension Indexer {
    func rescanAllSources() async {
        setPhase(.scanning)
        await publishStatus(force: true)
        // Remote sources are listed in the background (`pollSources`) so a slow service never
        // holds up launch.
        let sources = ((try? await writer.sources()) ?? []).filter { $0.remote == nil }
        var inaccessible = 0
        for source in sources where !(await rescan(sourceID: source.id, root: source.path)) {
            inaccessible += 1
        }
        inaccessibleSources = inaccessible
        setPhase(.idle)
    }

    /// Reconciles one source (or a folder inside it). Returns false when the root is not
    /// readable; an unplugged drive or a disconnected share must never look like "every file
    /// was deleted". Such a source is marked offline until it can be read again.
    @discardableResult
    func rescan(sourceID: SourceID, root: String, scope: String? = nil) async -> Bool {
        if PhotosLibraryPath.isLibrary(root) { return await rescanPhotos(sourceID: sourceID) }
        if RemotePath.isRemote(root) { return await rescanRemote(sourceID: sourceID) }
        guard volumes.isReachable(root) else {
            setOffline(sourceID, true)
            return false
        }
        setOffline(sourceID, false)
        let scanner = FileScanner(exclusions: rules)
        let target = URL(fileURLWithPath: scope ?? root)
        let scanned: [ScannedFile]
        do {
            scanned = try await Task.detached(priority: .utility) { try scanner.scan(target) }.value
        } catch {
            guard scope != nil, !FileManager.default.fileExists(atPath: target.path) else {
                // A folder that cannot be listed (privacy denial, a drive's empty mount point) keeps its rows.
                let reason = String(describing: error)
                Log.indexer.notice("Skipping rescan of unreadable folder \(target.path, privacy: .private): \(reason, privacy: .public)")
                return false
            }
            scanned = []  // The folder inside the source was deleted or moved away.
        }
        do {
            await apply(try await writer.reconcile(sourceID: sourceID, scanned: scanned, scope: scope))
        } catch {
            Log.indexer.error("Reconciling a scan failed: \(String(describing: error), privacy: .public)")
        }
        return true
    }

    func restartWatcher() async {
        let paths = ((try? await writer.sources()) ?? []).filter(Self.isFolder).map(\.path)
        watcher.watch(paths, latency: options.watcherLatency)
    }

    func handle(_ change: FileSystemChange) async {
        let sources = (try? await writer.sources()) ?? []
        func source(for path: String) -> SourceRecord? {
            sources.filter { path == $0.path || path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
                .max { $0.path.count < $1.path.count }
        }
        let online = onlineSources(sources)
        for root in change.rescanRoots.map(FileScanner.canonicalPath) {
            if let owner = source(for: root) {
                await rescan(sourceID: owner.id, root: owner.path, scope: root == owner.path ? nil : root)
            }
        }

        let scanner = FileScanner(exclusions: rules)
        var upserts: [(SourceID, ScannedFile)] = []
        var removed: [String] = []
        for path in change.paths.map(FileScanner.canonicalPath).sorted() {
            guard let owner = source(for: path), online.contains(owner.id) else { continue }
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
        guard !upserts.isEmpty || !removed.isEmpty else { return }
        do {
            let result = try await writer.applyChanges(upserts: Self.uniqueByPath(upserts), removedPaths: removed)
            await apply(result)
        } catch {
            // The batch rolled back; the next full rescan picks these changes up.
            Log.indexer.error(
                "Applying \(change.paths.count, privacy: .public) file changes failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Folder sources that can be read now; the rest are marked offline. A share that
    /// disconnects reports its files as gone, and only a reachable source may lose files.
    private func onlineSources(_ sources: [SourceRecord]) -> Set<SourceID> {
        var online = Set<SourceID>()
        for source in sources where Self.isFolder(source) {
            if volumes.isReachable(source.path) { online.insert(source.id) } else { setOffline(source.id, true) }
        }
        return online
    }

    /// One entry per path, the last one winning. A new folder and a file inside it can arrive
    /// in the same batch, and scanning the folder lists the file again; a second insert of the
    /// same path would fail the whole batch.
    static func uniqueByPath(_ upserts: [(SourceID, ScannedFile)]) -> [(SourceID, ScannedFile)] {
        var seen = Set<String>()
        return upserts.reversed().filter { seen.insert($0.1.path).inserted }.reversed()
    }

    /// Marks a folder source offline or back online. A source coming back has pending files to claim again.
    func setOffline(_ id: SourceID, _ offline: Bool) {
        if offline {
            offlineSources.insert(id)
        } else if offlineSources.remove(id) != nil {
            Log.indexer.info("A source is reachable again")
            wake()
        }
    }

    /// Lists remote sources once at launch, then refreshes every source that FSEvents cannot
    /// watch every `networkRescanInterval` until cancelled.
    func pollSources() async {
        for source in (try? await writer.sources()) ?? [] where source.remote != nil {
            await rescanRemote(sourceID: source.id)
        }
        while !Task.isCancelled {
            guard (try? await Task.sleep(for: options.networkRescanInterval)) != nil else { return }
            await refreshSources()
        }
    }

    /// Rescans what FSEvents cannot watch: network shares (it misses changes made on other
    /// machines), remote services, and any folder that went offline or came back. The app calls
    /// this when a volume mounts or unmounts and when the Mac wakes; it also runs on a timer.
    public func refreshSources() async {
        let all = (try? await writer.sources()) ?? []
        let offlineBefore = offlineSources
        for source in all where source.remote != nil {
            await rescanRemote(sourceID: source.id)
        }
        for source in all.filter(Self.isFolder) {
            if volumes.isNetworkVolume(source.path) { networkSources.insert(source.id) }
            let reachable = volumes.isReachable(source.path)
            let wasOffline = offlineSources.contains(source.id)
            guard networkSources.contains(source.id) || wasOffline || !reachable else { continue }
            await rescan(sourceID: source.id, root: source.path)
        }
        guard offlineSources != offlineBefore else { return }
        inaccessibleSources = all.filter { !isAccessible($0) }.count
        // FSEvents cannot watch a folder that was missing when the stream started.
        await restartWatcher()
        await publishStatus(force: true)
    }

    func apply(_ result: IndexWriter.ReconcileResult) async {
        thumbnails.delete(relativePaths: result.orphanedThumbnails)
        for id in result.removed { try? await vectorIndex.remove(fileID: id) }
        for moved in result.moved { await vectorIndex.updateAttributes(moved.attributes, for: moved.id) }
        if result.added + result.changed > 0 { wake() }
        if !result.isEmpty { await publishStatus() }
    }
}
