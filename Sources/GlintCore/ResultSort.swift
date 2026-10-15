import Foundation

/// How results and library views are ordered.
public struct ResultSort: Sendable, Hashable, Codable {
    public enum Field: String, Sendable, Hashable, Codable, CaseIterable {
        /// Best match first (search results only; the library falls back to newest first).
        case relevance
        case modified
        case name
        case size
        case kind
        /// Length of audio and video; files without one come last.
        case duration
    }

    public var field: Field
    public var ascending: Bool

    public init(field: Field, ascending: Bool? = nil) {
        self.field = field
        self.ascending = ascending ?? field.defaultAscending
    }

    public static let relevance = ResultSort(field: .relevance)
    public static let newestFirst = ResultSort(field: .modified)
}

extension ResultSort.Field {
    /// The direction a field reads most naturally in: names A to Z, dates newest first, sizes largest first.
    public var defaultAscending: Bool {
        switch self {
        case .name, .kind: true
        case .relevance, .modified, .size, .duration: false
        }
    }
}
