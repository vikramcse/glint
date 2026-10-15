import AppKit
import Quartz

/// Drives the shared Quick Look panel for a list of files.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// Read by Quick Look's data-source callbacks, which are not main-actor isolated.
    private let items = PreviewItems()
    /// Called once the Quick Look panel leaves the screen, however it was dismissed.
    var onClose: (() -> Void)?
    private var visibilityObserver: (any NSObjectProtocol)?

    func show(_ urls: [URL], selectedIndex: Int) {
        items.set(urls)
        guard let panel = QLPreviewPanel.shared() else {
            onClose?()
            return
        }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(0, selectedIndex), max(0, urls.count - 1))
        if panel.isVisible {
            panel.orderOut(nil)
            onClose?()
        } else {
            observeClosing(panel)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Quick Look closes with Space, Esc or its close button, and only some of those close the
    /// window, so watch for it leaving the screen instead.
    private func observeClosing(_ panel: QLPreviewPanel) {
        guard visibilityObserver == nil else { return }
        let name = NSWindow.didChangeOcclusionStateNotification
        visibilityObserver = NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = QLPreviewPanel.shared(), !panel.isVisible else { return }
                if let observer = self.visibilityObserver { NotificationCenter.default.removeObserver(observer) }
                self.visibilityObserver = nil
                self.onClose?()
            }
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
