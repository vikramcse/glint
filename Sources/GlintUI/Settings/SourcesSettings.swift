import GlintCore
import SwiftUI

struct SourcesSettings: View {
    let services: GlintServices
    @State private var selection: SourceID?
    @State private var errorMessage: String?
    @State private var isUpdatingPhotos = false
    @State private var pendingRemoval: SourceInfo?
    @State private var isAddingBucket = false

    private var photosSource: SourceInfo? { services.status.sources.first(where: \.isPhotosLibrary) }
    private var selectedSource: SourceInfo? { services.status.sources.first { $0.id == selection } }

    /// On adds the library (asking for Photos access the first time); off removes it.
    private var photosBinding: Binding<Bool> {
        Binding {
            photosSource != nil
        } set: { isOn in
            guard isOn != (photosSource != nil) else { return }
            isUpdatingPhotos = true
            Task {
                do {
                    if isOn {
                        try await services.indexing.addSource(PhotosLibraryPath.libraryURL)
                    } else if let id = photosSource?.id {
                        try await services.indexing.removeSource(id)
                    }
                    errorMessage = nil
                } catch {
                    errorMessage =
                        isOn && error.glintCategory == .permissionDenied
                        ? String(localized: "Glint needs access to Photos. Allow it in System Settings › Privacy & Security › Photos.")
                        : ErrorPresenter.message(for: error)
                }
                await services.status.refreshSources()
                isUpdatingPhotos = false
            }
        }
    }

    var body: some View {
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(services.status.sources) { source in
                        HStack {
                            Image(systemName: source.symbolName)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading) {
                                Text(source.displayName)
                                Text(verbatim: Self.subtitle(for: source))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            SourceStatusView(source: source, phase: services.status.status.phase)
                        }
                        .padding(.vertical, 2)
                        .tag(source.id)
                    }
                }
                .frame(minHeight: 140)
                HStack {
                    Menu("Add") {
                        Button("Folder or Network Share…") {
                            Task { errorMessage = await SourceAdder.pickAndAdd(services: services) }
                        }
                        Button("S3 Bucket…") { isAddingBucket = true }
                    }
                    .fixedSize()
                    Button("Re-index") {
                        guard let selection else { return }
                        Task { errorMessage = await SourceActions.reindex(selection, services: services) }
                    }
                    .disabled(selection == nil)
                    Button("Remove", role: .destructive) { pendingRemoval = selectedSource }
                        .disabled(selection == nil)
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Folders, drives and cloud storage")
            }

            Section {
                Toggle(isOn: photosBinding) {
                    Label("Apple Photos Library", systemImage: "photo.on.rectangle.angled")
                }
                .disabled(isUpdatingPhotos)
            } footer: {
                Text("Searches photos and videos whose originals are on this Mac. Nothing is downloaded from iCloud.")
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
        .sheet(isPresented: $isAddingBucket) {
            S3SourceSheet(services: services) { isAddingBucket = false }
        }
        .removeSourceConfirmation(for: $pendingRemoval) { source in
            if selection == source.id { selection = nil }
            errorMessage = await SourceActions.remove(source.id, services: services)
        }
    }

    static func subtitle(for source: SourceInfo) -> String {
        if source.isPhotosLibrary { return String(localized: "Photos and videos stored on this Mac") }
        if let remote = source.remote { return remote.locationDescription }
        return (source.path as NSString).abbreviatingWithTildeInPath
    }

    private func update(_ rules: ExclusionRules) {
        Task {
            try? await services.indexing.setExclusions(rules)
            await services.status.refreshSources()
        }
    }
}
