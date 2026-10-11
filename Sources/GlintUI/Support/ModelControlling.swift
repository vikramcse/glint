import Foundation
import Observation

/// What the UI shows about the search model.
public enum ModelUIState: Sendable, Hashable {
    /// The full model isn't on this Mac; search uses the built-in fallback.
    case notInstalled(downloadBytes: Int64)
    case downloading(received: Int64, total: Int64)
    case verifying
    /// Weights are on disk and the model is starting.
    case loading
    case active
    case failed(String)

    public var fraction: Double? {
        if case .downloading(let received, let total) = self, total > 0 { return Double(received) / Double(total) }
        return nil
    }

    public var isBusy: Bool {
        switch self {
        case .downloading, .verifying, .loading: true
        case .notInstalled, .active, .failed: false
        }
    }
}

/// Download, activation and presets of the search model. Implemented by the app.
@MainActor
public protocol ModelControlling: AnyObject, Observable {
    var state: ModelUIState { get }
    /// "EmbeddingGemma 2" or the fallback's name.
    var activeModelName: String { get }
    /// Output dimensions in use (Matryoshka preset).
    var dimensions: Int { get }
    /// Files waiting to be re-embedded after a model or preset change.
    var reembedding: Int { get }

    func download()
    func cancelDownload()
    func remove()
    /// Pro: 768 (best), 512 (balanced, default), 256 (compact). Re-embeds in the background.
    func setDimensions(_ dimensions: Int)
}

extension ModelUIState {
    /// One line for Settings and the menu bar.
    public var summary: String {
        switch self {
        case .notInstalled(let bytes):
            String(localized: "Download EmbeddingGemma 2 (\(bytes.formatted(.byteCount(style: .file)))) for the best search")
        case .downloading(let received, let total):
            String(
                localized: """
                    Downloading search model… \(received.formatted(.byteCount(style: .file))) \
                    of \(total.formatted(.byteCount(style: .file)))
                    """
            )
        case .verifying: String(localized: "Verifying search model…")
        case .loading: String(localized: "Starting search model…")
        case .active: String(localized: "EmbeddingGemma 2 is active")
        case .failed(let message): String(localized: "Model download failed: \(message)")
        }
    }
}
