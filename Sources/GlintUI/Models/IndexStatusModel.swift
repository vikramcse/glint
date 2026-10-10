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

    public init(indexing: any IndexingService) {
        self.indexing = indexing
    }

    /// Starts following status updates. Safe to call more than once.
    public func start() {
        guard task == nil else { return }
        task = Task { [weak self, indexing] in
            for await status in await indexing.statusUpdates() {
                guard let self else { return }
                let sourcesChanged = status.sourceCount != self.status.sourceCount
                self.status = status
                if sourcesChanged || self.sources.isEmpty { await self.refreshSources() }
            }
        }
        Task { await refreshSources() }
    }

    public func refreshSources() async {
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
        case .itemLimitReached: String(localized: "Free limit of 10,000 items reached")
        }
    }
}
