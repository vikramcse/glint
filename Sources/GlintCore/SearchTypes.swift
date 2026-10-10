import Foundation

/// A vector plus the identity and attributes needed to search and filter it.
public struct StoredVector: Sendable {
    public var chunkID: ChunkID
    public var fileID: FileID
    public var values: [Float]
    public var attributes: FileAttributes

    public init(chunkID: ChunkID, fileID: FileID, values: [Float], attributes: FileAttributes) {
        self.chunkID = chunkID
        self.fileID = fileID
        self.values = values
        self.attributes = attributes
    }
}

/// A chunk with its similarity (or fused) score.
public struct ScoredChunk: Sendable, Hashable {
    public var chunkID: ChunkID
    public var fileID: FileID
    public var score: Float

    public init(chunkID: ChunkID, fileID: FileID, score: Float) {
        self.chunkID = chunkID
        self.fileID = fileID
        self.score = score
    }
}

/// Restricts a search by kind, modification date and folder.
public struct SearchFilter: Sendable, Hashable, Codable {
    /// Kinds to include; empty means all kinds.
    public var kinds: Set<MediaKind>
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?
    /// Folder path prefixes to include; empty means everywhere.
    public var folders: [String]
    /// Files to leave out (for example the example file in "find similar").
    public var excludedFiles: Set<FileID>

    public init(
        kinds: Set<MediaKind> = [],
        modifiedAfter: Date? = nil,
        modifiedBefore: Date? = nil,
        folders: [String] = [],
        excludedFiles: Set<FileID> = []
    ) {
        self.kinds = kinds
        self.modifiedAfter = modifiedAfter
        self.modifiedBefore = modifiedBefore
        self.folders = folders
        self.excludedFiles = excludedFiles
    }

    public static let none = SearchFilter()

    public var isEmpty: Bool {
        kinds.isEmpty && modifiedAfter == nil && modifiedBefore == nil && folders.isEmpty && excludedFiles.isEmpty
    }

    public func matches(fileID: FileID, attributes: FileAttributes) -> Bool {
        if !kinds.isEmpty, !kinds.contains(attributes.kind) { return false }
        if let modifiedAfter, attributes.modified < modifiedAfter { return false }
        if let modifiedBefore, attributes.modified >= modifiedBefore { return false }
        if !folders.isEmpty {
            let inFolder = folders.contains { folder in
                let prefix = folder.hasSuffix("/") ? folder : folder + "/"
                return attributes.path.hasPrefix(prefix)
            }
            if !inFolder { return false }
        }
        return !excludedFiles.contains(fileID)
    }
}
