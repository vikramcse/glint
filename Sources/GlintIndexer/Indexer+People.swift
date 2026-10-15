import Foundation
import GlintCore
import GlintStore

// MARK: People

extension Indexer {
    /// Groups newly found faces into people: at most every `interval` while indexing, so People
    /// fills in as a large library is indexed, and always when the queue empties (`force`).
    func clusterFaces(force: Bool, interval: Duration = .seconds(30)) async {
        if !force, let lastClustering, ContinuousClock.now - lastClustering < interval { return }
        guard !isClustering else { return }
        isClustering = true
        defer { isClustering = false }
        lastClustering = .now
        do {
            let assigned = try await writer.clusterFaces()
            if assigned > 0 { Log.indexer.info("Grouped \(assigned, privacy: .public) faces into people") }
        } catch {
            Log.indexer.error("Grouping faces failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Finds faces in photos and videos indexed before Glint looked for faces, by indexing them
    /// again. Their current chunks stay searchable until each is re-committed. Returns how many
    /// files were queued.
    @discardableResult
    public func rescanForFaces() async throws -> Int {
        let requeued = try await writer.requeueForFaces()
        Log.indexer.info("Re-indexing \(requeued, privacy: .public) photos and videos for faces")
        wake()
        await publishStatus(force: true)
        return requeued
    }
}
