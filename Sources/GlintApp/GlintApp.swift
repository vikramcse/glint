import AppKit
import GlintUI
import SwiftUI

/// Glint: on-device multimodal search for Mac.
@main
struct GlintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            if let services = delegate.environment?.services {
                SettingsView(services: services)
                    .onAppear {
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate()
                    }
            }
        }

        MenuBarExtra(isInserted: menuBarInserted) {
            if let services = delegate.environment?.services {
                MenuBarContent(services: services) { delegate.showSearch() }
            }
        } label: {
            if let status = delegate.environment?.services.status {
                MenuBarLabel(status: status)
            } else {
                Image(systemName: "magnifyingglass")
            }
        }
    }

    /// The menu bar item hides when idle only if the user asked for that.
    private var menuBarInserted: Binding<Bool> {
        Binding {
            guard delegate.settings.hideMenuBarItemWhenIdle, let status = delegate.environment?.services.status else { return true }
            return status.status.isBusy || status.isPaused
        } set: { _ in
        }
    }
}
