import GlintCore
import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    let library: LibraryModel
    let people: PeopleModel?
    let services: GlintServices
    @State private var pendingRemoval: SourceInfo?

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("All Items", systemImage: "square.stack")
                    .badge(services.status.status.totalIndexed)
                    .tag(SidebarItem.all)
                ForEach(MediaKind.allCases.sorted(), id: \.self) { kind in
                    Label(kind.sectionTitle, systemImage: kind.symbolName)
                        .badge(services.status.status.indexed[kind] ?? 0)
                        .tag(SidebarItem.kind(kind))
                }
                if let people {
                    Label("People", systemImage: "person.2")
                        .badge(people.people.count)
                        .tag(SidebarItem.people)
                }
            }
            Section("Sources") {
                ForEach(services.status.sources) { source in
                    HStack {
                        Label(source.displayName, systemImage: source.symbolName)
                        Spacer(minLength: 4)
                        SourceStatusBadge(source: source, phase: services.status.status.phase)
                    }
                    .help(Text(verbatim: (source.path as NSString).abbreviatingWithTildeInPath))
                    .tag(SidebarItem.source(source.id))
                    .contextMenu {
                        Button("Re-index") { run { await SourceActions.reindex(source.id, services: services) } }
                        Divider()
                        Button("Remove…", role: .destructive) { pendingRemoval = source }
                    }
                }
                Button {
                    SourceAdder.pickAndAddReportingErrors(services: services)
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if !library.savedSearches.isEmpty {
                Section("Saved Searches") {
                    ForEach(library.savedSearches) { saved in
                        Label(saved.name, systemImage: "magnifyingglass")
                            .tag(SidebarItem.saved(saved.id))
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    Task { try? await library.deleteSavedSearch(saved.id) }
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .removeSourceConfirmation(for: $pendingRemoval) { source in
            if selection == .source(source.id) { selection = .all }
            if let message = await SourceActions.remove(source.id, services: services) {
                services.actions?.presentError(message)
            }
        }
    }

    private func run(_ action: @escaping @MainActor () async -> String?) {
        Task {
            if let message = await action() { services.actions?.presentError(message) }
        }
    }
}
