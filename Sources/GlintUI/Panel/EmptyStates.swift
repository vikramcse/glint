import GlintCore
import SwiftUI

/// Designed empty, still-indexing, no-results and no-sources states.
struct PanelEmptyState: View {
    let state: SearchEmptyState
    let services: GlintServices

    var body: some View {
        switch state {
        case .noSources:
            ContentUnavailableView {
                Label("No Folders Yet", systemImage: "folder.badge.plus")
            } description: {
                Text("Add a folder and Glint will start indexing it right away.")
            } actions: {
                Button("Add Folders…") { SourceAdder.pickAndAddReportingErrors(services: services) }
            }
        case .start:
            ContentUnavailableView {
                Label("Search Anything", systemImage: "sparkle.magnifyingglass")
            } description: {
                Text("Describe a photo, a moment in a video, something said in a recording, or a page in a document.")
            }
        case .stillIndexing(let pending):
            ContentUnavailableView {
                Label("No Results Yet", systemImage: "hourglass")
            } description: {
                Text("Glint is still indexing \(pending.formatted()) items. Results appear as soon as they’re ready.")
            }
        case .noResults:
            ContentUnavailableView {
                Label("No Results", systemImage: "magnifyingglass")
            } description: {
                Text("Try different words, or check that the folder is one of your sources.")
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Search Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        }
    }
}

/// Shown when a source folder can't be read.
public struct PermissionDeniedView: View {
    let openSettings: () -> Void

    public init(openSettings: @escaping () -> Void) {
        self.openSettings = openSettings
    }

    public var body: some View {
        ContentUnavailableView {
            Label("Glint Can’t Read This Folder", systemImage: "lock.shield")
        } description: {
            Text(
                """
                Allow access in System Settings › Privacy & Security. \
                Full Disk Access is optional and lets Glint index any folder you add.
                """
            )
        } actions: {
            Button("Open Privacy Settings", action: openSettings)
        }
    }
}
