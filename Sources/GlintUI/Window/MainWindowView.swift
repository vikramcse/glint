import GlintCore
import GlintSearch
import SwiftUI

/// The main window: library sidebar, results grid or list, and an inspector.
public struct MainWindowView: View {
    let services: GlintServices
    @State private var model: SearchModel
    @State private var library: LibraryModel
    @State private var sidebar: SidebarItem? = .all
    @State private var showInspector = true
    @State private var savingSearch = false
    @State private var savedSearchName = ""
    @State private var people: PeopleModel?
    @State private var naming: PersonSummary?
    @State private var personName = ""

    public init(services: GlintServices, savedSearches: any SavedSearchProviding) {
        self.services = services
        _model = State(
            initialValue: SearchModel(
                engine: services.engine,
                sourcePaths: { services.status.sources.map(\.path) }
            ))
        _library = State(initialValue: LibraryModel(engine: services.engine, saved: savedSearches, sort: services.settings.librarySort))
        _people = State(initialValue: services.people.map(PeopleModel.init(provider:)))
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(selection: sidebarSelection, library: library, people: people, services: services)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            detail
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if IndexingStatusBar.isVisible(services.status.status) {
                        IndexingStatusBar(services: services)
                    }
                }
                .navigationTitle(title)
                .navigationSubtitle(services.status.summary)
                // Search and toolbar belong to the detail column, and the inspector is attached
                // inside it, so the inspector gets its own toolbar section instead of the search
                // field stretching over it.
                .searchable(
                    text: $model.text, tokens: $model.tokens, suggestedTokens: .constant(suggestedTokens), placement: .toolbar,
                    prompt: Text("Search anything")
                ) { token in
                    TokenLabel(token: token)
                }
                .searchScopes($model.matchScope) {
                    Text("Everything").tag(MatchScope.everything)
                    Text("File Names").tag(MatchScope.fileNames)
                }
                .toolbar { toolbar }
                .inspector(isPresented: $showInspector) {
                    InspectorView(result: selectedResult, model: model, services: services)
                        .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
                }
        }
        .onChange(of: sidebar, initial: true) { _, item in applySidebar(item) }
        .onChange(of: services.status.status.totalIndexed) { _, _ in
            if model.text.isEmpty { applySidebar(sidebar) }
        }
        .onChange(of: services.status.status.phase) { _, _ in
            // Faces are grouped into people when the queue empties.
            Task { await people?.load() }
        }
        .task {
            services.status.start()
            await library.reloadSavedSearches()
            await people?.load()
        }
        .alert(Text("Name This Person"), isPresented: namingBinding, presenting: naming) { person in
            TextField(text: $personName, prompt: Text("Name")) { Text("Name") }
            Button("Save") { rename(person) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Give two people the same name to combine them.")
        }
        .alert(Text("Save Search"), isPresented: $savingSearch) {
            TextField(text: $savedSearchName, prompt: Text("Name")) { Text("Name") }
            Button("Save") {
                let query = model.text
                Task { try? await library.saveSearch(name: savedSearchName, query: query) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The People grid when browsing people; results otherwise.
    @ViewBuilder private var detail: some View {
        if sidebar == .people, let people, model.currentQuery.isEmpty, !model.isFindingSimilar {
            PeopleView(
                people: people, onOpen: { sidebar = .person($0) }, onRename: startNaming,
                onError: { services.actions?.presentError($0) })
        } else {
            ResultsArea(model: model, library: library, services: services, layout: layoutBinding)
        }
    }

    /// A person's page keeps People selected in the sidebar.
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding {
            if case .person = sidebar { return .people }
            return sidebar
        } set: {
            sidebar = $0
        }
    }

    private var namingBinding: Binding<Bool> {
        Binding {
            naming != nil
        } set: {
            if !$0 { naming = nil }
        }
    }

    private func startNaming(_ person: PersonSummary) {
        personName = person.name ?? ""
        naming = person
    }

    private func rename(_ person: PersonSummary) {
        guard let people else { return }
        let name = personName
        Task {
            do {
                let shown = try await people.rename(person.id, to: name)
                if case .person = sidebar { sidebar = .person(shown) }
            } catch {
                services.actions?.presentError(String(localized: "Couldn’t rename this person: \(error.localizedDescription)"))
            }
        }
    }

    /// Search results while searching, the library otherwise; only the library's order is remembered.
    private var isSearching: Bool { !model.currentQuery.isEmpty || model.isFindingSimilar }

    private var sortBinding: Binding<ResultSort> {
        Binding {
            isSearching ? model.sort : library.sort
        } set: {
            if isSearching {
                model.sort = $0
            } else {
                library.sort = $0
                services.settings.librarySort = $0
            }
        }
    }

    private var layoutBinding: Binding<ResultsLayout> {
        Binding {
            services.settings.mainWindowLayout
        } set: {
            services.settings.mainWindowLayout = $0
        }
    }

    private var selectedResult: SearchResult? {
        guard let selection = model.selection else { return nil }
        return (model.results + library.items).first { $0.id == selection }
    }

    private var title: String {
        if let name = model.similarExampleName { return String(localized: "Similar to \(name)") }
        return switch sidebar {
        case .kind(let kind): kind.sectionTitle
        case .source(let id): services.status.sources.first { $0.id == id }?.displayName ?? String(localized: "Folder")
        case .saved(let id): library.savedSearches.first { $0.id == id }?.name ?? String(localized: "Saved Search")
        case .people: String(localized: "People")
        case .person(let id): people?.person(id)?.name ?? String(localized: "Unnamed Person")
        case .all, nil: String(localized: "All Items")
        }
    }

    private var suggestedTokens: [SearchToken] {
        guard model.tokens.isEmpty, !model.text.isEmpty else { return [] }
        var tokens = MediaKind.allCases.sorted().map(SearchToken.kind)
        tokens += [.modifiedSince(.today), .modifiedSince(.week), .modifiedSince(.month)]
        tokens += services.status.sources.map { .folder($0.path) }
        return tokens
    }

    private func applySidebar(_ item: SidebarItem?) {
        switch item {
        case .kind(let kind):
            model.scope = [kind]
            model.folderScope = nil
            library.load(kinds: [kind])
        case .source(let id):
            model.scope = []
            let path = services.status.sources.first { $0.id == id }?.path
            model.folderScope = path
            library.load(kinds: [], folder: path)
        case .people:
            model.scope = [.image, .video]
            model.folderScope = nil
            Task { await people?.load() }
        case .person(let id):
            model.scope = [.image, .video]
            model.folderScope = nil
            library.load(person: id)
        case .saved(let id):
            model.scope = []
            model.folderScope = nil
            if let saved = library.savedSearches.first(where: { $0.id == id }) { model.text = saved.query }
        case .all, nil:
            model.scope = []
            model.folderScope = nil
            library.load(kinds: [])
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if case .person(let id) = sidebar {
            ToolbarItem(placement: .navigation) {
                Button {
                    sidebar = .people
                } label: {
                    Label("People", systemImage: "chevron.backward")
                }
                .help(Text("Back to People"))
            }
            ToolbarItem {
                Button {
                    startNaming(people?.person(id) ?? PersonSummary(id: id, name: nil, fileCount: 0, faceThumbnailURL: nil))
                } label: {
                    Label("Name", systemImage: "character.cursor.ibeam")
                }
                .help(Text("Name this person"))
            }
        }
        if model.isFindingSimilar {
            ToolbarItem {
                Button {
                    model.clear()
                } label: {
                    Label("Clear Similar", systemImage: "xmark.circle")
                }
                .help(Text("Go back to the library"))
            }
        }
        ToolbarItem {
            SortMenu(sort: sortBinding, offersRelevance: isSearching)
                .disabled(sidebar == .people && !isSearching)
        }
        ToolbarItem {
            Picker(selection: layoutBinding) {
                Label("Grid", systemImage: "square.grid.2x2").tag(ResultsLayout.grid)
                Label("List", systemImage: "list.bullet").tag(ResultsLayout.list)
            } label: {
                Text("View")
            }
            .pickerStyle(.segmented)
            .help(Text("Change how results are shown"))
        }
        ToolbarItem {
            Button {
                savedSearchName = model.text
                savingSearch = true
            } label: {
                Label("Save Search", systemImage: "bookmark")
            }
            .disabled(model.text.isEmpty)
            .help(Text("Save this search in the sidebar"))
        }
        ToolbarItem {
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help(Text("Show or hide the inspector"))
        }
    }
}

struct TokenLabel: View {
    let token: SearchToken

    var body: some View {
        switch token {
        case .kind(let kind): Label(kind.sectionTitle, systemImage: kind.symbolName)
        case .folder(let path): Label((path as NSString).lastPathComponent, systemImage: "folder")
        case .modifiedSince(let preset):
            switch preset {
            case .today: Label("Today", systemImage: "calendar")
            case .week: Label("Past Week", systemImage: "calendar")
            case .month: Label("Past Month", systemImage: "calendar")
            case .year: Label("Past Year", systemImage: "calendar")
            }
        }
    }
}

/// Search results when a query is typed, the library otherwise.
struct ResultsArea: View {
    @Bindable var model: SearchModel
    let library: LibraryModel
    let services: GlintServices
    @Binding var layout: ResultsLayout

    private var isBrowsing: Bool { model.currentQuery.isEmpty && !model.isFindingSimilar }
    private var items: [SearchResult] { isBrowsing ? library.items : model.displayOrder }

    var body: some View {
        Group {
            if items.isEmpty {
                if let state = model.emptyState(status: services.status.status), state != .start {
                    PanelEmptyState(state: state, services: services)
                } else if services.status.status.sourceCount == 0 {
                    PanelEmptyState(state: .noSources, services: services)
                } else if !library.isLoading {
                    ContentUnavailableView(String(localized: "Nothing Here Yet"), systemImage: "tray")
                }
            } else if layout == .grid {
                grid
            } else {
                list
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.findSimilar(toFileAt: url)
            return true
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)], spacing: 16) {
                ForEach(items) { result in
                    ResultTile(result: result, showsMatch: !isBrowsing)
                        .padding(4)
                        .background {
                            if model.selection == result.id {
                                RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.22))
                            }
                        }
                        .contentShape(.rect(cornerRadius: 10))
                        // Select on the first click; a double-click before it would delay every single click.
                        .onTapGesture { model.selection = result.id }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { open(result) })
                        .onDrag { NSItemProvider(object: result.file.url as NSURL) }
                        .contextMenu { ResultContextMenu(result: result, model: model, services: services) }
                }
            }
            .padding()
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            if let selected = items.first(where: { $0.id == model.selection }) {
                services.actions?.quickLook(items, selected: selected)
            }
            return .handled
        }
        .onKeyPress(.return) {
            if let selected = items.first(where: { $0.id == model.selection }) { open(selected) }
            return .handled
        }
    }

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(items) { result in
                ResultRow(result: result, isSelected: model.selection == result.id, showsMatch: !isBrowsing)
                    .tag(result.id)
                    // `.onDrag` swallows clicks on List rows, breaking selection and double-click.
                    .itemProvider { NSItemProvider(object: result.file.url as NSURL) }
            }
        }
        .contextMenu(forSelectionType: FileID.self) { ids in
            if let id = ids.first, let result = items.first(where: { $0.id == id }) {
                ResultContextMenu(result: result, model: model, services: services)
            }
        } primaryAction: { ids in
            if let id = ids.first, let result = items.first(where: { $0.id == id }) { open(result) }
        }
        .onKeyPress(.space) {
            if let selected = items.first(where: { $0.id == model.selection }) {
                services.actions?.quickLook(items, selected: selected)
            }
            return .handled
        }
    }

    private func open(_ result: SearchResult) {
        services.actions?.open(result)
    }
}
