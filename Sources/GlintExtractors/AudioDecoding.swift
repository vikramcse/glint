@preconcurrency import AVFoundation
import Foundation

/// Streams an asset's audio as mono Float PCM at a fixed sample rate, mixing all audio tracks.
///
/// Uses `AVAssetReader`, which resamples and downmixes in its output settings, so audio files
/// and the audio tracks of videos go through the same path. Not thread-safe: exactly one actor
/// owns each reader and awaits each read before starting the next, which is what makes the
/// `@unchecked Sendable` hop to the offload queue safe.
final class AudioStreamReader: @unchecked Sendable {
    let sampleRate: Double
    private let reader: AVAssetReader
    private let output: AVAssetReaderAudioMixOutput
    private var pending: [Float] = []
    private var pendingStart = 0
    private(set) var isFinished = false

    /// Returns `nil` when the asset has no audio track.
    static func make(asset: AVURLAsset, sampleRate: Double, maxDuration: Double) async throws -> AudioStreamReader? {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        return try AudioStreamReader(asset: asset, tracks: tracks, sampleRate: sampleRate, maxDuration: maxDuration)
    }

    private init(asset: AVURLAsset, tracks: [AVAssetTrack], sampleRate: Double, maxDuration: Double) throws {
        self.sampleRate = sampleRate
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ExtractionError.corrupt
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExtractionError.unsupported }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: .zero, duration: CMTime(seconds: maxDuration, preferredTimescale: 600)
        )
        guard reader.startReading() else { throw ExtractionError.corrupt }
    }

    deinit {
        if reader.status == .reading { reader.cancelReading() }
    }

    /// Reads up to `count` samples off the cooperative pool. Returns fewer only at the end.
    func read(_ count: Int) async throws -> [Float] {
        try await Offload.run { try self.readBlocking(count) }
    }

    private func readBlocking(_ count: Int) throws -> [Float] {
        while pending.count - pendingStart < count, !isFinished {
            try fill()
        }
        let available = min(count, pending.count - pendingStart)
        let result = Array(pending[pendingStart..<pendingStart + available])
        pendingStart += available
        if pendingStart > 1 << 20 {
            pending.removeFirst(pendingStart)
            pendingStart = 0
        }
        return result
    }

    private func fill() throws {
        guard let buffer = output.copyNextSampleBuffer() else {
            isFinished = true
            if reader.status == .failed { throw ExtractionError.corrupt }
            return
        }
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        let count = length / MemoryLayout<Float>.size
        guard count > 0 else { return }
        let start = pending.count
        pending.append(contentsOf: repeatElement(0, count: count))
        let status = pending.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(
                block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                destination: base.advanced(by: start * MemoryLayout<Float>.size)
            )
        }
        if status != noErr { throw ExtractionError.corrupt }
    }
}

enum AudioAnalysis {
    /// Sample rate for embedding (EmbeddingGemma expects 16 kHz mono).
    static let embeddingSampleRate: Double = 16_000
    /// Low sample rate for the waveform pass; peaks survive, decoding stays cheap.
    static let waveformSampleRate: Double = 8_000

    /// Computes `bins` normalized (0...1) peaks for an asset's audio in one streaming pass.
    static func waveform(of asset: AVURLAsset, duration: Double, bins: Int, maxDuration: Double) async throws -> [Float] {
        guard bins > 0, duration > 0,
            let reader = try await AudioStreamReader.make(
                asset: asset, sampleRate: waveformSampleRate, maxDuration: maxDuration
            )
        else { return [] }
        let total = max(1, Int(min(duration, maxDuration) * waveformSampleRate))
        let perBin = max(1, Int((Double(total) / Double(bins)).rounded(.up)))
        var peaks: [Float] = []
        peaks.reserveCapacity(bins)
        while peaks.count < bins {
            try Task.checkCancellation()
            let block = try await reader.read(perBin)
            if block.isEmpty { break }
            peaks.append(block.reduce(0) { max($0, abs($1)) })
        }
        return normalized(peaks)
    }

    static func normalized(_ peaks: [Float]) -> [Float] {
        let loudest = peaks.max() ?? 0
        guard loudest > 0 else { return peaks }
        return peaks.map { min(1, $0 / loudest) }
    }

    /// Window start/end times covering `duration`. The last window may be shorter; no window
    /// starts after an earlier one already reached the end.
    static func windows(duration: Double, length: Double, overlap: Double) -> [(start: Double, end: Double)] {
        guard duration > 0, length > 0 else { return [] }
        let hop = max(length - max(0, overlap), length / 10)
        var windows: [(Double, Double)] = []
        var start = 0.0
        while start < duration {
            let end = min(start + length, duration)
            windows.append((start, end))
            if end >= duration { break }
            start += hop
        }
        return windows
    }
}
