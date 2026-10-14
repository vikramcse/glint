import GlintCore
import SwiftUI

/// Three screens, under a minute: what Glint does, which folders, and the shortcut.
public struct OnboardingView: View {
    let services: GlintServices
    let onFinish: () -> Void
    @State private var step = 0
    @State private var choices = SuggestedFolder.defaults()
    @State private var extraFolders: [URL] = []
    @State private var isFinishing = false
    @State private var downloadModel = true

    /// - Parameter suggestions: folders to pre-select; `nil` suggests Desktop, Documents,
    ///   Downloads and Screenshots.
    public init(services: GlintServices, suggestions: [URL]? = nil, onFinish: @escaping () -> Void) {
        self.services = services
        self.onFinish = onFinish
        if let suggestions {
            _choices = State(
                initialValue: suggestions.map {
                    SuggestedFolder(name: $0.lastPathComponent, symbol: "folder", url: $0, isSelected: true)
                })
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: sources
                default: shortcut
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
            Divider()
            HStack {
                PageDots(count: 3, current: step)
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1 }
                        .keyboardShortcut(.cancelAction)
                }
                Button(step == 2 ? String(localized: "Start Searching") : String(localized: "Continue")) {
                    if step == 2 { finish() } else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isFinishing || (step == 1 && selectedFolders.isEmpty))
                .accessibilityIdentifier(step == 2 ? "onboarding.start" : "onboarding.continue")
            }
            .padding(16)
        }
        .frame(width: 620, height: 500)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 20) {
            DemoLoop()
                .frame(height: 220)
            Text("Find anything by describing it").font(.title.bold())
            Text(
                """
                Photos, moments in videos, things said in recordings, pages in PDFs. \
                Glint searches them all at once, entirely on this Mac.
                """
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 460)
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose what to search").font(.title2.bold())
            Text("Glint indexes your newest files first, so you can search within minutes.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach($choices) { $choice in
                    Toggle(isOn: $choice.isSelected) {
                        Label(choice.name, systemImage: choice.symbol)
                    }
                }
                ForEach(extraFolders, id: \.self) { url in
                    Label(url.lastPathComponent, systemImage: "folder")
                }
                Button("Add Another Folder…") {
                    let chosen =
                        services.actions?.chooseFolders(
                            message: String(localized: "Choose folders for Glint to search"), allowsMultipleSelection: true) ?? []
                    extraFolders.append(contentsOf: chosen.filter { !extraFolders.contains($0) })
                }
                .padding(.top, 4)
            }
            GroupBox {
                HStack(alignment: .top) {
                    Image(systemName: "lock.shield").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("macOS asks before Glint reads protected folders. Full Disk Access is optional and avoids repeated prompts.")
                            .font(.callout)
                        Button("Open Full Disk Access Settings…") { services.actions?.openFullDiskAccessSettings() }
                            .buttonStyle(.link)
                    }
                }
            }
        }
    }

    private var shortcut: some View {
        @Bindable var settings = services.settings
        return VStack(alignment: .leading, spacing: 20) {
            Text("Search from anywhere").font(.title2.bold())
            HStack {
                Text("Press")
                HotKeyRecorder(combo: $settings.hotKey)
                Text("to open Glint in any app.")
            }
            if let models = services.models, case .notInstalled(let bytes) = models.state {
                Divider()
                Toggle(isOn: $downloadModel) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Download EmbeddingGemma 2 (\(bytes.formatted(.byteCount(style: .file))))")
                        Text(
                            """
                            Finds photos, video moments and audio by what's in them. Downloads once, then works offline. \
                            Search works by name and text meanwhile.
                            """
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
    }

    // MARK: Finish

    private var selectedFolders: [URL] {
        choices.filter(\.isSelected).map(\.url) + extraFolders
    }

    private func finish() {
        isFinishing = true
        let folders = selectedFolders
        if downloadModel { services.models?.download() }
        Task {
            let failures = await SourceAdder.add(folders, services: services)
            services.settings.hasCompletedOnboarding = true
            onFinish()
            if let failures { services.actions?.presentError(failures) }
        }
    }
}

/// A suggested source folder on the onboarding screen.
struct SuggestedFolder: Identifiable, Hashable {
    var name: String
    var symbol: String
    var url: URL
    var isSelected: Bool

    var id: URL { url }

    static func defaults() -> [SuggestedFolder] {
        let manager = FileManager.default
        var folders: [SuggestedFolder] = []
        func add(_ directory: FileManager.SearchPathDirectory, _ name: String, _ symbol: String) {
            if let url = manager.urls(for: directory, in: .userDomainMask).first {
                folders.append(SuggestedFolder(name: name, symbol: symbol, url: url, isSelected: true))
            }
        }
        add(.desktopDirectory, String(localized: "Desktop"), "menubar.dock.rectangle")
        add(.documentDirectory, String(localized: "Documents"), "doc")
        add(.downloadsDirectory, String(localized: "Downloads"), "arrow.down.circle")
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let url = URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true)
            if !folders.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                folders.append(
                    SuggestedFolder(name: String(localized: "Screenshots"), symbol: "camera.viewfinder", url: url, isSelected: true))
            }
        }
        return folders
    }
}

struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Step \(current + 1) of \(count)"))
    }
}

/// A five-second loop: a query is typed and matching moments appear. Static with Reduce Motion.
struct DemoLoop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let query = String(localized: "crowd cheering at night")
    private struct Row {
        let symbol: String
        let name: String
        let time: String
    }

    private let rows = [
        Row(symbol: "film", name: String(localized: "Festival.mov"), time: "12:04"),
        Row(symbol: "waveform", name: String(localized: "Voice memo 14.m4a"), time: "3:18"),
        Row(symbol: "photo", name: String(localized: "IMG_2041.HEIC"), time: ""),
    ]

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let phase = reduceMotion ? 4.0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 5)
            let typed = query.prefix(Int(min(1, phase / 1.6) * Double(query.count)))
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text(String(typed)).font(.title3)
                    Spacer()
                }
                .padding(10)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10))
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    let visible = phase > 1.9 + Double(index) * 0.35
                    HStack {
                        Image(systemName: row.symbol).frame(width: 36, height: 28).background(.quaternary, in: .rect(cornerRadius: 5))
                        Text(row.name)
                        Spacer()
                        Text(row.time).monospacedDigit().foregroundStyle(.tint)
                    }
                    .opacity(visible ? 1 : 0)
                    .offset(y: visible ? 0 : 6)
                }
            }
            .padding(14)
            .frame(width: 380)
            .background(.background.secondary, in: .rect(cornerRadius: 14))
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Example: searching for crowd cheering at night finds a video moment, a voice memo and a photo."))
    }
}
