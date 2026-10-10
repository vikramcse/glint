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

    /// Limits concurrent OCR; Vision already parallelizes internally and uses the Neural Engine.
    static let ocrSlots = DispatchSemaphore(value: 2)

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
