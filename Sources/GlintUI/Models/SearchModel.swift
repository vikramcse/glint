import Foundation
import GlintCore
import GlintLicensing
import GlintSearch
import Observation

/// A titled group of results in display order.
public struct ResultSection: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case topHits
        case media(MediaKind)
        case all
    }

    public var kind: Kind
    public var results: [SearchResult]

    public var id: Kind { kind }

    public var title: String {
        switch kind {
        case .topHits: String(localized: "Top Hits", comment: "Result section")
        case .media(let media): media.sectionTitle
        case .all: String(localized: "Results", comment: "Result section")
        }
    }
}

/// What the results area shows when there are no results to list.
public enum SearchEmptyState: Hashable, Sendable {
    case noSources
    case start
    case stillIndexing(pending: Int)
    case noResults(lockedKinds: Bool)
}

/// Drives a search field and its results: keyword results on every keystroke, semantic
/// results merged in 40 ms after the last keystroke, with every newer keystroke cancelling
/// in-flight work. The selected row never moves when results merge in.
@MainActor
@Observable
public final class SearchModel {
    public var text = "" { didSet { if text != oldValue { queryChanged() } } }
    public var tokens: [SearchToken] = [] { didSet { if tokens != oldValue { queryChanged() } } }
    /// Kinds selected outside the field (the main window's sidebar).
    public var scope: Set<MediaKind> = [] { didSet { if scope != oldValue { queryChanged() } } }
    /// Folder selected outside the field (a source in the main window's sidebar).
    public var folderScope: String? { didSet { if folderScope != oldValue { queryChanged() } } }
    public var selection: FileID?
    public var groupByKind = true

    public private(set) var results: [SearchResult] = []
    public private(set) var phase: SearchPhase?
    public private(set) var isMerging = false
    public private(set) var similarTo: SearchResult?
    public private(set) var errorMessage: String?

    @ObservationIgnored private let engine: SearchEngine
    @ObservationIgnored private let entitlements: @MainActor () -> Entitlements
    @ObservationIgnored private let sourcePaths: @MainActor () -> [String]
    @ObservationIgnored private let report: @MainActor (UIEvent) -> Void
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var keywordTask: Task<Void, Never>?
    @ObservationIgnored private var mergeTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// The generation whose merged results are on screen; slower keyword results for the
    /// same generation must not replace them.
    @ObservationIgnored private var mergedGeneration = -1
    @ObservationIgnored public var onFirstSearch: (@MainActor () -> Void)?

    public init(
        engine: SearchEngine,
        entitlements: @escaping @MainActor () -> Entitlements,
        sourcePaths: @escaping @MainActor () -> [String] = { [] },
        report: @escaping @MainActor (UIEvent) -> Void = { _ in },
        debounce: Duration = .milliseconds(40)
    ) {
        self.engine = engine
        self.entitlements = entitlements
        self.sourcePaths = sourcePaths
        self.report = report
        self.debounce = debounce
    }

    // MARK: Query

    /// The query the current text, tokens and scope describe.
    public var currentQuery: SearchQuery {
        let parsed = QueryParser.parse(text)
        let combined = ParsedQuery(text: parsed.text, tokens: parsed.tokens + tokens)
        var filter = combined.filter(allowFullFilters: entitlements().allows(.fullFilters), sources: sourcePaths())
        filter.kinds.formUnion(scope)
        if let folderScope { filter.folders.append(folderScope) }
        return SearchQuery(text: combined.text, filter: filter)
    }

    /// Re-runs the current query (for example after the index changed).
    public func refresh() { queryChanged() }

    public func clear() {
        text = ""
        tokens = []
        similarTo = nil
        results = []
        phase = nil
    }

    private func queryChanged() {
        generation += 1
        let current = generation
        keywordTask?.cancel()
        mergeTask?.cancel()
        similarTo = nil
        errorMessage = nil

        let query = currentQuery
        guard !query.isEmpty else {
            results = []
            phase = nil
            isMerging = false
            return
        }
        let stopwatch = Stopwatch()
        let engine = engine
        keywordTask = Task { [weak self] in
            guard let results = try? await engine.keywordResults(for: query) else { return }
            guard let self, !Task.isCancelled, current == self.generation, self.mergedGeneration != current else { return }
            self.apply(results)
        }
        isMerging = true
        mergeTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            do {
                let merged = try await engine.mergedResults(for: query)
                guard let self, !Task.isCancelled, current == self.generation else { return }
                self.mergedGeneration = current
                self.apply(merged)
                self.isMerging = false
                self.didSearch(latency: stopwatch.milliseconds, results: merged.items)
            } catch {
                guard let self, current == self.generation, !(error is CancellationError) else { return }
                self.isMerging = false
                if error.glintCategory != .cancelled { self.errorMessage = ErrorPresenter.message(for: error) }
            }
        }
    }

    private func apply(_ new: SearchResults) {
        let ordered = ResultStabilizer.stabilize(previous: results, next: new.items, pinned: selection)
        results = ordered
        phase = new.phase
        if selection == nil || !ordered.contains(where: { $0.id == selection }) {
            selection = displayOrder.first?.id
        }
    }

    private func didSearch(latency: Double, results: [SearchResult]) {
        report(.searchPerformed(latencyMilliseconds: latency, resultCount: results.count, kinds: Set(results.map(\.file.kind))))
        onFirstSearch?()
        onFirstSearch = nil
    }

    // MARK: Find similar

    public func findSimilar(to result: SearchResult) {
        guard entitlements().allows(.findSimilar) else { return }
        run(similarTo: result) { engine in try await engine.similar(to: result.id) }
    }

    public func findSimilar(toFileAt url: URL) {
        guard entitlements().allows(.findSimilar) else { return }
        run(similarTo: nil) { engine in try await engine.similar(toFileAt: url) }
    }

    private func run(similarTo example: SearchResult?, _ operation: @escaping @Sendable (SearchEngine) async throws -> SearchResults) {
        generation += 1
        let current = generation
        keywordTask?.cancel()
        mergeTask?.cancel()
        text = ""
        similarTo = example
        isMerging = true
        let engine = engine
        mergeTask = Task { [weak self] in
            do {
                let results = try await operation(engine)
                guard let self, current == self.generation else { return }
                self.similarTo = example
                self.apply(results)
            } catch {
                self?.errorMessage = ErrorPresenter.message(for: error)
            }
            self?.isMerging = false
        }
    }

    // MARK: Presentation

    /// Results grouped for display: up to three top hits, then one section per kind.
    public var sections: [ResultSection] {
        guard groupByKind, results.count > 4 else {
            return results.isEmpty ? [] : [ResultSection(kind: .all, results: results)]
        }
        let top = Array(results.prefix(3))
        var sections = [ResultSection(kind: .topHits, results: top)]
        let rest = results.dropFirst(3)
        for kind in MediaKind.allCases.sorted() {
            let items = rest.filter { $0.file.kind == kind }
            if !items.isEmpty { sections.append(ResultSection(kind: .media(kind), results: items)) }
        }
        return sections
    }

    /// Results in the order they appear on screen (what the arrow keys walk through).
    public var displayOrder: [SearchResult] { sections.flatMap(\.results) }

    public var selectedResult: SearchResult? {
        guard let selection else { return nil }
        return results.first { $0.id == selection }
    }

    /// Moves the selection by `offset` rows in display order, clamping at the ends.
    public func moveSelection(by offset: Int) {
        let order = displayOrder
        guard !order.isEmpty else { return }
        let index = order.firstIndex { $0.id == selection } ?? -1
        selection = order[min(max(index + offset, 0), order.count - 1)].id
    }

    /// The 1-based rank of a result, for analytics.
    public func rank(of result: SearchResult) -> Int {
        (displayOrder.firstIndex { $0.id == result.id } ?? 0) + 1
    }

    public func emptyState(status: IndexStatus) -> SearchEmptyState? {
        guard results.isEmpty, !isMerging || phase == .merged else { return nil }
        if status.sourceCount == 0 { return .noSources }
        if currentQuery.isEmpty, similarTo == nil { return .start }
        if status.pending > 0 { return .stillIndexing(pending: status.pending) }
        return .noResults(lockedKinds: status.locked > 0)
    }
}
