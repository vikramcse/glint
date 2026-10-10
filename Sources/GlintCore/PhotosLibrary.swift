import Foundation
import UniformTypeIdentifiers

/// Paths that stand for the Apple Photos library and its assets in the index.
///
/// The library is one source (`photos://library`); each asset is a row whose path is
/// `photos://asset/<localIdentifier>/<original filename>`, so the file name shows in results
/// and the asset's stable PhotoKit identifier can be recovered.
public enum PhotosLibraryPath {
    public static let scheme = "photos"
    public static let library = "photos://library"
    static let assetPrefix = "photos://asset/"

    /// The URL passed to `IndexingService.addSource` to add the Photos library.
    public static var libraryURL: URL { URL(string: library) ?? URL(fileURLWithPath: "/") }

    public static func isLibrary(_ path: String) -> Bool { path == library }
    public static func isAsset(_ path: String) -> Bool { path.hasPrefix(assetPrefix) }

    /// The index path for an asset.
    public static func path(forAsset identifier: String, filename: String) -> String {
        let safeName = filename.isEmpty ? "Photo" : filename.replacingOccurrences(of: "/", with: "-")
        return assetPrefix + identifier + "/" + safeName
    }

    /// The PhotoKit local identifier stored in an asset path (identifiers may contain slashes).
    public static func assetIdentifier(fromPath path: String) -> String? {
        guard isAsset(path) else { return nil }
        let rest = path.dropFirst(assetPrefix.count)
        guard let slash = rest.lastIndex(of: "/") else { return nil }
        let identifier = String(rest[..<slash])
        return identifier.isEmpty ? nil : identifier
    }

    /// The original file name stored in an asset path.
    public static func filename(fromPath path: String) -> String? {
        guard isAsset(path), let slash = path.lastIndex(of: "/") else { return nil }
        return String(path[path.index(after: slash)...])
    }
}

/// Whether Glint may read the Photos library.
public enum PhotoLibraryAuthorization: Sendable, Hashable {
    case notDetermined
    case authorized
    case denied
}

/// One asset as the indexer needs it. Only assets whose originals are on this Mac are listed.
public struct PhotoAssetInfo: Sendable, Hashable {
    public var identifier: String
    public var filename: String
    public var kind: MediaKind
    public var contentType: UTType
    public var size: Int64
    public var modified: Date

    public init(identifier: String, filename: String, kind: MediaKind, contentType: UTType, size: Int64, modified: Date) {
        self.identifier = identifier
        self.filename = filename
        self.kind = kind
        self.contentType = contentType
        self.size = size
        self.modified = modified
    }

    public var path: String { PhotosLibraryPath.path(forAsset: identifier, filename: filename) }
}

/// Read-only access to the Photos library. PhotoKit in the app; a fake in tests.
public protocol PhotoLibraryProviding: Sendable {
    func authorizationStatus() -> PhotoLibraryAuthorization
    /// Asks the user once; never prompts again after a decision.
    func requestAuthorization() async -> PhotoLibraryAuthorization
    /// Photos and videos whose originals are stored locally (iCloud-only assets are skipped).
    func localAssets() async throws -> [PhotoAssetInfo]
    /// Copies an asset's original into `directory` without network access and returns its URL.
    func exportOriginal(assetIdentifier: String, to directory: URL) async throws -> URL
    /// Fires whenever the library changes.
    func changes() -> AsyncStream<Void>
}
