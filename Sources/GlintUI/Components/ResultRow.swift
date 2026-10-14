import AVKit
import GlintCore
import GlintSearch
import SwiftUI

/// One result in a list: photo, video moment, audio match, PDF page or document.
struct ResultRow: View {
    let result: SearchResult
    let isSelected: Bool
    var playback: InlinePlayback?
    /// False when browsing the library: the locator is just the first chunk, not a match.
    var showsMatch = true

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            leading
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(result.file.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !result.file.isIndexed {
                        Label("Not indexed yet", systemImage: "clock")
                            .labelStyle(.iconOnly)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(Text("Matched by name. Its contents become searchable once Glint indexes it."))
                    }
                }
                subtitle
                detail
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(AccessibilityText.label(for: result)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var leading: some View {
        switch result.file.kind {
        case .audio:
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary, in: .rect(cornerRadius: 6))
        default:
            ThumbnailView(url: result.match.thumbnailURL, filePath: result.file.path, kind: result.file.kind)
        }
    }

    @ViewBuilder private var subtitle: some View {
        HStack(spacing: 4) {
            if showsMatch, let location = Formatting.location(of: result.match.locator) {
                Text(location)
                    .monospacedDigit()
                    .foregroundStyle(.tint)
                Text(verbatim: "·")
            }
            Text(Formatting.folder(of: result.file.path))
                .truncationMode(.head)
            Text(verbatim: "·")
            Text(result.file.modified, format: .relative(presentation: .named, unitsStyle: .abbreviated))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder private var detail: some View {
        if result.file.kind == .audio || result.file.kind == .video, let waveform = result.file.waveform, !waveform.isEmpty {
            WaveformView(peaks: waveform, highlight: highlightRange, playhead: playheadFraction)
                .frame(height: 16)
                .frame(maxWidth: 260)
        } else if let snippet = result.match.snippet {
            SnippetText(snippet: snippet)
        }
    }

    @ViewBuilder private var trailing: some View {
        if let playback, let range = result.match.locator.timeRange {
            Button {
                playback.toggle(id: result.id, url: result.file.url, start: range.lowerBound, duration: result.file.duration)
            } label: {
                Image(systemName: playback.isPlaying(result.id) ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .help(playback.isPlaying(result.id) ? Text("Stop") : Text("Play from match"))
            .accessibilityLabel(playback.isPlaying(result.id) ? Text("Stop") : Text("Play from match"))
        }
    }

    private var highlightRange: ClosedRange<Double>? {
        guard showsMatch, let range = result.match.locator.timeRange, let duration = result.file.duration, duration > 0 else { return nil }
        return (range.lowerBound / duration)...(min(range.upperBound, duration) / duration)
    }

    private var playheadFraction: Double? {
        guard let playback, playback.isPlaying(result.id) else { return nil }
        return playback.progress
    }
}

/// A grid cell for the main window.
struct ResultTile: View {
    let result: SearchResult
    /// False when browsing the library: the locator is just the first chunk, not a match.
    var showsMatch = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                if result.file.kind == .audio {
                    WaveformView(peaks: result.file.waveform ?? [], highlight: nil)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.quaternary, in: .rect(cornerRadius: 8))
                } else {
                    ThumbnailView(url: result.match.thumbnailURL, filePath: result.file.path, kind: result.file.kind, cornerRadius: 8)
                }
                if showsMatch, let location = Formatting.location(of: result.match.locator) {
                    Text(location)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: .capsule)
                        .padding(5)
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            Text(result.file.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(AccessibilityText.label(for: result)))
    }
}
