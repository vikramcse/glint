import CoreGraphics
import Foundation

/// Stable identifier of a person: a group of faces the clusterer believes are one individual.
public struct PersonID: RawRepresentable, Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
    public init(_ rawValue: Int64) { self.rawValue = rawValue }
    public static func < (lhs: PersonID, rhs: PersonID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "person#\(rawValue)" }
}

/// A face found in a photo or a video keyframe, with the vector that identifies whose it is.
public struct DetectedFace: Sendable {
    /// Where the face is, normalized to 0...1 with a top-left origin.
    public var box: CGRect
    /// Vision's capture quality, 0...1 (sharp, frontal, well lit is high).
    public var quality: Float
    /// Unit-length identity vector; faces of one person have a high cosine similarity.
    public var print: [Float]
    /// Square crop around the face, for the People view.
    public var crop: CGImage?

    public init(box: CGRect, quality: Float, print: [Float], crop: CGImage?) {
        self.box = box
        self.quality = quality
        self.print = print
        self.crop = crop
    }
}

/// A person as the People view lists them.
public struct PersonSummary: Sendable, Hashable, Identifiable {
    public var id: PersonID
    /// The name the user gave, or `nil` while unnamed.
    public var name: String?
    /// Photos and videos the person appears in.
    public var fileCount: Int
    /// The person's clearest face.
    public var faceThumbnailURL: URL?

    public init(id: PersonID, name: String?, fileCount: Int, faceThumbnailURL: URL?) {
        self.id = id
        self.name = name
        self.fileCount = fileCount
        self.faceThumbnailURL = faceThumbnailURL
    }
}
