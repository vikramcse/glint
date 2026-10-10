import GlintCore
import SwiftUI

/// The menu bar item's menu: indexing status, pause and resume, and ways into the app.
public struct MenuBarContent: View {
    let services: GlintServices
    let showSearch: () -> Void

    public init(services: GlintServices, showSearch: @escaping () -> Void) {
        self.services = services
        self.showSearch = showSearch
    }

    public var body: some View {
        let status = services.status
        Text(status.summary)
        if status.status.isBusy {
            Text("\(Int(status.status.progress * 100))% complete")
        }
        if status.status.locked > 0 {
            Text("\(status.status.locked.formatted()) video and audio files need Pro")
        }
        if let models = services.models, models.state.isBusy {
            Text(models.state.summary)
        }
        Divider()
        Button("Search…", action: showSearch)
        Button("Open Glint") { services.actions?.showMainWindow() }
            .keyboardShortcut("o")
        Divider()
        if status.isPaused, case .paused(.user) = status.status.phase {
            Button("Resume Indexing") { Task { await services.indexing.resume() } }
        } else {
            Button("Pause Indexing") { Task { await services.indexing.pause() } }
                .disabled(!status.status.isBusy && status.status.pending == 0)
        }
        Divider()
        if services.entitlements.showsUpgrade {
            Button("Upgrade to Pro…") { services.actions?.showUpgrade(.menu) }
        }
        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Glint") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// The menu bar icon; fills while indexing.
public struct MenuBarLabel: View {
    let status: IndexStatusModel

    public init(status: IndexStatusModel) {
        self.status = status
    }

    public var body: some View {
        Image(systemName: status.status.isBusy ? "sparkle.magnifyingglass" : "magnifyingglass")
            .accessibilityLabel(Text("Glint"))
    }
}
