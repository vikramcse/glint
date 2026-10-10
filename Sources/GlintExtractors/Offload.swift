import Dispatch
import Foundation

/// Runs blocking framework work (Vision, ImageIO, PDFKit text, AVAssetReader) on a GCD queue
/// instead of Swift's cooperative pool.
///
/// Vision performs requests synchronously and waits on its own internal queues; running many
/// such calls on cooperative threads can starve the pool and deadlock. Everything blocking in
/// this module goes through here.
enum Offload {
    private static let queue = DispatchQueue(
        label: "app.glint.extractors.blocking", qos: .utility, attributes: .concurrent
    )

    /// Limits concurrent OCR; Vision already parallelizes internally and uses the Neural Engine,
    /// and accurate OCR does not get faster beyond two lanes (benchmark: 149 ms/image at 2, 146
    /// at 8). The indexer narrows it to one lane on battery.
    static let ocrLane = Lane(width: 2)

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}

/// A counting semaphore whose width can change while work is waiting.
public final class Lane: @unchecked Sendable {
    private let condition = NSCondition()
    private var width: Int
    private var active = 0

    public init(width: Int) {
        self.width = max(1, width)
    }

    public var currentWidth: Int {
        condition.lock()
        defer { condition.unlock() }
        return width
    }

    public func setWidth(_ newWidth: Int) {
        condition.lock()
        width = max(1, newWidth)
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks the calling (GCD) thread until a slot is free, runs `work`, then frees the slot.
    public func run<T>(_ work: () throws -> T) rethrows -> T {
        condition.lock()
        while active >= width { condition.wait() }
        active += 1
        condition.unlock()
        defer {
            condition.lock()
            active -= 1
            condition.signal()
            condition.unlock()
        }
        return try work()
    }
}

/// Shared extraction lanes the indexer tunes for power and thermal state.
public enum ExtractionLanes {
    /// Concurrent Vision text recognitions.
    public static var ocr: Lane { Offload.ocrLane }
}
