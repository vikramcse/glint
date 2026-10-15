import GlintCore
import SwiftUI

/// The standard Settings window: General, Sources, Search, Models, Privacy.
public struct SettingsView: View {
    let services: GlintServices

    public init(services: GlintServices) {
        self.services = services
    }

    public var body: some View {
        TabView {
            GeneralSettings(services: services).tabItem { Label("General", systemImage: "gearshape") }
            SourcesSettings(services: services).tabItem { Label("Sources", systemImage: "folder") }
            SearchSettings(settings: services.settings).tabItem { Label("Search", systemImage: "magnifyingglass") }
            ModelsSettings(services: services).tabItem { Label("Models", systemImage: "cpu") }
            PrivacySettings(services: services).tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .scenePadding()
        .frame(width: 560, height: 440)
        .onAppear { services.status.start() }
    }
}

struct GeneralSettings: View {
    let services: GlintServices

    var body: some View {
        @Bindable var settings = services.settings
        Form {
            LabeledContent("Search shortcut") {
                HotKeyRecorder(combo: $settings.hotKey)
            }
            Toggle("Open at login", isOn: $settings.launchAtLogin)
            Toggle("Hide menu bar item when idle", isOn: $settings.hideMenuBarItemWhenIdle)
            if let updates = services.updates, updates.isAvailable {
                Section("Updates") {
                    Toggle(
                        "Automatically check for updates",
                        isOn: Binding {
                            updates.automaticallyChecksForUpdates
                        } set: {
                            updates.automaticallyChecksForUpdates = $0
                        })
                    Button("Check for Updates…") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct SearchSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Toggle("Group results by kind", isOn: $settings.groupResultsByKind)
            Section("Search these kinds by default") {
                ForEach(MediaKind.allCases.sorted(), id: \.self) { kind in
                    Toggle(
                        kind.sectionTitle,
                        isOn: Binding {
                            settings.defaultKinds.isEmpty || settings.defaultKinds.contains(kind)
                        } set: { isOn in
                            var kinds = settings.defaultKinds.isEmpty ? Set(MediaKind.allCases) : settings.defaultKinds
                            if isOn { kinds.insert(kind) } else { kinds.remove(kind) }
                            settings.defaultKinds = kinds.count == MediaKind.allCases.count ? [] : kinds
                        })
                }
            }
            Section {
                Text("Type kind:video, in:Downloads or date:week in the search field to filter.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ModelsSettings: View {
    let services: GlintServices
    @State private var storage: Int64?

    var body: some View {
        @Bindable var settings = services.settings
        Form {
            Section("Model") {
                if let models = services.models {
                    ModelStatusView(models: models)
                } else {
                    ForEach(services.modelDescription.options) { option in
                        LabeledContent(option.name, value: option.detail)
                    }
                }
            }
            Section("Indexing") {
                Toggle("Index video only when plugged in", isOn: $settings.videoOnlyOnPower)
                Toggle("Transcribe speech in audio and video", isOn: $settings.transcribeAudio)
                Text("Transcripts are made on this Mac and make spoken words searchable by keyword.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Storage") {
                LabeledContent("Index and thumbnails") {
                    if let storage { Text(Formatting.bytes(storage)) } else { ProgressView().controlSize(.small) }
                }
            }
        }
        .formStyle(.grouped)
        .task { storage = await services.storageUsage() }
    }
}

struct PrivacySettings: View {
    let services: GlintServices
    @State private var confirmingDelete = false
    @State private var deleteError: String?

    var body: some View {
        Form {
            if let control = services.localAPI {
                LocalAPISection(services: services, control: control)
            }
            Section("Network activity") {
                Label("One-time model download", systemImage: "arrow.down.circle")
                Label("Update checks", systemImage: "arrow.triangle.2.circlepath")
                Text("Nothing about your files ever leaves this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Delete Index…", role: .destructive) { confirmingDelete = true }
                if let deleteError { Text(deleteError).foregroundStyle(.red).font(.caption) }
            } footer: {
                Text(
                    """
                    Removes everything Glint derived from your files. \
                    Your files are not touched; Glint re-indexes your folders afterwards.
                    """
                )
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(Text("Delete the index?"), isPresented: $confirmingDelete) {
            Button("Delete Index", role: .destructive) {
                Task {
                    do { try await services.indexing.deleteIndex() } catch { deleteError = ErrorPresenter.message(for: error) }
                }
            }
        } message: {
            Text("Search results will be empty until Glint re-indexes your folders.")
        }
    }
}
