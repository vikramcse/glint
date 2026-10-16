import CryptoKit
import Foundation
import GlintCore
import GlintStore

/// A record resolved to a file on disk the extractors can read.
struct ResolvedFile {
    var fileRef: FileRef
    /// Precomputed content hash (Photos assets); `nil` means hash the file.
    var contentHash: String?
    /// A temporary copy to delete once the file is indexed.
    var temporaryCopy: URL?
}

extension FilePipeline {
    /// Resolves `record` to a readable file, or `nil` when a folder file vanished.
    /// Photos assets are exported to a temporary copy without network access, so iCloud-only
    /// originals fail here instead of being downloaded.
    func resolve(_ record: FileRecord) async throws -> ResolvedFile? {
        if RemotePath.isRemote(record.path) { return try await resolveRemote(record) }
        guard let identifier = PhotosLibraryPath.assetIdentifier(fromPath: record.path) else {
            guard FileManager.default.fileExists(atPath: record.path) else { return nil }
            return ResolvedFile(fileRef: record.fileRef, contentHash: nil, temporaryCopy: nil)
        }
        guard let photos else { throw CocoaError(.fileReadUnsupportedScheme) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glint-photos-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let exported: URL
        do {
            exported = try await photos.exportOriginal(assetIdentifier: identifier, to: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        var fileRef = record.fileRef
        fileRef.url = exported
        return ResolvedFile(fileRef: fileRef, contentHash: Self.photoHash(record, identifier: identifier), temporaryCopy: directory)
    }

    /// Identity of an asset version: re-indexed when Photos reports an edit (new modification date).
    static func photoHash(_ record: FileRecord, identifier: String) -> String {
        let digest = SHA256.hash(data: Data("\(identifier)|\(record.modified.timeIntervalSince1970)|\(record.size)".utf8))
        return "p" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
