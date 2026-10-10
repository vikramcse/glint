import Foundation
import GlintCore
import UniformTypeIdentifiers

/// Routes a content type to the extractor that handles it.
///
/// Extractors are consulted in order, so more specific ones (PDF) come before broad ones (text).
public struct ExtractorRegistry: Sendable {
    public let extractors: [any ContentExtractor]

    public init(extractors: [any ContentExtractor]) {
        self.extractors = extractors
    }

    /// The first extractor whose content types `type` conforms to, or `nil` when unsupported.
    public func extractor(for type: UTType) -> (any ContentExtractor)? {
        extractors.first { $0.canExtract(type) }
    }

    /// Whether any extractor handles `type`.
    public func supports(_ type: UTType) -> Bool {
        extractor(for: type) != nil
    }

    /// Every built-in extractor: PDF, image, video, audio, then text.
    ///
    /// - Parameter transcriber: on-device transcriber for audio and video; used only when
    ///   `options.transcriptionEnabled` is true. Defaults to `OnDeviceSpeechTranscriber`.
    public static func standard(
        options: ExtractionOptions = .default,
        transcriber: (any Transcriber)? = OnDeviceSpeechTranscriber()
    ) -> ExtractorRegistry {
        ExtractorRegistry(extractors: [
            PDFExtractor(options: options),
            ImageExtractor(options: options),
            VideoExtractor(options: options, transcriber: transcriber),
            AudioExtractor(options: options, transcriber: transcriber),
            TextExtractor(options: options),
        ])
    }
}
