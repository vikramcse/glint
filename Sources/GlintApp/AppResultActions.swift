import AppKit
import GlintCore
import GlintSearch
import GlintUI
import SwiftUI

/// AppKit implementations of result actions, plus the app's own windows.
@MainActor
final class AppResultActions: ResultActions {
    private let services: GlintServices
    private let savedSearches: any SavedSearchProviding
    private let quickLook = QuickLookController()
    weak var panel: SearchPanelController?
    private var mainWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var upgradeWindow: NSWindow?
    private var playerWindows: [NSWindow] = []
    private var windowObservers: [any NSObjectProtocol] = []
    private var pdfWindows: [NSWindow] = []
    private let photos: (any PhotoLibraryProviding)?

    init(services: GlintServices, savedSearches: any SavedSearchProviding, photos: (any PhotoLibraryProviding)? = nil) {
        self.services = services
        self.savedSearches = savedSearches
        self.photos = photos
    }

    // MARK: ResultActions

    func open(_ result: SearchResult) {
        let state = Signposts.search.beginInterval(Signposts.Name.openResult)
        defer { Signposts.search.endInterval(Signposts.Name.openResult, state) }
        panel?.hide()
        if PhotosLibraryPath.isAsset(result.file.path) {
            // Photos has no public way to open one asset, so preview the local original.
            quickLook([result], selected: result)
        } else if let range = result.match.locator.timeRange, result.file.kind == .video || result.file.kind == .audio {
            showPlayer(for: result, start: range.lowerBound)
        } else if result.file.kind == .pdf {
            showPDF(PDFMatchTarget(result: result), title: result.file.name)
        } else {
            NSWorkspace.shared.open(result.file.url)
        }
    }

    func revealInFinder(_ results: [SearchResult]) {
        panel?.hide()
        let files = results.filter { !PhotosLibraryPath.isAsset($0.file.path) }.map(\.file.url)
        if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
        if files.count < results.count, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func quickLook(_ results: [SearchResult], selected: SearchResult?) {
        let candidates = results.filter { !$0.isLocked }
        guard !candidates.isEmpty else { return }
        panel?.keepOpenOnResign = true
        Task {
            let urls = await localURLs(for: candidates)
            guard !urls.isEmpty else { return }
            let selectedIndex = selected.flatMap { selected in candidates.firstIndex { $0.id == selected.id } } ?? 0
            NSApp.activate()
            quickLook.show(urls, selectedIndex: min(selectedIndex, urls.count - 1))
        }
    }

    func copy(_ results: [SearchResult]) {
        Task {
            let urls = await localURLs(for: results)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects(urls.map { $0 as NSURL })
        }
    }

    /// File URLs for results; Photos assets are exported (without network access) to a cache.
    private func localURLs(for results: [SearchResult]) async -> [URL] {
        var urls: [URL] = []
        for result in results {
            guard let identifier = PhotosLibraryPath.assetIdentifier(fromPath: result.file.path) else {
                urls.append(result.file.url)
                continue
            }
            guard let photos else { continue }
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Glint/PhotosExports", isDirectory: true)
                .appendingPathComponent(identifier.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
            if let existing = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first {
                urls.append(existing)
                continue
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                urls.append(try await photos.exportOriginal(assetIdentifier: identifier, to: folder))
            } catch {
                Log.app.notice("Could not export a Photos asset: \(error.localizedDescription, privacy: .public)")
            }
        }
        return urls
    }

    func dismissPanel() {
        panel?.hide()
    }

    func showMainWindow() {
        panel?.hide()
        if mainWindow == nil {
            let window = makeWindow(
                title: String(localized: "Glint"),
                root: MainWindowView(services: services, savedSearches: savedSearches),
                size: NSSize(width: 1_100, height: 700),
                style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            )
            window.setFrameAutosaveName("GlintMainWindow")
            mainWindow = window
        }
        present(mainWindow)
    }

    func showUpgrade(_ reason: PaywallReason) {
        panel?.hide()
        upgradeWindow?.close()
        let window = makeWindow(
            title: String(localized: "Glint Pro"),
            root: UpgradeView(services: services, reason: reason) { [weak self] in self?.upgradeWindow?.close() },
            size: NSSize(width: 500, height: 520),
            style: [.titled, .closable, .fullSizeContentView]
        )
        upgradeWindow = window
        present(window)
    }

    func openPurchasePage() {
        if let url = AppConfiguration.current.purchasePage { NSWorkspace.shared.open(url) }
    }

    func openFullDiskAccessSettings() {
        if let url = AppConfiguration.fullDiskAccessSettings { NSWorkspace.shared.open(url) }
    }

    func chooseFolders(message: String, allowsMultipleSelection: Bool) -> [URL] {
        // The floating panel hides when it loses focus; bring it back after the picker.
        let reopenPanel = panel?.isVisible == true
        panel?.hide()
        NSApp.activate()
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = false
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.message = message
        picker.prompt = String(localized: "Choose")
        picker.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        let response = picker.runModal()
        if reopenPanel { panel?.show() }
        return response == .OK ? picker.urls : []
    }

    func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Some folders couldn’t be added")
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate()
        if let window = NSApp.keyWindow, window.isVisible, !(window is NSPanel) {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: Onboarding and player

    func showOnboarding(suggestions: [URL]? = nil, onFinish: @escaping () -> Void) {
        let window = makeWindow(
            title: String(localized: "Welcome to Glint"),
            root: OnboardingView(services: services, suggestions: suggestions) { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                onFinish()
            },
            size: NSSize(width: 620, height: 500),
            style: [.titled, .closable, .fullSizeContentView]
        )
        onboardingWindow = window
        present(window)
    }

    private func showPDF(_ target: PDFMatchTarget, title: String) {
        let window = makeWindow(
            title: title, root: PDFPageViewer(target: target), size: NSSize(width: 760, height: 900),
            style: [.titled, .closable, .miniaturizable, .resizable]
        )
        pdfWindows.append(window)
        present(window)
    }

    private func showPlayer(for result: SearchResult, start: Double) {
        let window = makeWindow(
            title: result.file.name,
            root: MomentPlayerView(result: result, start: start),
            size: NSSize(width: 720, height: result.file.kind == .audio ? 160 : 460),
            style: [.titled, .closable, .miniaturizable, .resizable]
        )
        playerWindows.append(window)
        present(window)
    }

    // MARK: Windows

    private func makeWindow<Content: View>(title: String, root: Content, size: NSSize, style: NSWindow.StyleMask) -> NSWindow {
        let host = NSHostingController(rootView: root)
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: host)
        window.title = title
        window.styleMask = style
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
            [weak self] notification in
            let closed = notification.object as? NSWindow
            MainActor.assumeIsolated { self?.windowClosed(closed) }
        }
        windowObservers.append(observer)
        return window
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        // Glint lives in the menu bar; it shows in the Dock only while a window is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func windowClosed(_ window: NSWindow?) {
        playerWindows.removeAll { $0 === window }
        pdfWindows.removeAll { $0 === window }
        if window === upgradeWindow { upgradeWindow = nil }
        let anyOpen =
            [mainWindow, onboardingWindow, upgradeWindow].contains { $0?.isVisible == true && $0 !== window }
            || playerWindows.contains { $0.isVisible } || pdfWindows.contains { $0.isVisible }
        if !anyOpen { NSApp.setActivationPolicy(.accessory) }
    }
}
