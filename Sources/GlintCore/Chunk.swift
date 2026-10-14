import CoreGraphics
import Foundation

/// Where a chunk sits inside its file. Drives "open at" behavior and result display.
public enum ChunkLocator: Sendable, Hashable, Codable {
    /// The whole file (an image, a short document).
    case whole
    /// A character range of a text document, in `Character` offsets of the extracted text.
    case text(start: Int, end: Int)
    /// A zero-based PDF page.
    case page(Int)
    /// A time window of an audio or video file, in seconds.
    case time(start: Double, end: Double)

    public var pageIndex: Int? {
        if case .page(let index) = self { index } else { nil }
    }

    public var timeRange: ClosedRange<Double>? {
        if case .time(let start, let end) = self { start...max(start, end) } else { nil }
    }
}

/// Display data generated at index time so the results view never decodes a full file.
public struct ChunkPreview: Sendable {
    /// Image to cache as this chunk's thumbnail (keyframe, page render, photo).
    public var thumbnail: CGImage?
    /// Cache key suffix for the thumbnail. Chunks that share a key share one cached image
    /// (for example several text chunks of the same PDF page).
    public var thumbnailKey: String?
    /// Whole-file waveform (0...1 peaks), attached to the first chunk of audio and video files.
    public var waveform: [Float]?
    /// Media duration in seconds, attached to the first chunk of audio and video files.
    public var duration: Double?

    public init(thumbnail: CGImage? = nil, thumbnailKey: String? = nil, waveform: [Float]? = nil, duration: Double? = nil) {
        self.thumbnail = thumbnail
        self.thumbnailKey = thumbnailKey
        self.waveform = waveform
        self.duration = duration
    }

    public static let none = ChunkPreview()
}

/// One searchable unit produced by a `ContentExtractor`.
public struct Chunk: Sendable {
    /// Position of the chunk within its file, starting at 0.
    public var ordinal: Int
    public var locator: ChunkLocator
    /// Text that goes into the keyword index and snippets (document text, OCR, transcript).
    public var text: String?
    /// What to embed. `nil` makes this a keyword-only chunk.
    public var input: EmbeddingInput?
    public var preview: ChunkPreview

    public init(
        ordinal: Int,
        locator: ChunkLocator,
        text: String? = nil,
        input: EmbeddingInput? = nil,
        preview: ChunkPreview = .none
    ) {
        self.ordinal = ordinal
        self.locator = locator
        self.text = text
        self.input = input
        self.preview = preview
    }
}
