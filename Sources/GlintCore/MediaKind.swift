import Foundation
import UniformTypeIdentifiers

/// The five kinds of media Glint indexes. Every file maps to exactly one kind.
public enum MediaKind: String, Sendable, Codable, CaseIterable, Hashable, Comparable {
    case image
    case video
    case audio
    case pdf
    case document

    /// Classifies a content type, or returns `nil` when Glint does not index it.
    public init?(contentType: UTType) {
        if contentType.conforms(to: .pdf) {
            self = .pdf
        } else if contentType.conforms(to: .image) {
            self = .image
        } else if contentType.conforms(to: .movie) || contentType.conforms(to: .video) {
            self = .video
        } else if contentType.conforms(to: .audio) {
            self = .audio
        } else if MediaKind.documentTypes.contains(where: { contentType.conforms(to: $0) }) {
            self = .document
        } else {
            return nil
        }
    }

    /// Content types treated as text documents.
    public static let documentTypes: [UTType] = {
        var types: [UTType] = [.plainText, .text, .sourceCode, .json, .xml, .yaml, .rtf, .rtfd, .html, .commaSeparatedText]
        for identifier in [
            "net.daringfireball.markdown",
            "org.openxmlformats.wordprocessingml.document",
            "com.microsoft.word.doc",
            "org.oasis-open.opendocument.text",
            "com.apple.pages.pages",
        ] {
            if let type = UTType(identifier) { types.append(type) }
        }
        return types
    }()

    /// Order in which the indexer works through pending files: cheap, high-value media first.
    public var indexingPriority: Int {
        switch self {
        case .document, .image, .pdf: 0
        case .audio: 1
        case .video: 2
        }
    }

    /// The feature a user needs to search this kind, if any.
    public var requiredFeature: Feature? {
        switch self {
        case .video: .videoSearch
        case .audio: .audioSearch
        case .image, .pdf, .document: nil
        }
    }

    public static func < (lhs: MediaKind, rhs: MediaKind) -> Bool {
        lhs.sortIndex < rhs.sortIndex
    }

    private var sortIndex: Int {
        switch self {
        case .image: 0
        case .video: 1
        case .audio: 2
        case .pdf: 3
        case .document: 4
        }
    }
}
