import Foundation
import GlintCore

/// The one path every "Add Folder" button uses: pick folders, add them as sources, and report
/// what went wrong in words the user can act on.
@MainActor
public enum SourceAdder {
    /// Shows the folder picker and adds the chosen folders. Returns a message when some
    /// folders could not be added, or `nil` on success or cancel.
    @discardableResult
    public static func pickAndAdd(services: GlintServices) async -> String? {
        guard let actions = services.actions else { return nil }
        let urls = actions.chooseFolders(
            message: String(localized: "Choose folders for Glint to search"), allowsMultipleSelection: true)
        return await add(urls, services: services)
    }

    /// Adds `urls` as sources.
    @discardableResult
    public static func add(_ urls: [URL], services: GlintServices) async -> String? {
        guard !urls.isEmpty else { return nil }
        var failures: [String] = []
        for url in urls {
            do {
                try await services.indexing.addSource(url)
            } catch {
                failures.append("\(url.lastPathComponent): \(ErrorPresenter.message(for: error))")
            }
        }
        await services.status.refreshSources()
        return failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    /// Picks folders and shows any failure in an alert (for buttons without room for inline errors).
    public static func pickAndAddReportingErrors(services: GlintServices) {
        Task {
            if let message = await pickAndAdd(services: services) {
                services.actions?.presentError(message)
            }
        }
    }
}
