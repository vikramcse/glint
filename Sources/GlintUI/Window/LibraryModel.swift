import Foundation
import GlintCore
import GlintSearch
import Observation

/// A saved search as the UI sees it.
public struct SavedSearchItem: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var name: String
    public var query: String

    public init(id: Int64, name: String, query: String) {
        self.id = id
        self.name = name
        self.query = query
    }
}

/// Persists saved searches; implemented by the app on top of the index store.
public protocol SavedSearchProviding: Sendable {
    func savedSearches() async -> [SavedSearchItem]
    func save(name: String, query: String) async throws -> SavedSearchItem
    func delete(id: Int64) async throws
}

/// Sidebar destinations in the main window.
public enum SidebarItem: Hashable, Sendable {
    case all
    case kind(MediaKind)
    case people
    case person(PersonID)
    case source(SourceID)
    case saved(Int64)
}

/// Browsing state for the main window when no query is typed: newest files first unless sorted otherwise.
@MainActor
@Observable
public final class LibraryModel {
    public private(set) var items: [SearchResult] = []
    public private(set) var isLoading = false
    public private(set) var savedSearches: [SavedSearchItem] = []
    /// Order of the library views; relevance means newest first here. Changing it reloads.
    public var sort: ResultSort { didSet { if sort != oldValue { reload() } } }
    @ObservationIgnored private let engine: SearchEngine
    @ObservationIgnored private let saved: any SavedSearchProviding
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastLoad: (@MainActor () -> Void)?

    public init(engine: SearchEngine, saved: any SavedSearchProviding, sort: ResultSort = .newestFirst) {
        self.engine = engine
        self.saved = saved
        self.sort = sort
    }

    public func load(kinds: Set<MediaKind>, folder: String? = nil, limit: Int = 400) {
        lastLoad = { [weak self] in self?.load(kinds: kinds, folder: folder, limit: limit) }
        run { [sort] engine in try await engine.recent(kinds: kinds, folder: folder, sort: sort, limit: limit) }
    }

    /// The photos and videos a person appears in.
    public func load(person: PersonID) {
        lastLoad = { [weak self] in self?.load(person: person) }
        run { [sort] engine in try await engine.files(of: person).sorted(by: sort) }
    }

    private func reload() { lastLoad?() }

    private func run(_ fetch: @escaping @Sendable (SearchEngine) async throws -> [SearchResult]) {
        task?.cancel()
        isLoading = true
        let engine = engine
        task = Task { [weak self] in
            let items = (try? await fetch(engine)) ?? []
            guard let self, !Task.isCancelled else { return }
            self.items = items
            self.isLoading = false
        }
    }

    public func reloadSavedSearches() async {
        savedSearches = await saved.savedSearches()
    }

    public func saveSearch(name: String, query: String) async throws {
        _ = try await saved.save(name: name, query: query)
        await reloadSavedSearches()
    }

    public func deleteSavedSearch(_ id: Int64) async throws {
        try await saved.delete(id: id)
        await reloadSavedSearches()
    }
}
