import GlintCore
import GlintSearch
import SwiftUI

/// Preview, metadata, the matched moment or page, and similar items.
struct InspectorView: View {
    let result: SearchResult?
    let model: SearchModel
    let services: GlintServices
    @State private var similar: [SearchResult] = []
    @State private var playback = InlinePlayback()

    var body: some View {
        if let result {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    preview(result)
                    Text(result.file.name)
                        .font(.headline)
                        .textSelection(.enabled)
                    match(result)
                    metadata(result)
                    actions(result)
                    similarSection
                }
                .padding()
            }
            .task(id: result.id) { await loadSimilar(result) }
            // The view stays the same across selections, so stop the previous file's moment.
            .onChange(of: result.id) { playback.stop() }
            .onDisappear { playback.stop() }
        } else {
            ContentUnavailableView(String(localized: "No Selection"), systemImage: "sidebar.trailing")
        }
    }

    @ViewBuilder private func preview(_ result: SearchResult) -> some View {
        if result.file.kind == .audio {
            WaveformView(
                peaks: result.file.waveform ?? [], highlight: highlight(result),
                playhead: playback.isPlaying(result.id) ? playback.progress : nil
            )
            .frame(height: 64)
        } else {
            ThumbnailView(
                url: result.match.thumbnailURL, filePath: result.file.path, kind: result.file.kind, cornerRadius: 10, contentMode: .fit
            )
            .frame(maxWidth: .infinity, maxHeight: 240)
        }
    }

    @ViewBuilder private func match(_ result: SearchResult) -> some View {
        if let range = result.match.locator.timeRange {
            HStack {
                Label {
                    Text("Moment at \(Formatting.timecode(range.lowerBound))")
                } icon: {
                    Image(systemName: "clock")
                }
                Spacer()
                Button {
                    playback.toggle(id: result.id, url: result.file.url, start: range.lowerBound, duration: result.file.duration)
                } label: {
                    Label(
                        playback.isPlaying(result.id) ? "Stop" : "Play",
                        systemImage: playback.isPlaying(result.id) ? "stop.fill" : "play.fill")
                }
            }
        } else if let page = result.match.locator.pageIndex {
            Button {
                services.actions?.open(result)
            } label: {
                Label {
                    Text("Page \(page + 1)")
                } icon: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
            }
            .buttonStyle(.link)
            .help(Text("Open the PDF at this page"))
        }
        if let snippet = result.match.snippet {
            SnippetText(snippet: snippet, lineLimit: 8)
                .textSelection(.enabled)
        }
    }

    private func metadata(_ result: SearchResult) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Kind").foregroundStyle(.secondary)
                Text(result.file.kind.displayName)
            }
            GridRow {
                Text("Size").foregroundStyle(.secondary)
                Text(Formatting.bytes(result.file.size))
            }
            if let duration = result.file.duration {
                GridRow {
                    Text("Duration").foregroundStyle(.secondary)
                    Text(Formatting.timecode(duration)).monospacedDigit()
                }
            }
            GridRow {
                Text("Modified").foregroundStyle(.secondary)
                Text(result.file.modified, format: .dateTime)
            }
            GridRow {
                Text("Where").foregroundStyle(.secondary)
                Text(Formatting.folder(of: result.file.path))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
    }

    private func actions(_ result: SearchResult) -> some View {
        HStack {
            Button("Open") { services.actions?.open(result) }
                .keyboardShortcut(.defaultAction)
            Button("Show in Finder") { services.actions?.revealInFinder([result]) }
        }
    }

    @ViewBuilder private var similarSection: some View {
        if !similar.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Similar Items").font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(similar.prefix(9)) { item in
                        ThumbnailView(url: item.match.thumbnailURL, filePath: item.file.path, kind: item.file.kind)
                            .aspectRatio(1, contentMode: .fit)
                            .contentShape(.rect)
                            .help(Text(verbatim: item.file.name))
                            .onTapGesture { model.selection = item.id }
                            .onTapGesture(count: 2) { services.actions?.open(item) }
                            .accessibilityElement()
                            .accessibilityLabel(Text(AccessibilityText.label(for: item)))
                            .accessibilityAddTraits(.isButton)
                    }
                }
            }
        }
    }

    private func loadSimilar(_ result: SearchResult) async {
        similar = []
        guard result.file.isIndexed else { return }
        similar = (try? await services.engine.similar(to: result.id).items) ?? []
    }

    private func highlight(_ result: SearchResult) -> ClosedRange<Double>? {
        guard let range = result.match.locator.timeRange, let duration = result.file.duration, duration > 0 else { return nil }
        return (range.lowerBound / duration)...(min(range.upperBound, duration) / duration)
    }
}
