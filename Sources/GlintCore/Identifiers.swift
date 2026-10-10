import Foundation

/// Stable identifier of an indexed file (the `files` table row id).
public struct FileID: RawRepresentable, Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
    public init(_ rawValue: Int64) { self.rawValue = rawValue }
    public static func < (lhs: FileID, rhs: FileID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "file#\(rawValue)" }
}

/// Stable identifier of a chunk (the `chunks` table row id).
public struct ChunkID: RawRepresentable, Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
    public init(_ rawValue: Int64) { self.rawValue = rawValue }
    public static func < (lhs: ChunkID, rhs: ChunkID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "chunk#\(rawValue)" }
}

/// Stable identifier of a user-chosen source folder or drive.
public struct SourceID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
    public init(_ rawValue: Int64) { self.rawValue = rawValue }
    public var description: String { "source#\(rawValue)" }
}
