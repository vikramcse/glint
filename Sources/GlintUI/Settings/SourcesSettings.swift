import GlintCore
import SwiftUI

struct SourcesSettings: View {
    let services: GlintServices
    @State private var selection: SourceID?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(services.status.sources) { source in
                        HStack {
                            Image(systemName: source.isExternalVolume ? "externaldrive" : "folder")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading) {
                                Text(source.displayName)
                                Text(verbatim: (source.path as NSString).abbreviatingWithTildeInPath)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if source.isAccessible {
                                Text("\(source.itemCount.formatted()) items").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Label("Can’t read", systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .tag(source.id)
                    }
                }
                .frame(minHeight: 120)
                HStack {
                    Button("Add Folder…") {
                        Task { errorMessage = await SourceAdder.pickAndAdd(services: services) }
                    }
                    Button("Remove", role: .destructive) {
                        guard let selection else { return }
                        Task {
                            try? await services.indexing.removeSource(selection)
                            await services.status.refreshSources()
                        }
                    }
                    .disabled(selection == nil)
                    Spacer()
                    if let limit = services.entitlements.snapshot.sourceLimit {
                        Text("\(services.status.sources.count) of \(limit) folders on Free")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Folders and drives")
            }

            Section("Excluded folders") {
                ForEach(services.status.exclusions.folders, id: \.self) { folder in
                    HStack {
                        Text(verbatim: (folder as NSString).abbreviatingWithTildeInPath)
                        Spacer()
                        Button {
                            var rules = services.status.exclusions
                            rules.folders.removeAll { $0 == folder }
                            update(rules)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Remove exclusion"))
                    }
                }
                Button("Exclude Folder…") {
                    guard
                        let url = services.actions?.chooseFolders(
                            message: String(localized: "Choose a folder Glint should skip"), allowsMultipleSelection: false
                        ).first
                    else { return }
                    var rules = services.status.exclusions
                    rules.folders.append(url.standardizedFileURL.path)
                    update(rules)
                }
                Toggle(
                    "Index hidden files",
                    isOn: Binding {
                        services.status.exclusions.includeHiddenFiles
                    } set: { value in
                        var rules = services.status.exclusions
                        rules.includeHiddenFiles = value
                        update(rules)
                    })
            }

            Section {
                Button("Open Full Disk Access Settings…") { services.actions?.openFullDiskAccessSettings() }
            } footer: {
                Text("Optional. Lets Glint index any folder you add, including ones macOS protects, without asking again.")
            }
        }
        .formStyle(.grouped)
    }

    private func update(_ rules: ExclusionRules) {
        Task {
            try? await services.indexing.setExclusions(rules)
            await services.status.refreshSources()
        }
    }
}
