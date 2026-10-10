import Foundation
import UniformTypeIdentifiers

/// A file Glint knows about, as handed to extractors.
public struct FileRef: Sendable, Hashable {
    public var id: FileID
    public var url: URL
    public var kind: MediaKind
    public var contentType: UTType
    public var size: Int64
    public var modified: Date

    public init(id: FileID, url: URL, kind: MediaKind, contentType: UTType, size: Int64, modified: Date) {
        self.id = id
        self.url = url
        self.kind = kind
        self.contentType = contentType
        self.size = size
        self.modified = modified
    }

    public var name: String { url.lastPathComponent }
}

/// The file attributes the search path needs to filter vectors without touching the database.
public struct FileAttributes: Sendable, Hashable, Codable {
    public var kind: MediaKind
    public var modified: Date
    public var path: String

    public init(kind: MediaKind, modified: Date, path: String) {
        self.kind = kind
        self.modified = modified
        self.path = path
    }
}
