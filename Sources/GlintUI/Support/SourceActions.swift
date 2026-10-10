import GlintCore
import SwiftUI

/// Re-index and remove for a source, shared by Settings and the sidebar.
@MainActor
enum SourceActions {
    /// Queues every file in the source to be indexed again. Returns a message on failure.
    static func reindex(_ id: SourceID, services: GlintServices) async -> String? {
        defer { Task { await services.status.refreshSources() } }
        do {
            try await services.indexing.reindexSource(id)
            return nil
        } catch {
            return ErrorPresenter.message(for: error)
        }
    }

    /// Removes the source and everything indexed from it. Returns a message on failure.
    static func remove(_ id: SourceID, services: GlintServices) async -> String? {
        defer { Task { await services.status.refreshSources() } }
        do {
            try await services.indexing.removeSource(id)
            return nil
        } catch {
            return ErrorPresenter.message(for: error)
        }
    }
}

extension View {
    /// Asks before removing `source`, since its index is deleted with it.
    func removeSourceConfirmation(
        for source: Binding<SourceInfo?>, perform: @escaping @MainActor (SourceInfo) async -> Void
    ) -> some View {
        confirmationDialog(
            Text("Remove “\(source.wrappedValue?.displayName ?? "")”?"),
            isPresented: Binding {
                source.wrappedValue != nil
            } set: {
                if !$0 { source.wrappedValue = nil }
            },
            presenting: source.wrappedValue
        ) { item in
            Button("Remove", role: .destructive) { Task { await perform(item) } }
        } message: { _ in
            Text("Glint stops watching this folder and deletes everything it indexed from it. Your files are not touched.")
        }
    }
}
