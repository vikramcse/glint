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
    func rescan(sourceID: SourceID, root: String, scope: String? = nil) async -> Bool {
        if PhotosLibraryPath.isLibrary(root) { return await rescanPhotos(sourceID: sourceID) }
        guard FileManager.default.isReadableFile(atPath: root) else { return false }
        let scanner = FileScanner(exclusions: rules)
        let target = URL(fileURLWithPath: scope ?? root)
        let scanned = await Task.detached(priority: .utility) { (try? scanner.scan(target)) ?? [] }.value
        guard let result = try? await writer.reconcile(sourceID: sourceID, scanned: scanned, scope: scope) else { return true }
        await apply(result)
        return true
    }

    func restartWatcher() async {
        let paths = ((try? await writer.sources()) ?? []).map(\.path).filter { !PhotosLibraryPath.isLibrary($0) }
        watcher.watch(paths, latency: options.watcherLatency)
    }

    func handle(_ change: FileSystemChange) async {
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

    func apply(_ result: IndexWriter.ReconcileResult) async {
        for id in result.removed { try? await vectorIndex.remove(fileID: id) }
        for moved in result.moved { await vectorIndex.updateAttributes(moved.attributes, for: moved.id) }
        if result.added + result.changed > 0 { wake() }
        if !result.isEmpty { await publishStatus() }
    }
}
