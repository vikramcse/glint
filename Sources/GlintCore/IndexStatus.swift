import Foundation

/// A folder or drive the user asked Glint to index, with its indexing progress.
public struct SourceInfo: Sendable, Hashable, Identifiable, Codable {
    public var id: SourceID
    public var path: String
    public var isExternalVolume: Bool
    /// On a network share (SMB, NFS, AFP). When it is not accessible, the share is disconnected.
    public var isNetworkVolume: Bool
    public var isAccessible: Bool
    /// Where a remote source (an S3 bucket) lives; `nil` for folders and Photos.
    public var remote: RemoteSourceConfig?
    /// Indexable files found in the folder.
    public var itemCount: Int
    /// Files whose content is searchable.
    public var indexed: Int
    /// Files waiting to be indexed.
    public var pending: Int
    /// Files that could not be read.
    public var failed: Int

    public init(
        id: SourceID, path: String, isExternalVolume: Bool, isNetworkVolume: Bool = false, isAccessible: Bool,
        itemCount: Int, indexed: Int = 0, pending: Int = 0, failed: Int = 0, remote: RemoteSourceConfig? = nil
    ) {
        self.remote = remote
        self.id = id
        self.path = path
        self.isExternalVolume = isExternalVolume
        self.isNetworkVolume = isNetworkVolume
        self.isAccessible = isAccessible
        self.itemCount = itemCount
        self.indexed = indexed
        self.pending = pending
        self.failed = failed
    }

    public var url: URL {
        if isPhotosLibrary { return PhotosLibraryPath.libraryURL }
        if remote != nil { return URL(string: path) ?? URL(fileURLWithPath: "/") }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    public var displayName: String {
        if isPhotosLibrary { return String(localized: "Photos Library") }
        return remote?.displayName ?? url.lastPathComponent
    }
    /// The Apple Photos library rather than a folder.
    public var isPhotosLibrary: Bool { PhotosLibraryPath.isLibrary(path) }

    /// Every file that can be indexed now has been.
    public var isComplete: Bool { pending == 0 }

    /// Fraction of indexable files that are done.
    public var progress: Double {
        let total = indexed + pending
        return total == 0 ? 1 : Double(indexed) / Double(total)
    }
}

/// Folders, extensions and hidden files the indexer must skip. Applied before extraction.
public struct ExclusionRules: Sendable, Hashable, Codable {
    public var folders: [String]
    public var fileExtensions: Set<String>
    public var includeHiddenFiles: Bool

    public init(folders: [String] = [], fileExtensions: Set<String> = [], includeHiddenFiles: Bool = false) {
        self.folders = folders
        self.fileExtensions = fileExtensions
        self.includeHiddenFiles = includeHiddenFiles
    }

    /// Directory names never worth indexing.
    public static let builtInFolderNames: Set<String> = [
        "node_modules", ".git", ".svn", ".hg", "DerivedData", ".build", "Pods", "__pycache__", ".Trash", "Caches",
    ]

    /// Path fragments always skipped: Glint's own derived data and system caches.
    public static let builtInPathFragments: [String] = [
        "/Library/Application Support/Glint/", "/Library/Caches/", "/Library/Containers/", "/Library/Group Containers/",
    ]

    public static let `default` = ExclusionRules()

    public func excludes(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        if fileExtensions.contains(url.pathExtension.lowercased()) { return true }
        if !includeHiddenFiles, url.pathComponents.contains(where: { $0.hasPrefix(".") && $0.count > 1 }) {
            return true
        }
        if url.pathComponents.contains(where: ExclusionRules.builtInFolderNames.contains) { return true }
        if ExclusionRules.builtInPathFragments.contains(where: { path.contains($0) }) { return true }
        return folders.contains { folder in
            let prefix = folder.hasSuffix("/") ? folder : folder + "/"
            return path == folder || path.hasPrefix(prefix)
        }
    }
}

/// Why indexing is not running.
public enum PauseReason: String, Sendable, Hashable, Codable {
    case user
    case lowBattery
    case lowPowerMode
    case thermal
}

/// Honest, user-facing state of the index.
public struct IndexStatus: Sendable, Hashable {
    public enum Phase: Sendable, Hashable {
        case idle
        case scanning
        case indexing
        case paused(PauseReason)
    }

    public var phase: Phase
    /// Indexed files per kind.
    public var indexed: [MediaKind: Int]
    /// Files waiting to be indexed.
    public var pending: Int
    /// Files that could not be read.
    public var failed: Int
    /// Number of sources, and how many are currently unreadable (permission denied, unplugged).
    public var sourceCount: Int
    public var inaccessibleSources: Int

    public init(
        phase: Phase = .idle,
        indexed: [MediaKind: Int] = [:],
        pending: Int = 0,
        failed: Int = 0,
        sourceCount: Int = 0,
        inaccessibleSources: Int = 0
    ) {
        self.phase = phase
        self.indexed = indexed
        self.pending = pending
        self.failed = failed
        self.sourceCount = sourceCount
        self.inaccessibleSources = inaccessibleSources
    }

    public var totalIndexed: Int { indexed.values.reduce(0, +) }

    /// Fraction done.
    public var progress: Double {
        let total = totalIndexed + pending
        return total == 0 ? 1 : Double(totalIndexed) / Double(total)
    }

    public var isBusy: Bool {
        switch phase {
        case .scanning, .indexing: true
        case .idle, .paused: false
        }
    }
}
