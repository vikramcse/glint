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

    /// Every label heard in the file, per classifier window (about 1 s, half overlapping).
    static func labels(of url: URL) throws -> [SoundLabel] {
        let analyzer = try SNAudioFileAnalyzer(url: url)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        let collector = Collector()
        try analyzer.add(request, withObserver: collector)
        analyzer.analyze()
        if let error = collector.error { throw error }
        return collector.labels
    }

    private final class Collector: NSObject, SNResultsObserving, @unchecked Sendable {
        // Written only on the analyzer's queue, read after `analyze()` returns.
        var labels: [SoundLabel] = []
        var error: (any Error)?

        func request(_ request: any SNRequest, didProduce result: any SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let start = result.timeRange.start.seconds
            let end = start + result.timeRange.duration.seconds
            for classification in result.classifications where classification.confidence >= SoundLabeler.minimumConfidence {
                labels.append(
                    SoundLabel(
                        start: start, end: end, name: classification.identifier.replacingOccurrences(of: "_", with: " "),
                        confidence: classification.confidence))
            }
        }

        func request(_ request: any SNRequest, didFailWithError error: any Error) {
            self.error = error
        }
    }
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
