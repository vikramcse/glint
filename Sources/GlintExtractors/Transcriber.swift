import Foundation
import GlintCore
import Speech

/// A span of recognized speech.
public struct TranscriptSegment: Sendable, Hashable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Produces a timed transcript of an audio or video file, entirely on device.
public protocol Transcriber: Sendable {
    /// Returns segments in time order, or an empty array when transcription is unavailable.
    func transcribe(_ url: URL) async throws -> [TranscriptSegment]
}

extension [TranscriptSegment] {
    /// Text of the segments overlapping `start..<end`, or `nil` when there is none.
    func text(from start: Double, to end: Double) -> String? {
        let words = filter { $0.end > start && $0.start < end }.map(\.text)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}

/// Transcribes with `SFSpeechRecognizer` in on-device mode.
///
/// Never asks for permission: if Speech Recognition is not already authorized, or on-device
/// recognition is unavailable for the locale, it returns no segments.
public struct OnDeviceSpeechTranscriber: Transcriber {
    public var locale: Locale

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    public func transcribe(_ url: URL) async throws -> [TranscriptSegment] {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
            let recognizer = SFSpeechRecognizer(locale: locale),
            recognizer.supportsOnDeviceRecognition
        else { return [] }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        let gate = ResumeOnce()
        let taskBox = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[TranscriptSegment], any Error>) in
                taskBox.task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        if gate.claim() { continuation.resume(throwing: error) }
                        return
                    }
                    guard let result, result.isFinal else { return }
                    let segments = result.bestTranscription.segments.map {
                        TranscriptSegment(start: $0.timestamp, end: $0.timestamp + $0.duration, text: $0.substring)
                    }
                    if gate.claim() { continuation.resume(returning: segments) }
                }
            }
        } onCancel: {
            taskBox.task?.cancel()
        }
    }
}

/// Ensures a continuation resumes exactly once.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Holds the recognition task so cancellation can reach it.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: SFSpeechRecognitionTask?

    var task: SFSpeechRecognitionTask? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
