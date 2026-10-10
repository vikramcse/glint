import GlintCore
import GlintLicensing
import SwiftUI

/// The standard Settings window: General, Sources, Search, Models, Privacy, License.
public struct SettingsView: View {
    let services: GlintServices

    public init(services: GlintServices) {
        self.services = services
    }

    public var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings(services: services) }
            Tab("Sources", systemImage: "folder") { SourcesSettings(services: services) }
            Tab("Search", systemImage: "magnifyingglass") { SearchSettings(settings: services.settings) }
            Tab("Models", systemImage: "cpu") { ModelsSettings(services: services) }
            Tab("Privacy", systemImage: "hand.raised") { PrivacySettings(services: services) }
            Tab("License", systemImage: "checkmark.seal") { LicenseSettings(services: services) }
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
                Text("Type kind:video, in:Downloads or date:week in the search field to filter. Folder and date filters need Pro.")
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
                ForEach(services.modelDescription.options) { option in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(option.name)
                            Text(option.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if option.isActive {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                                .accessibilityLabel(Text("In use"))
                        } else if !option.isAvailable {
                            Text("Coming soon").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !services.entitlements.allows(.modelChoice) {
                    Text("Choosing a model and quality preset is part of Glint Pro.")
                        .font(.callout).foregroundStyle(.secondary)
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
    @State private var preview = ""
    @State private var confirmingDelete = false
    @State private var deleteError: String?

    var body: some View {
        @Bindable var settings = services.settings
        Form {
            Section {
                Toggle("Share anonymous usage statistics", isOn: $settings.analyticsEnabled)
                Text("About ten events like “search took 40–80 ms”. Never your searches, file names, paths or contents.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.analyticsEnabled {
                    DisclosureGroup("Data waiting to be sent") {
                        ScrollView {
                            Text(verbatim: preview.isEmpty ? "—" : preview)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 90)
                    }
                }
            }
            if let control = services.localAPI {
                LocalAPISection(services: services, control: control)
            }
            Section("Network activity") {
                Label("One-time model download", systemImage: "arrow.down.circle")
                Label("Update checks", systemImage: "arrow.triangle.2.circlepath")
                Label("License activation and weekly check", systemImage: "checkmark.seal")
                Label("Anonymous statistics, if turned on", systemImage: "chart.bar")
                Text("Nothing about your files ever leaves this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Delete Index…", role: .destructive) { confirmingDelete = true }
                if let deleteError { Text(deleteError).foregroundStyle(.red).font(.caption) }
            } footer: {
                Text(
                    "Removes everything Glint derived from your files. Your files are not touched; Glint re-indexes your folders afterwards."
                )
            }
        }
        .formStyle(.grouped)
        .task(id: settings.analyticsEnabled) { preview = await services.analyticsPreview() }
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
