import Foundation
import GlintCore
import Observation

/// Live index status and sources for the menu bar, panel footer and Settings.
@MainActor
@Observable
public final class IndexStatusModel {
    public private(set) var status = IndexStatus()
    public private(set) var sources: [SourceInfo] = []
    public private(set) var exclusions = ExclusionRules.default
    @ObservationIgnored private let indexing: any IndexingService
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastSourceRefresh: ContinuousClock.Instant?

    public init(indexing: any IndexingService) {
        self.indexing = indexing
    }

    /// Starts following status updates. Safe to call more than once.
    public func start() {
        guard task == nil else { return }
        task = Task { [weak self, indexing] in
            for await status in await indexing.statusUpdates() {
                guard let self else { return }
                let previous = self.status
                self.status = status
                // Per-folder progress follows the overall status, at most once a second while
                // indexing, and always when the phase or folder count changes so the final
                // state (a checkmark) is never stale.
                let structural = status.phase != previous.phase || status.sourceCount != previous.sourceCount
                let due = self.lastSourceRefresh.map { ContinuousClock.now - $0 > .seconds(1) } ?? true
                if structural || (due && status != previous) { await self.refreshSources() }
            }
        }
        Task { await refreshSources() }
    }

    public func refreshSources() async {
        lastSourceRefresh = .now
        sources = (try? await indexing.sources()) ?? []
        exclusions = await indexing.exclusions()
    }

    public var isPaused: Bool {
        if case .paused = status.phase { true } else { false }
    }

    /// One line of honest status: "Indexing 1,204 of 5,310 items".
    public var summary: String {
        let indexed = status.totalIndexed
        let total = indexed + status.pending
        switch status.phase {
        case .scanning:
            return String(localized: "Looking for files…")
        case .indexing:
            return String(localized: "Indexing \(indexed.formatted()) of \(total.formatted()) items")
        case .paused(let reason):
            return Self.pauseText(reason)
        case .idle:
            if status.sourceCount == 0 { return String(localized: "No folders added yet") }
            return String(localized: "\(indexed.formatted()) items indexed")
        }
    }

    public static func pauseText(_ reason: PauseReason) -> String {
        switch reason {
        case .user: String(localized: "Indexing paused")
        case .lowBattery: String(localized: "Paused to save battery")
        case .lowPowerMode: String(localized: "Paused in Low Power Mode")
        case .thermal: String(localized: "Paused while your Mac cools down")
        }
    }
}
