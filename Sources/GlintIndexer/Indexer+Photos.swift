import Foundation
import GlintCore
import GlintEmbedding
import GlintExtractors
import GlintStore

// MARK: Photos library

extension Indexer {
    /// Adds the Photos library as a source. Asks for Photos access the first time.
    func addPhotosLibrary() async throws -> SourceInfo {
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
    func rescanPhotos(sourceID: SourceID) async -> Bool {
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
    func startObservingPhotos() {
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

    func isAccessible(_ source: SourceRecord) -> Bool {
        if PhotosLibraryPath.isLibrary(source.path) { return photos?.authorizationStatus() == .authorized }
        if source.remote != nil { return !offlineSources.contains(source.id) }
        return volumes.isReachable(source.path)
    }

    /// A folder on a disk or share, rather than the Photos library or a remote service.
    static func isFolder(_ source: SourceRecord) -> Bool {
        source.remote == nil && !PhotosLibraryPath.isLibrary(source.path)
    }
}
