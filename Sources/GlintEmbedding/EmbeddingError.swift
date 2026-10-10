import Foundation
import GlintCore

/// Errors from embedding providers.
public enum EmbeddingError: GlintError, Equatable {
    /// The model's assets are not on this Mac (not downloaded, or not available for the language).
    case modelUnavailable(String)
    /// The provider cannot encode this modality.
    case unsupportedModality(Modality)
    /// The model ran but produced no usable vector.
    case encodingFailed

    public var category: ErrorCategory {
        switch self {
        case .modelUnavailable, .encodingFailed: .model
        case .unsupportedModality: .unsupported
        }
    }

    public var description: String {
        switch self {
        case .modelUnavailable(let id): "Model \(id) is not available"
        case .unsupportedModality(let modality): "Modality \(modality.rawValue) is not supported"
        case .encodingFailed: "The model produced no vector"
        }
    }
}
