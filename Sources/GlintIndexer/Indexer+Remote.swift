import Foundation
import GlintCore
import GlintStore
import UniformTypeIdentifiers

// MARK: Remote sources (S3 buckets)

extension Indexer: RemoteFileFetching {
    public func addRemoteSource(_ config: RemoteSourceConfig, secret: String?) async throws -> SourceInfo {
        guard let remotes else { throw RemoteStorageError.misconfigured("Remote sources aren’t available.") }
        // Connecting checks the endpoint, bucket and key before anything is stored.
        let connected = try await remotes.storage(for: config, secret: secret).connect()
        let path = connected.rootPath
        if let found = try await writer.sources().first(where: { $0.path == path }) {
            return try await sources().first { $0.id == found.id } ?? placeholder(found.id, path, connected)
        }
        if let secret { try remotes.saveSecret(secret, credentialID: connected.credentialID) }
        let id: SourceID
        do {
            id = try await writer.addSource(path: path, bookmark: nil, remote: connected)
        } catch {
            if secret != nil { remotes.deleteSecret(credentialID: connected.credentialID) }
            throw error
        }
        await rescanRemote(sourceID: id)
        wake()
        return try await sources().first { $0.id == id } ?? placeholder(id, path, connected)
    }

    public func checkRemoteSource(_ config: RemoteSourceConfig, secret: String?) async throws -> Int {
        guard let remotes else { throw RemoteStorageError.misconfigured("Remote sources aren’t available.") }
        let storage = try remotes.storage(for: config, secret: secret)
        let connected = try await storage.connect()
        let listing = try await remotes.storage(for: connected, secret: secret).list()
        return scannedFiles(listing, root: connected.rootPath).count
    }

    public func downloadRemoteFile(path: String, to directory: URL) async throws -> URL {
        guard let remotes else { throw RemoteStorageError.misconfigured("Remote sources aren’t available.") }
        let sources = try await writer.sources()
        guard
            let source = sources.filter({ $0.remote != nil && RemotePath.key(of: path, inRoot: $0.path) != nil })
                .max(by: { $0.path.count < $1.path.count }),
            let config = source.remote, let key = RemotePath.key(of: path, inRoot: source.path)
        else { throw RemoteStorageError.notFound(path) }
        return try await remotes.storage(for: config, secret: nil).download(key: key, to: directory)
    }

    /// Lists a remote source and reconciles it like a folder scan. Any failure (offline, signed
    /// out, the folder was renamed) keeps the existing rows and marks the source offline.
    @discardableResult
    func rescanRemote(sourceID: SourceID) async -> Bool {
        guard let remotes, let source = try? await writer.sources().first(where: { $0.id == sourceID }),
            let config = source.remote
        else { return false }
        guard rescanningRemote.insert(sourceID).inserted else { return !offlineSources.contains(sourceID) }
        defer { rescanningRemote.remove(sourceID) }
        let listing: [RemoteObject]
        do {
            listing = try await remotes.storage(for: config, secret: nil).list()
        } catch {
            Log.indexer.notice("Can’t list a remote source: \(String(describing: error), privacy: .public)")
            setOffline(sourceID, true)
            return false
        }
        setOffline(sourceID, false)
        do {
            await apply(try await writer.reconcile(sourceID: sourceID, scanned: scannedFiles(listing, root: source.path)))
        } catch {
            Log.indexer.error("Reconciling a remote listing failed: \(String(describing: error), privacy: .public)")
        }
        return true
    }

    /// Indexable files of a listing, after exclusions.
    func scannedFiles(_ objects: [RemoteObject], root: String) -> [ScannedFile] {
        objects.compactMap { object in
            let path = root + "/" + object.key
            let fileExtension = (object.name as NSString).pathExtension
            guard !rules.excludes(path: path),
                let type = UTType(filenameExtension: fileExtension),
                let kind = MediaKind(contentType: type)
            else { return nil }
            return ScannedFile(path: path, kind: kind, contentType: type, size: object.size, modified: object.modified)
        }
    }

    private func placeholder(_ id: SourceID, _ path: String, _ config: RemoteSourceConfig) -> SourceInfo {
        SourceInfo(id: id, path: path, isExternalVolume: false, isAccessible: true, itemCount: 0, remote: config)
    }
}

extension FilePipeline {
    /// Downloads a remote file to a temporary folder. A file deleted remotely resolves to `nil`.
    func resolveRemote(_ record: FileRecord) async throws -> ResolvedFile? {
        guard let remotes else { throw RemoteStorageError.misconfigured("Remote sources aren’t available.") }
        guard let source = try await writer.sources().first(where: { $0.id == record.sourceID }), let config = source.remote,
            let key = RemotePath.key(of: record.path, inRoot: source.path)
        else { return nil }
        guard record.size <= options.maxRemoteFileSize else { throw CocoaError(.fileReadTooLarge) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glint-remote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let downloaded: URL
        do {
            downloaded = try await remotes.storage(for: config, secret: nil).download(key: key, to: directory)
        } catch RemoteStorageError.notFound {
            try? FileManager.default.removeItem(at: directory)
            return nil
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        var fileRef = record.fileRef
        fileRef.url = downloaded
        return ResolvedFile(fileRef: fileRef, contentHash: nil, temporaryCopy: directory)
    }
}
