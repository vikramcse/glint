@preconcurrency import AVFoundation
import Foundation
import GlintCore
import UniformTypeIdentifiers

/// Extracts audio as overlapping 16 kHz mono windows, with a whole-file waveform and an
/// optional on-device transcript in the keyword index.
public struct AudioExtractor: ContentExtractor {
    public static let contentTypes: Set<UTType> = [.audio]

    public let options: ExtractionOptions
    public let transcriber: (any Transcriber)?

    /// - Parameter transcriber: used only when `options.transcriptionEnabled` is true.
    public init(options: ExtractionOptions = .default, transcriber: (any Transcriber)? = nil) {
        self.options = options
        self.transcriber = transcriber
    }

    public func chunks(of file: FileRef) -> AsyncThrowingStream<Chunk, any Error> {
        let cursor = AudioCursor(
            url: file.url, options: options, transcriber: options.transcriptionEnabled ? transcriber : nil
        )
        return lazyChunkStream { try await cursor.next() }
    }
}

/// Produces one audio window at a time, decoding only as far as the current window.
actor AudioCursor {
    private let url: URL
    private let options: ExtractionOptions
    private let transcriber: (any Transcriber)?
    private var reader: AudioStreamReader?
    private var opened = false
    private var windows: [(start: Double, end: Double)] = []
    private var nextWindow = 0
    private var waveform: [Float] = []
    private var duration: Double = 0
    private var transcript: [TranscriptSegment] = []
    private var sounds: [SoundLabel] = []
    /// Decoded samples starting at `bufferStart` (in samples from the file start).
    private var buffer: [Float] = []
    private var bufferStart = 0

    init(url: URL, options: ExtractionOptions, transcriber: (any Transcriber)?) {
        self.url = url
        self.options = options
        self.transcriber = transcriber
    }

    func next() async throws -> Chunk? {
        if !opened { try await open() }
        guard nextWindow < windows.count, let reader else { return nil }
        try Task.checkCancellation()

        let window = windows[nextWindow]
        let rate = AudioAnalysis.embeddingSampleRate
        let first = Int(window.start * rate)
        let last = Int(window.end * rate)
        let missing = last - (bufferStart + buffer.count)
        if missing > 0 { buffer += try await reader.read(missing) }

        let lower = max(0, first - bufferStart)
        let upper = min(buffer.count, last - bufferStart)
        guard lower < upper else { return nil }
        let samples = Array(buffer[lower..<upper])
        let end = window.start + Double(samples.count) / rate

        nextWindow += 1
        if nextWindow < windows.count {
            let drop = min(buffer.count, max(0, Int(windows[nextWindow].start * rate) - bufferStart))
            buffer.removeFirst(drop)
            bufferStart += drop
        } else {
            buffer = []
        }

        let clip = AudioClip(samples: samples, sampleRate: rate, start: window.start)
        let spoken = transcript.text(from: window.start, to: end)
        let heard = sounds.text(from: window.start, to: end)
        let embedded = [spoken, options.soundLabels == .embedded ? heard : nil].compactMap { $0 }
        let text = [spoken, heard].compactMap { $0 }.joined(separator: "\n")
        let isFirst = nextWindow == 1
        return Chunk(
            ordinal: nextWindow - 1,
            locator: .time(start: window.start, end: end),
            text: text.isEmpty ? nil : text,
            input: embedded.isEmpty ? .audio(clip) : .interleaved([.audio(clip), .text(embedded.joined(separator: "\n"))]),
            preview: isFirst ? ChunkPreview(waveform: waveform, duration: duration) : .none
        )
    }

    private func open() async throws {
        opened = true
        try ExtractionError.checkReadable(url)
        guard ExtractionError.fileSize(url) > 0 else { throw ExtractionError.empty }
        let asset = AVURLAsset(url: url)
        let assetDuration: CMTime
        do {
            assetDuration = try await asset.load(.duration)
        } catch {
            throw ExtractionError.corrupt
        }
        duration = assetDuration.isNumeric ? assetDuration.seconds : 0
        let capped = min(duration, options.maxAudioDuration)
        guard capped > 0 else { throw ExtractionError.corrupt }

        let rate = AudioAnalysis.embeddingSampleRate
        do {
            reader = try await AudioStreamReader.make(asset: asset, sampleRate: rate, maxDuration: capped)
        } catch let error as ExtractionError {
            throw error
        } catch {
            throw ExtractionError.corrupt
        }
        guard reader != nil else { throw ExtractionError.empty }

        windows = AudioAnalysis.windows(duration: capped, length: options.audioWindow, overlap: options.audioOverlap)
        waveform = try await AudioAnalysis.waveform(
            of: asset, duration: duration, bins: options.waveformBins, maxDuration: capped
        )
        try await listen(upTo: capped)
    }

    /// What was heard and said: sound labels and the transcript, each when enabled.
    private func listen(upTo maxDuration: Double) async throws {
        if options.soundLabels != .off {
            let url = url
            let flag = CancellationFlag()
            do {
                sounds = try await withTaskCancellationHandler {
                    try await Offload.run { try SoundLabeler.labels(of: url, maxDuration: maxDuration, isCancelled: { flag.isCancelled }) }
                } onCancel: {
                    flag.cancel()
                }
            } catch is CancellationError {
                throw ExtractionError.cancelled
            } catch {
                Log.extractor.error("Sound classification failed: \(String(describing: error), privacy: .public)")
            }
        }
        if let transcriber {
            do {
                transcript = try await transcriber.transcribe(url)
            } catch is CancellationError {
                throw ExtractionError.cancelled
            } catch {
                Log.extractor.error("Transcription failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
