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

    init(services: GlintServices, savedSearches: any SavedSearchProviding) {
        self.services = services
        self.savedSearches = savedSearches
    }

    // MARK: ResultActions

    func open(_ result: SearchResult) {
        let state = Signposts.search.beginInterval(Signposts.Name.openResult)
        defer { Signposts.search.endInterval(Signposts.Name.openResult, state) }
        panel?.hide()
        if let range = result.match.locator.timeRange, result.file.kind == .video || result.file.kind == .audio {
            showPlayer(for: result, start: range.lowerBound)
        } else {
            NSWorkspace.shared.open(result.file.url)
        }
    }

    func revealInFinder(_ results: [SearchResult]) {
        panel?.hide()
        NSWorkspace.shared.activateFileViewerSelecting(results.map(\.file.url))
    }

    func quickLook(_ results: [SearchResult], selected: SearchResult?) {
        let urls = results.filter { !$0.isLocked }.map(\.file.url)
        guard !urls.isEmpty else { return }
        let index = selected.flatMap { selected in urls.firstIndex(of: selected.file.url) } ?? 0
        panel?.keepOpenOnResign = true
        NSApp.activate()
        quickLook.show(urls, selectedIndex: index)
    }

    func copy(_ results: [SearchResult]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(results.map { $0.file.url as NSURL })
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

    func showOnboarding(onFinish: @escaping () -> Void) {
        let window = makeWindow(
            title: String(localized: "Welcome to Glint"),
            root: OnboardingView(services: services) { [weak self] in
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
        if window === upgradeWindow { upgradeWindow = nil }
        let anyOpen =
            [mainWindow, onboardingWindow, upgradeWindow].contains { $0?.isVisible == true && $0 !== window }
            || playerWindows.contains { $0.isVisible }
        if !anyOpen { NSApp.setActivationPolicy(.accessory) }
    }
}
