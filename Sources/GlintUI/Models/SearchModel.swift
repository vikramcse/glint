import Foundation
import GlintCore
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

/// What the search field's text is matched against.
public enum MatchScope: String, Hashable, Sendable, CaseIterable {
    /// Names, contents and meaning.
    case everything
    /// File names only, anywhere in the name.
    case fileNames
}

/// What the results area shows when there are no results to list.
public enum SearchEmptyState: Hashable, Sendable {
    case noSources
    case start
    case stillIndexing(pending: Int)
    case noResults
    case failed(String)
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
    /// Match file names only, or everything (picked outside the field; `name:` in the text also works).
    public var matchScope: MatchScope = .everything { didSet { if matchScope != oldValue { queryChanged() } } }
    public var selection: FileID?
    public var groupByKind = true
    /// Display order; anything but relevance lists results in one section.
    public var sort: ResultSort = .relevance

    public private(set) var results: [SearchResult] = []
    public private(set) var phase: SearchPhase?
    public private(set) var isMerging = false
    public private(set) var similarTo: SearchResult?
    /// A file dropped from outside the results that "find similar" compares with.
    public private(set) var similarToFile: URL?
    public private(set) var errorMessage: String?

    @ObservationIgnored private let engine: SearchEngine
    @ObservationIgnored private let sourcePaths: @MainActor () -> [String]
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
        sourcePaths: @escaping @MainActor () -> [String] = { [] },
        debounce: Duration = .milliseconds(40)
    ) {
        self.engine = engine
        self.sourcePaths = sourcePaths
        self.debounce = debounce
    }

    // MARK: Query

    /// The query the current text, tokens and scope describe.
    public var currentQuery: SearchQuery {
        let parsed = QueryParser.parse(text)
        let combined = ParsedQuery(text: parsed.text, tokens: parsed.tokens + tokens)
        var filter = combined.filter(sources: sourcePaths())
        filter.kinds.formUnion(scope)
        if let folderScope { filter.folders.append(folderScope) }
        return SearchQuery(text: combined.text, filter: filter, namesOnly: parsed.namesOnly || matchScope == .fileNames)
    }

    /// Re-runs the current query (for example after the index changed).
    public func refresh() { queryChanged() }

    public func clear() {
        text = ""
        tokens = []
        similarTo = nil
        similarToFile = nil
        results = []
        phase = nil
    }

    private func queryChanged() {
        generation += 1
        let current = generation
        keywordTask?.cancel()
        mergeTask?.cancel()
        similarTo = nil
        similarToFile = nil
        errorMessage = nil

        let query = currentQuery
        guard !query.isEmpty else {
            results = []
            phase = nil
            isMerging = false
            return
        }
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
                self.didSearch()
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

    private func didSearch() {
        onFirstSearch?()
        onFirstSearch = nil
    }

    // MARK: Find similar

    /// Whether the results are "find similar" results rather than a query's.
    public var isFindingSimilar: Bool { similarTo != nil || similarToFile != nil }

    /// The name of the file "find similar" compares with.
    public var similarExampleName: String? { similarTo?.file.name ?? similarToFile?.lastPathComponent }

    public func findSimilar(to result: SearchResult) {
        run(similarTo: result, file: nil) { engine in try await engine.similar(to: result.id) }
    }

    public func findSimilar(toFileAt url: URL) {
        run(similarTo: nil, file: url) { engine in try await engine.similar(toFileAt: url) }
    }

    private func run(
        similarTo example: SearchResult?, file: URL?, _ operation: @escaping @Sendable (SearchEngine) async throws -> SearchResults
    ) {
        // Clearing the text starts a new (empty) query; do it before taking this run's generation.
        text = ""
        generation += 1
        let current = generation
        keywordTask?.cancel()
        mergeTask?.cancel()
        similarTo = example
        similarToFile = file
        errorMessage = nil
        results = []
        isMerging = true
        let engine = engine
        mergeTask = Task { [weak self] in
            do {
                let results = try await operation(engine)
                guard let self, current == self.generation else { return }
                self.apply(results)
                self.isMerging = false
            } catch {
                guard let self, current == self.generation, !(error is CancellationError) else { return }
                self.errorMessage = ErrorPresenter.message(for: error)
                self.isMerging = false
            }
        }
    }

    // MARK: Presentation

    /// Results grouped for display: up to three top hits, then one section per kind. Sorted
    /// any other way than by relevance, they are one list.
    public var sections: [ResultSection] {
        guard sort.field == .relevance else {
            return results.isEmpty ? [] : [ResultSection(kind: .all, results: results.sorted(by: sort))]
        }
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

    public func emptyState(status: IndexStatus) -> SearchEmptyState? {
        guard results.isEmpty, !isMerging || phase == .merged else { return nil }
        if status.sourceCount == 0 { return .noSources }
        if let errorMessage { return .failed(errorMessage) }
        if currentQuery.isEmpty, !isFindingSimilar { return .start }
        if status.pending > 0 { return .stillIndexing(pending: status.pending) }
        return .noResults
    }
}
