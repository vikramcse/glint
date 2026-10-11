import GlintCore
import SwiftUI

/// Where one folder stands, derived from its counts and the indexer's phase.
public enum SourceIndexState: Hashable, Sendable {
    /// macOS denied access, or the drive is unplugged.
    case unreadable
    /// The folder has just been added and its files are being listed.
    case scanning
    case indexing(done: Int, total: Int)
    case paused(PauseReason, done: Int, total: Int)
    /// Everything that can be indexed now is searchable.
    case complete(indexed: Int)
    /// No files Glint can search were found.
    case empty

    public init(source: SourceInfo, phase: IndexStatus.Phase) {
        let total = source.indexed + source.pending
        if !source.isAccessible {
            self = .unreadable
        } else if source.itemCount == 0 {
            self = phase == .scanning ? .scanning : .empty
        } else if source.pending == 0 {
            self = .complete(indexed: source.indexed)
        } else if case .paused(let reason) = phase {
            self = .paused(reason, done: source.indexed, total: total)
        } else {
            self = .indexing(done: source.indexed, total: total)
        }
    }

    public var title: String {
        switch self {
        case .unreadable: String(localized: "Can’t read this folder")
        case .scanning: String(localized: "Looking for files…")
        case .indexing(let done, let total): String(localized: "Indexing \(done.formatted()) of \(total.formatted())")
        case .paused(let reason, let done, let total):
            if reason == .itemLimitReached {
                String(localized: "Free limit reached · \(done.formatted()) of \(total.formatted())")
            } else {
                String(localized: "Paused · \(done.formatted()) of \(total.formatted())")
            }
        case .complete(let indexed): String(localized: "Indexed · \(indexed.formatted()) items")
        case .empty: String(localized: "No searchable files")
        }
    }

    /// Indexing is running for this folder right now.
    public var isActive: Bool {
        if case .indexing = self { true } else { false }
    }

    public var fraction: Double? {
        switch self {
        case .indexing(let done, let total), .paused(_, let done, let total):
            total == 0 ? nil : Double(done) / Double(total)
        default: nil
        }
    }
}

/// Status line for a folder in Settings: icon, text, progress bar and footnotes.
struct SourceStatusView: View {
    let source: SourceInfo
    let phase: IndexStatus.Phase

    var body: some View {
        let state = SourceIndexState(source: source, phase: phase)
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 5) {
                SourceStatusBadge(source: source, phase: phase)
                Text(state.title)
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(state == .unreadable ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            if let fraction = state.fraction {
                ProgressBar(fraction: fraction, isActive: state.isActive)
                    .frame(width: 150, height: 4)
            }
            if let footnote = Self.footnote(for: source) {
                Text(footnote).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(Self.accessibilityLabel(source: source, state: state)))
    }

    static func footnote(for source: SourceInfo) -> String? {
        var parts: [String] = []
        if source.locked > 0 {
            parts.append(String(localized: "\(source.locked.formatted()) video and audio files need Pro"))
        }
        if source.failed > 0 {
            parts.append(String(localized: "\(source.failed.formatted()) couldn’t be read"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func accessibilityLabel(source: SourceInfo, state: SourceIndexState) -> String {
        ([state.title] + (footnote(for: source).map { [$0] } ?? [])).joined(separator: ", ")
    }
}

/// A compact indicator for sidebars: progress ring while indexing, checkmark when done.
struct SourceStatusBadge: View {
    let source: SourceInfo
    let phase: IndexStatus.Phase

    var body: some View {
        let state = SourceIndexState(source: source, phase: phase)
        Group {
            switch state {
            case .unreadable:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .scanning:
                ProgressView().controlSize(.mini)
            case .indexing(let done, let total):
                ProgressRing(fraction: total == 0 ? 0 : Double(done) / Double(total))
            case .paused:
                Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
            case .complete:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .empty:
                Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .frame(width: 14, height: 14)
        .help(Text(SourceStatusView.accessibilityLabel(source: source, state: state)))
        .accessibilityLabel(Text(state.title))
    }
}

/// A thin determinate bar: accent fill while active, secondary while paused.
struct ProgressBar: View {
    let fraction: Double
    var isActive = true

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: max(4, geometry.size.width * min(1, max(0, fraction))))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A small determinate ring that reads clearly at caption size.
struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.03, min(1, fraction)))
                .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(1)
    }
}

/// The main window's bottom bar while indexing: overall progress plus pause and resume.
struct IndexingStatusBar: View {
    let services: GlintServices

    var body: some View {
        let model = services.status
        let status = model.status
        HStack(spacing: 10) {
            if status.isBusy {
                ProgressRing(fraction: status.progress).frame(width: 14, height: 14)
            } else {
                Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
            }
            Text(model.summary).monospacedDigit()
            if status.isBusy, status.pending > 0 {
                ProgressBar(fraction: status.progress, isActive: true)
                    .frame(maxWidth: 220, maxHeight: 4)
            }
            Spacer()
            if case .paused(.itemLimitReached) = status.phase {
                Button("Upgrade…") { services.actions?.showUpgrade(.itemLimit) }
            } else if case .paused(.user) = status.phase {
                Button("Resume") { Task { await services.indexing.resume() } }
            } else if status.isBusy {
                Button("Pause") { Task { await services.indexing.pause() } }
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
    }

    static func isVisible(_ status: IndexStatus) -> Bool {
        if status.isBusy { return true }
        if case .paused = status.phase { return true }
        return false
    }
}
