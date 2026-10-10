import Foundation

/// Tunables for every extractor. Defaults follow the PRD extraction table.
public struct ExtractionOptions: Sendable, Hashable {
    /// Vision OCR accuracy level.
    public enum OCRLevel: String, Sendable, Hashable, Codable {
        /// Skip images without text; read screens, scans and rendered pages with the fast
        /// recognizer at `ocrMaxPixel` (99.96% of words, 5–15x faster than accurate on the
        /// benchmark corpus); use the accurate recognizer only for camera photos with text,
        /// where scene text is harder to read.
        case automatic
        case fast
        case accurate
    }

    /// Run Vision OCR on images and on PDF pages without a text layer.
    public var ocrEnabled: Bool
    public var ocrLevel: OCRLevel
    /// Long side, in pixels, of the image OCR reads. The fast recognizer needs about 2048 px
    /// for small UI text (at 1024 px it misreads most words).
    public var ocrMaxPixel: Int
    /// Transcribe audio on device (needs Speech Recognition authorization; never prompts).
    public var transcriptionEnabled: Bool

    /// Text chunk size and overlap, in approximate tokens.
    public var textChunkTokens: Int
    public var textOverlapTokens: Int
    /// Text documents larger than this throw `ExtractionError.tooLarge`.
    public var maxTextBytes: Int64

    /// PDFs are indexed up to this many pages.
    public var maxPDFPages: Int
    /// Long side, in pixels, of images handed to the embedding model.
    public var embeddingImageMaxPixel: Int
    /// Long side, in pixels, of cached thumbnails and keyframes.
    public var thumbnailMaxPixel: Int

    /// Audio windows, in seconds.
    public var audioWindow: Double
    public var audioOverlap: Double
    public var maxAudioDuration: Double

    /// Video clips, in seconds, sampled at `videoFrameRate` frames per second.
    public var videoClipDuration: Double
    public var videoFrameRate: Double
    public var videoFrameMaxPixel: Int
    public var maxVideoDuration: Double

    /// Number of peak bins in a file's waveform preview.
    public var waveformBins: Int

    public init(
        ocrEnabled: Bool = true,
        ocrLevel: OCRLevel = .automatic,
        ocrMaxPixel: Int = 2_048,
        transcriptionEnabled: Bool = false,
        textChunkTokens: Int = 512,
        textOverlapTokens: Int = 64,
        maxTextBytes: Int64 = 20 * 1_024 * 1_024,
        maxPDFPages: Int = 500,
        embeddingImageMaxPixel: Int = 1_024,
        thumbnailMaxPixel: Int = 512,
        audioWindow: Double = 10,
        audioOverlap: Double = 2,
        maxAudioDuration: Double = 4 * 3_600,
        videoClipDuration: Double = 5,
        videoFrameRate: Double = 1,
        videoFrameMaxPixel: Int = 512,
        maxVideoDuration: Double = 3 * 3_600,
        waveformBins: Int = 200
    ) {
        self.ocrEnabled = ocrEnabled
        self.ocrLevel = ocrLevel
        self.ocrMaxPixel = ocrMaxPixel
        self.transcriptionEnabled = transcriptionEnabled
        self.textChunkTokens = textChunkTokens
        self.textOverlapTokens = textOverlapTokens
        self.maxTextBytes = maxTextBytes
        self.maxPDFPages = maxPDFPages
        self.embeddingImageMaxPixel = embeddingImageMaxPixel
        self.thumbnailMaxPixel = thumbnailMaxPixel
        self.audioWindow = audioWindow
        self.audioOverlap = audioOverlap
        self.maxAudioDuration = maxAudioDuration
        self.videoClipDuration = videoClipDuration
        self.videoFrameRate = videoFrameRate
        self.videoFrameMaxPixel = videoFrameMaxPixel
        self.maxVideoDuration = maxVideoDuration
        self.waveformBins = waveformBins
    }

    public static let `default` = ExtractionOptions()

    var textChunker: TextChunker {
        TextChunker(maxTokens: textChunkTokens, overlapTokens: textOverlapTokens)
    }
}
