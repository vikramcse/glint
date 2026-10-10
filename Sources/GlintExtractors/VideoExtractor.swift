@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import GlintCore
import UniformTypeIdentifiers

/// Extracts video as fixed clips sampled at 1 frame per second, each with its slice of the
/// audio track and a keyframe thumbnail. Files without a video track are handled as audio.
public struct VideoExtractor: ContentExtractor {
    public static let contentTypes: Set<UTType> = [.movie]

    public let options: ExtractionOptions
    public let transcriber: (any Transcriber)?

    public init(options: ExtractionOptions = .default, transcriber: (any Transcriber)? = nil) {
        self.options = options
        self.transcriber = transcriber
    }

    public func chunks(of file: FileRef) -> AsyncThrowingStream<Chunk, any Error> {
        let cursor = VideoCursor(
            url: file.url, options: options, transcriber: options.transcriptionEnabled ? transcriber : nil
        )
        return lazyChunkStream { try await cursor.next() }
    }
}

/// Produces one clip at a time so at most one clip's frames are in memory.
actor VideoCursor {
    private let url: URL
    private let options: ExtractionOptions
    private let transcriber: (any Transcriber)?
    private var opened = false
    private var audioFallback: AudioCursor?
    private var generator: AVAssetImageGenerator?
    private var audioReader: AudioStreamReader?
    private var clips: [(start: Double, end: Double)] = []
    private var nextClip = 0
    private var duration: Double = 0
    private var waveform: [Float] = []
    private var transcript: [TranscriptSegment] = []
    private var audioBuffer: [Float] = []
    private var audioBufferStart = 0

    init(url: URL, options: ExtractionOptions, transcriber: (any Transcriber)?) {
        self.url = url
        self.options = options
        self.transcriber = transcriber
    }

    func next() async throws -> Chunk? {
        if !opened { try await open() }
        if let audioFallback { return try await audioFallback.next() }
        guard nextClip < clips.count, let generator else { return nil }
        try Task.checkCancellation()

        let clip = clips[nextClip]
        let frames = try await Self.frames(of: generator, from: clip.start, to: clip.end, rate: options.videoFrameRate)
        let audio = try await audioSlice(from: clip.start, to: clip.end)
        nextClip += 1
        guard !frames.isEmpty else {
            return nextClip < clips.count ? try await next() : nil
        }

        let keyframe = ImageProcessing.scaled(frames[frames.count / 2], maxPixel: options.thumbnailMaxPixel)
        let isFirst = nextClip == 1
        var preview = ChunkPreview(thumbnail: keyframe, thumbnailKey: "t\(Int(clip.start))")
        if isFirst {
            preview.waveform = waveform
            preview.duration = duration
        }
        let videoClip = VideoClip(frames: frames, audio: audio, start: clip.start, end: clip.end)
        let spoken = transcript.text(from: clip.start, to: clip.end)
        let middle = frames[frames.count / 2]
        let tags = options.visualTagsEnabled ? try await Offload.run { VisualTagger().tags(for: middle) } : []
        return Chunk(
            ordinal: nextClip - 1,
            locator: .time(start: clip.start, end: clip.end),
            text: spoken,
            tags: tags,
            input: spoken.map { .interleaved([.video(videoClip), .text($0)]) } ?? .video(videoClip),
            preview: preview
        )
    }

    private func open() async throws {
        opened = true
        try ExtractionError.checkReadable(url)
        guard ExtractionError.fileSize(url) > 0 else { throw ExtractionError.empty }
        let asset = AVURLAsset(url: url)
        let videoTracks: [AVAssetTrack]
        let assetDuration: CMTime
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            assetDuration = try await asset.load(.duration)
        } catch {
            throw ExtractionError.corrupt
        }
        guard !videoTracks.isEmpty else {
            audioFallback = AudioCursor(url: url, options: options, transcriber: transcriber)
            return
        }
        duration = assetDuration.isNumeric ? assetDuration.seconds : 0
        let capped = min(duration, options.maxVideoDuration)
        guard capped > 0 else { throw ExtractionError.corrupt }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: options.videoFrameMaxPixel, height: options.videoFrameMaxPixel)
        let tolerance = CMTime(seconds: 0.4 / max(options.videoFrameRate, 0.1), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        self.generator = generator

        clips = AudioAnalysis.windows(duration: capped, length: options.videoClipDuration, overlap: 0)
        audioReader = try? await AudioStreamReader.make(
            asset: asset, sampleRate: AudioAnalysis.embeddingSampleRate, maxDuration: capped
        )
        if audioReader != nil {
            waveform = try await AudioAnalysis.waveform(
                of: asset, duration: duration, bins: options.waveformBins, maxDuration: capped
            )
        }
        if let transcriber, audioReader != nil {
            do {
                transcript = try await transcriber.transcribe(url)
            } catch is CancellationError {
                throw ExtractionError.cancelled
            } catch {
                Log.extractor.error("Transcription failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Frames at `rate` per second inside `start..<end`, sampled at the middle of each interval.
    static func frameTimes(from start: Double, to end: Double, rate: Double) -> [Double] {
        let step = 1 / max(rate, 0.01)
        let times = Array(stride(from: start + step / 2, to: end, by: step))
        return times.isEmpty ? [(start + end) / 2] : times
    }

    private static func frames(
        of generator: AVAssetImageGenerator, from start: Double, to end: Double, rate: Double
    ) async throws -> [CGImage] {
        var frames: [CGImage] = []
        for time in frameTimes(from: start, to: end, rate: rate) {
            try Task.checkCancellation()
            do {
                let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
                frames.append(image)
            } catch is CancellationError {
                throw ExtractionError.cancelled
            } catch {
                Log.extractor.debug("Skipped a frame: \(String(describing: error), privacy: .public)")
            }
        }
        return frames
    }

    private func audioSlice(from start: Double, to end: Double) async throws -> AudioClip? {
        guard let audioReader else { return nil }
        let rate = AudioAnalysis.embeddingSampleRate
        let first = Int(start * rate)
        let last = Int(end * rate)
        let missing = last - (audioBufferStart + audioBuffer.count)
        if missing > 0 { audioBuffer += try await audioReader.read(missing) }
        let lower = max(0, first - audioBufferStart)
        let upper = min(audioBuffer.count, last - audioBufferStart)
        guard lower < upper else { return nil }
        let samples = Array(audioBuffer[lower..<upper])
        audioBuffer.removeFirst(upper)
        audioBufferStart += upper
        return AudioClip(samples: samples, sampleRate: rate, start: start)
    }
}
