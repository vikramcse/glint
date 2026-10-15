import Foundation
import GlintCore
import GlintStore
import UniformTypeIdentifiers

/// Walks a folder and lists indexable files with the metadata the queue needs. Needs no
/// model and reads no file contents, so a first scan of a large folder takes seconds.
public struct FileScanner: Sendable {
    public var exclusions: ExclusionRules

    public init(exclusions: ExclusionRules) {
        self.exclusions = exclusions
    }

    static let keys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
        .contentTypeKey, .isHiddenKey,
    ]

    /// Lists every indexable file at or below `root`. Unreadable subfolders are skipped, but a
    /// root that cannot be listed throws: an empty result means the folder really is empty.
    public func scan(_ root: URL) throws -> [ScannedFile] {
        let values = try root.resourceValues(forKeys: Set(Self.keys))
        if values.isRegularFile == true || values.isPackage == true {
            return scannedFile(root, values: values).map { [$0] } ?? []
        }
        // The enumerator reports an unlistable root (say, a privacy denial) as no items.
        _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
        if Self.isUnmountedVolume(root) { throw IndexerError.sourceUnreadable }
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !exclusions.includeHiddenFiles { options.insert(.skipsHiddenFiles) }
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Self.keys, options: options,
                errorHandler: { url, error in
                    Log.indexer.debug(
                        "Skipping unreadable item \(url.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
                    return true
                }
            )
        else { throw IndexerError.sourceUnreadable }

        var files: [ScannedFile] = []
        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            guard let values = try? url.resourceValues(forKeys: Set(Self.keys)) else { continue }
            if values.isDirectory == true, values.isPackage != true {
                if exclusions.excludes(path: Self.canonicalPath(url) + "/") { enumerator.skipDescendants() }
                continue
            }
            if let file = scannedFile(url, values: values) { files.append(file) }
        }
        return files
    }

    /// The one path form used everywhere in the index. FSEvents and directory enumeration
    /// report `/private/var/…` where Foundation standardizes to `/var/…`; this maps both to the latter.
    public static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    public static func canonicalPath(_ path: String) -> String {
        canonicalPath(URL(fileURLWithPath: path))
    }

    /// A path under `/Volumes/<name>` whose drive is not mounted: the folder left behind lies on
    /// the startup disk and is empty, which must not read as "every file was deleted".
    static func isUnmountedVolume(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let components = resolved.pathComponents
        guard components.count >= 3, components[0] == "/", components[1] == "Volumes" else { return false }
        let mountPoint = "/Volumes/" + components[2]
        guard let volume = (try? resolved.resourceValues(forKeys: [.volumeURLKey]))?.volume else { return false }
        return volume.standardizedFileURL.path != mountPoint
    }

    /// Metadata for one file, or `nil` when it is excluded or not indexable.
    public func scannedFile(at url: URL) -> ScannedFile? {
        guard let values = try? url.resourceValues(forKeys: Set(Self.keys)) else { return nil }
        return scannedFile(url, values: values)
    }

    private func scannedFile(_ url: URL, values: URLResourceValues) -> ScannedFile? {
        let path = Self.canonicalPath(url)
        guard values.isRegularFile == true, !exclusions.excludes(path: path),
            let type = values.contentType ?? UTType(filenameExtension: url.pathExtension),
            let kind = MediaKind(contentType: type)
        else { return nil }
        return ScannedFile(
            path: path,
            kind: kind,
            contentType: type,
            size: Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate ?? .distantPast
        )
    }
}
