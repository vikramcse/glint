import CoreGraphics
import Foundation
import GlintCore
import UniformTypeIdentifiers

/// A user-chosen folder or drive as stored.
public struct SourceRecord: Sendable, Hashable, Identifiable {
    public var id: SourceID
    public var path: String
    public var bookmark: Data?
    public var addedAt: Date
}

/// A file found by the scanner, before it has an id.
public struct ScannedFile: Sendable, Hashable {
    public var path: String
    public var kind: MediaKind
    public var contentType: UTType
    public var size: Int64
    public var modified: Date

    public init(path: String, kind: MediaKind, contentType: UTType, size: Int64, modified: Date) {
        self.path = path
        self.kind = kind
        self.contentType = contentType
        self.size = size
        self.modified = modified
    }
}

/// A row of the `files` table.
public struct FileRecord: Sendable, Hashable, Identifiable {
    public var id: FileID
    public var sourceID: SourceID
    public var path: String
    public var name: String
    public var kind: MediaKind
    public var contentType: UTType
    public var size: Int64
    public var modified: Date
    public var contentHash: String?
    public var status: FileStatus
    public var indexedAt: Date?
    /// Media duration in seconds (audio and video).
    public var duration: Double?
    /// Whole-file waveform peaks in 0...1 (audio and video).
    public var waveform: [Float]?

    public var url: URL { URL(fileURLWithPath: path) }
    public var version: FileVersion { FileVersion(size: size, modified: modified) }
    public var attributes: FileAttributes { FileAttributes(kind: kind, modified: modified, path: path) }
    public var fileRef: FileRef {
        FileRef(id: id, url: url, kind: kind, contentType: contentType, size: size, modified: modified)
    }
}

/// A row of the `chunks` table.
public struct ChunkRecord: Sendable, Hashable, Identifiable {
    public var id: ChunkID
    public var fileID: FileID
    public var ordinal: Int
    public var locator: ChunkLocator
    public var text: String?
    /// Thumbnail path relative to the thumbnail store, if one was generated.
    public var thumbnail: String?
}

/// A chunk to commit, with its vector when it was embedded.
public struct ChunkWrite: Sendable {
    public var ordinal: Int
    public var locator: ChunkLocator
    public var text: String?
    public var thumbnail: String?
    public var vector: [Float]?
    public var faces: [FaceWrite]

    public init(
        ordinal: Int, locator: ChunkLocator, text: String?, thumbnail: String?, vector: [Float]?, faces: [FaceWrite] = []
    ) {
        self.ordinal = ordinal
        self.locator = locator
        self.text = text
        self.thumbnail = thumbnail
        self.vector = vector
        self.faces = faces
    }
}

/// A face to commit with its chunk.
public struct FaceWrite: Sendable {
    /// Normalized, top-left origin.
    public var box: CGRect
    public var quality: Float
    public var print: [Float]
    /// Face crop path relative to the thumbnail store.
    public var thumbnail: String?
    /// The person it belongs to when known (a copied file); otherwise the clusterer decides.
    public var person: PersonID?

    public init(box: CGRect, quality: Float, print: [Float], thumbnail: String?, person: PersonID? = nil) {
        self.box = box
        self.quality = quality
        self.print = print
        self.thumbnail = thumbnail
        self.person = person
    }
}

/// The size and modification date a file had when it was claimed. A file still being copied
/// in is claimed half-written; results for that version must not overwrite the newer one.
public struct FileVersion: Sendable, Hashable {
    public var size: Int64
    public var modified: Date

    public init(size: Int64, modified: Date) {
        self.size = size
        self.modified = modified
    }
}

/// One file's complete index update, committed atomically (possibly with other files).
public struct FileCommit: Sendable {
    public var fileID: FileID
    public var contentHash: String
    public var space: VectorSpace
    public var chunks: [ChunkWrite]
    public var media: FileMedia
    /// The version that was indexed; the commit is dropped if the file changed since.
    public var version: FileVersion?

    public init(
        fileID: FileID, contentHash: String, space: VectorSpace, chunks: [ChunkWrite], media: FileMedia = FileMedia(),
        version: FileVersion? = nil
    ) {
        self.fileID = fileID
        self.contentHash = contentHash
        self.space = space
        self.chunks = chunks
        self.media = media
        self.version = version
    }
}

/// File-level display data committed alongside chunks.
public struct FileMedia: Sendable, Hashable {
    public var duration: Double?
    public var waveform: [Float]?

    public init(duration: Double? = nil, waveform: [Float]? = nil) {
        self.duration = duration
        self.waveform = waveform
    }
}

/// A vector committed to the store, ready to upsert into the in-memory index.
public struct CommittedVector: Sendable {
    public var chunkID: ChunkID
    public var values: [Float]
}

/// File counts per kind and status.
public struct IndexCounts: Sendable, Hashable {
    public var indexed: [MediaKind: Int] = [:]
    public var pending: [MediaKind: Int] = [:]
    public var failed: Int = 0

    public init() {}

    public var totalIndexed: Int { indexed.values.reduce(0, +) }
    public var totalPending: Int { pending.values.reduce(0, +) }
}

/// A full-text match in chunk text (OCR, transcript, document) or in a file name.
public struct KeywordHit: Sendable, Hashable {
    public var fileID: FileID
    /// `nil` for a file-name match.
    public var chunkID: ChunkID?
    /// BM25 score; lower is better, as SQLite reports it.
    public var bm25: Double
    public var attributes: FileAttributes

    public init(fileID: FileID, chunkID: ChunkID?, bm25: Double, attributes: FileAttributes) {
        self.fileID = fileID
        self.chunkID = chunkID
        self.bm25 = bm25
        self.attributes = attributes
    }
}

/// A saved search.
public struct SavedSearch: Sendable, Hashable, Identifiable, Codable {
    public var id: Int64
    public var name: String
    public var query: String
    public var filter: SearchFilter
    public var createdAt: Date

    public init(id: Int64, name: String, query: String, filter: SearchFilter, createdAt: Date) {
        self.id = id
        self.name = name
        self.query = query
        self.filter = filter
        self.createdAt = createdAt
    }
}
