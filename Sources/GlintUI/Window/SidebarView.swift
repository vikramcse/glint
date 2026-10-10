import GlintCore
import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    let library: LibraryModel
    let services: GlintServices

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("All Items", systemImage: "square.stack")
                    .badge(services.status.status.totalIndexed)
                    .tag(SidebarItem.all)
                ForEach(MediaKind.allCases.sorted(), id: \.self) { kind in
                    HStack {
                        Label(kind.sectionTitle, systemImage: kind.symbolName)
                        if !services.entitlements.allows(kind) {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(Text("Requires Glint Pro"))
                        }
                    }
                    .badge(services.status.status.indexed[kind] ?? 0)
                    .tag(SidebarItem.kind(kind))
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
    }
}
