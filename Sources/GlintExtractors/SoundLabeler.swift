import AVFoundation
import CoreMedia
import Foundation
import GlintCore
import SoundAnalysis

/// One sound Apple's on-device classifier heard, and when.
struct SoundLabel: Sendable, Hashable {
    var start: Double
    var end: Double
    /// Readable name ("crow caw"), from the classifier's identifier ("crow_caw").
    var name: String
    var confidence: Double
}

/// Names what an audio file sounds like ("bird", "rain", "engine starting") with Apple's
/// built-in sound classifier (about 300 classes, on device). The embedding model alone barely
/// tells one sound from a similar one (text-to-audio: the right clip in the top 10 of its kind
/// for 36% of Clotho captions); the names give search words to match.
enum SoundLabeler {
    /// Labels below this confidence are dropped.
    static let minimumConfidence = 0.5
    /// At most this many labels describe one window.
    static let labelsPerWindow = 5

    /// Frames read and classified at a time; also how often cancellation is checked.
    static let framesPerRead: AVAudioFrameCount = 16_384

    /// Every label heard in the first `maxDuration` seconds of the file, per classifier window
    /// (about 1 s, half overlapping). Blocking; run it through `Offload`. Stops with
    /// `CancellationError` once `isCancelled` returns true.
    static func labels(
        of url: URL, maxDuration: Double, isCancelled: @Sendable () -> Bool = { false }
    ) throws -> [SoundLabel] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        let collector = Collector()
        try analyzer.add(request, withObserver: collector)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerRead) else { return [] }

        let limit = min(file.length, AVAudioFramePosition(max(0, maxDuration) * format.sampleRate))
        var position: AVAudioFramePosition = 0
        while position < limit {
            if isCancelled() {
                analyzer.removeAllRequests()
                throw CancellationError()
            }
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(framesPerRead), limit - position))
            try file.read(into: buffer, frameCount: frames)
            guard buffer.frameLength > 0 else { break }
            analyzer.analyze(buffer, atAudioFramePosition: position)
            position += AVAudioFramePosition(buffer.frameLength)
        }
        // Flushes the last windows; observers have been called by the time it returns.
        analyzer.completeAnalysis()
        if let error = collector.error { throw error }
        return collector.labels
    }

    private final class Collector: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var found: [SoundLabel] = []
        private var failure: (any Error)?

        var labels: [SoundLabel] { lock.withLock { found } }
        var error: (any Error)? { lock.withLock { failure } }

        func request(_ request: any SNRequest, didProduce result: any SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let start = result.timeRange.start.seconds
            let end = start + result.timeRange.duration.seconds
            let heard = result.classifications.filter { $0.confidence >= SoundLabeler.minimumConfidence }.map {
                SoundLabel(start: start, end: end, name: $0.identifier.replacingOccurrences(of: "_", with: " "), confidence: $0.confidence)
            }
            lock.withLock { found += heard }
        }

        func request(_ request: any SNRequest, didFailWithError error: any Error) {
            lock.withLock { failure = error }
        }
    }
}

/// Carries a task's cancellation into blocking work running outside it.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

extension [SoundLabel] {
    /// The strongest sounds heard between `start` and `end`, as text for search ("Sounds: bird
    /// squawk, crow caw"), or `nil` when nothing was heard confidently.
    func text(from start: Double, to end: Double) -> String? {
        var best: [String: Double] = [:]
        for label in self where label.end > start && label.start < end {
            best[label.name] = Swift.max(best[label.name] ?? 0, label.confidence)
        }
        let names = best.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(SoundLabeler.labelsPerWindow).map(\.key)
        return names.isEmpty ? nil : "Sounds: " + names.joined(separator: ", ")
    }
}
