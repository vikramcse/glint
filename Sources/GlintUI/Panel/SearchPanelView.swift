import GlintCore
import GlintSearch
import SwiftUI
import UniformTypeIdentifiers

/// Content of the floating search panel summoned by the global hotkey.
public struct SearchPanelView: View {
    @Bindable var model: SearchModel
    let services: GlintServices
    @State private var playback = InlinePlayback()
    /// Set once the user arrows into the results; Space and ⌘C then act on the selected result.
    @State private var navigatingResults = false
    @State private var isDropTargeted = false
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: SearchModel, services: GlintServices) {
        self.model = model
        self.services = services
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchField
            if showsBody {
                Divider()
                content
                    .frame(maxHeight: 460)
                Divider()
                footer
            }
        }
        .frame(width: 720)
        .modifier(PanelBackground())
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: PanelBackground.cornerRadius)
                    .strokeBorder(.tint, lineWidth: 3)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.findSimilar(toFileAt: url)
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
        .onAppear {
            fieldFocused = true
            services.status.start()
        }
        .onDisappear { playback.stop() }
        .onChange(of: model.text) { navigatingResults = false }
    }

    private var showsBody: Bool {
        !model.results.isEmpty || model.isFindingSimilar || !model.currentQuery.isEmpty || services.status.status.sourceCount == 0
    }

    // MARK: Field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if let name = model.similarExampleName {
                TokenChip(title: String(localized: "Similar to \(name)")) { model.clear() }
            }
            TextField(text: $model.text, prompt: Text("Search anything")) {
                Text("Search")
            }
            .textFieldStyle(.plain)
            .font(.system(size: 22))
            .focused($fieldFocused)
            .accessibilityIdentifier("panel.search")
            .onKeyPress(phases: .down, action: handleKey)
            .onSubmit(openSelection)
            .accessibilityHint(Text("Type to search. Use the arrow keys to choose a result."))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: Results

    @ViewBuilder private var content: some View {
        if let state = model.emptyState(status: services.status.status) {
            PanelEmptyState(state: state, services: services)
                .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    // Not lazy: the panel sizes itself to this content's ideal height, and a lazy
                    // stack's estimate changes with the rows it has built, which change with the
                    // panel's height. With legacy scroll bars that never settled. Results are
                    // capped (SearchEngine.resultLimit), so building them all is cheap.
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.sections) { section in
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(section.results) { result in
                                row(result)
                            }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: model.selection) { _, selection in
                    guard let selection else { return }
                    if reduceMotion {
                        proxy.scrollTo(selection)
                    } else {
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(selection) }
                    }
                }
            }
        }
    }

    private func row(_ result: SearchResult) -> some View {
        let isSelected = model.selection == result.id
        return ResultRow(result: result, isSelected: isSelected, playback: playback)
            .padding(.horizontal, 8)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.22))
                }
            }
            .id(result.id)
            .accessibilityIdentifier("result.\(result.file.name)")
            .onTapGesture(count: 2) { open(result) }
            .onTapGesture { model.selection = result.id }
            .onDrag { NSItemProvider(object: result.file.url as NSURL) }
            .contextMenu { ResultContextMenu(result: result, model: model, services: services) }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if services.status.status.isBusy || services.status.isPaused {
                Text(services.status.summary)
            }
            Spacer()
            KeyHint(keys: "↩", label: Text("Open"))
            KeyHint(keys: "␣", label: Text("Quick Look"))
            KeyHint(keys: "⌘↩", label: Text("Show in Finder"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .downArrow:
            navigatingResults = true
            model.moveSelection(by: 1)
            return .handled
        case .upArrow:
            navigatingResults = true
            model.moveSelection(by: -1)
            return .handled
        case .escape:
            if model.text.isEmpty, !model.isFindingSimilar {
                services.actions?.dismissPanel()
            } else {
                model.clear()
            }
            return .handled
        case .return where press.modifiers.contains(.command):
            if let result = model.selectedResult { services.actions?.revealInFinder([result]) }
            return .handled
        case .space where navigatingResults:
            if let result = model.selectedResult { services.actions?.quickLook(model.displayOrder, selected: result) }
            return .handled
        default:
            return handleCommandShortcut(press)
        }
    }

    /// ⌘C copies the selected result while navigating results; ⌘Y opens Quick Look.
    private func handleCommandShortcut(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command), let result = model.selectedResult else { return .ignored }
        if press.characters == "c", navigatingResults {
            services.actions?.copy([result])
            return .handled
        }
        if press.characters == "y" {
            services.actions?.quickLook(model.displayOrder, selected: result)
            return .handled
        }
        return .ignored
    }

    private func openSelection() {
        if let result = model.selectedResult { open(result) }
    }

    private func open(_ result: SearchResult) {
        playback.stop()
        services.actions?.open(result)
    }
}

/// Liquid Glass on macOS 26, a system material before.
struct PanelBackground: ViewModifier {
    static let cornerRadius: CGFloat = 22

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: Self.cornerRadius))
        } else {
            content
                .background(.regularMaterial, in: .rect(cornerRadius: Self.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius).strokeBorder(.separator))
        }
    }
}

struct KeyHint: View {
    let keys: String
    let label: Text

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: keys)
                .font(.caption.monospaced())
                .padding(.horizontal, 4)
                .background(.quaternary, in: .rect(cornerRadius: 3))
            label
        }
        .accessibilityElement(children: .combine)
    }
}

struct TokenChip: View {
    let title: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Remove"))
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.tint.opacity(0.2), in: .capsule)
    }
}

/// Context menu shared by the panel and the main window.
struct ResultContextMenu: View {
    let result: SearchResult
    let model: SearchModel
    let services: GlintServices

    var body: some View {
        Button("Open") {
            services.actions?.open(result)
        }
        Button("Quick Look") { services.actions?.quickLook([result], selected: result) }
        Button("Show in Finder") { services.actions?.revealInFinder([result]) }
        Button("Copy") { services.actions?.copy([result]) }
        Divider()
        Button("Find Similar") { model.findSimilar(to: result) }
    }
}
