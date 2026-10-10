import AVFoundation
import CoreGraphics
import Foundation
import GlintCore
import SoundAnalysis
import Vision

/// Describes images and sounds with words using classifiers that ship with macOS
/// (Vision scene classification, SoundAnalysis sound classification). The interim provider
/// embeds these words, which puts every modality in one text space.
struct MediaDescriber: Sendable {
    var imageLabelLimit = 8
    var imageConfidence: Float = 0.15
    var soundLabelLimit = 6
    var soundConfidence: Double = 0.3

    /// Scene labels for an image, most confident first, as readable words ("blue sky").
    func labels(for image: CGImage) -> [(label: String, confidence: Float)] {
        let request = VNClassifyImageRequest()
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            Log.embedding.debug("Image classification failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        return (request.results ?? [])
            .filter { $0.confidence >= imageConfidence }
            .prefix(imageLabelLimit)
            .map { (Self.readable($0.identifier), $0.confidence) }
    }

    /// Sound labels for a clip ("crowd", "cheering", "speech"), strongest first.
    func labels(for clip: AudioClip) -> [String] {
        guard clip.duration >= 1, let format = AVAudioFormat(standardFormatWithSampleRate: clip.sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return [] }
        buffer.frameLength = AVAudioFrameCount(clip.samples.count)
        clip.samples.withUnsafeBufferPointer { samples in
            if let base = samples.baseAddress { channel.update(from: base, count: samples.count) }
        }

        let observer = SoundObserver()
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            let analyzer = SNAudioStreamAnalyzer(format: format)
            try analyzer.add(request, withObserver: observer)
            analyzer.analyze(buffer, atAudioFramePosition: 0)
            analyzer.completeAnalysis()
        } catch {
            Log.embedding.debug("Sound classification failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        return observer.strongest(minimumConfidence: soundConfidence, limit: soundLabelLimit).map(Self.readable)
    }

    /// Words describing any input; text passes through unchanged.
    func describe(_ input: EmbeddingInput) -> String {
        switch input {
        case .text(let text):
            return text
        case .image(let image):
            let words = labels(for: image).map(\.label)
            return words.isEmpty ? "" : "photo of " + words.joined(separator: ", ")
        case .audio(let clip):
            let words = labels(for: clip)
            return words.isEmpty ? "" : "sound of " + words.joined(separator: ", ")
        case .video(let clip):
            return describe(clip)
        case .interleaved(let parts):
            return parts.map(describe).filter { !$0.isEmpty }.joined(separator: ". ")
        }
    }

    private func describe(_ clip: VideoClip) -> String {
        // First, middle and last frames are enough to describe a few seconds of video.
        let indices = Set([0, clip.frames.count / 2, clip.frames.count - 1]).filter { clip.frames.indices.contains($0) }
        var best: [String: Float] = [:]
        for index in indices.sorted() {
            for (label, confidence) in labels(for: clip.frames[index]) {
                best[label] = max(best[label] ?? 0, confidence)
            }
        }
        let visual = best.sorted { $0.value > $1.value }.prefix(imageLabelLimit).map(\.key)
        var parts: [String] = []
        if !visual.isEmpty { parts.append("video of " + visual.joined(separator: ", ")) }
        if let audio = clip.audio {
            let sounds = labels(for: audio)
            if !sounds.isEmpty { parts.append("sound of " + sounds.joined(separator: ", ")) }
        }
        return parts.joined(separator: ". ")
    }

    static func readable(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ")
    }
}

/// Collects the strongest confidence per sound label across analysis windows.
private final class SoundObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var best: [String: Double] = [:]

    func request(_ request: any SNRequest, didProduce result: any SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        lock.lock()
        defer { lock.unlock() }
        for classification in result.classifications.prefix(10) {
            best[classification.identifier] = max(best[classification.identifier] ?? 0, classification.confidence)
        }
    }

    func strongest(minimumConfidence: Double, limit: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return best.filter { $0.value >= minimumConfidence && $0.key != "silence" }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }
}
