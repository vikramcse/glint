import AppKit
import Quartz

/// Drives the shared Quick Look panel for a list of files.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// Read by Quick Look's data-source callbacks, which are not main-actor isolated.
    private let items = PreviewItems()

    func show(_ urls: [URL], selectedIndex: Int) {
        items.set(urls)
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(0, selectedIndex), max(0, urls.count - 1))
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel?) -> Int {
        items.count
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel?, previewItemAt index: Int) -> (any QLPreviewItem)? {
        items.url(at: index).map { $0 as NSURL }
    }
}

private final class PreviewItems: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func set(_ newValue: [URL]) { lock.withLock { urls = newValue } }
    var count: Int { lock.withLock { urls.count } }
    func url(at index: Int) -> URL? { lock.withLock { urls.indices.contains(index) ? urls[index] : nil } }
}
