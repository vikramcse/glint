import AppKit
import GlintCore
import GlintUI
import SwiftUI

/// A borderless, floating, non-activating panel: it takes keyboard focus without pulling the
/// app (and its windows) in front of what the user was doing, like Spotlight.
final class FloatingPanel: NSPanel {
    var onResignKey: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 80),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        setAccessibilityLabel(String(localized: "Glint Search"))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// Shows and hides the search panel; keeps one search model alive so reopening is instant.
@MainActor
final class SearchPanelController {
    private let panel = FloatingPanel()
    private let model: SearchModel
    /// While Quick Look is up, losing key status must not dismiss the panel.
    var keepOpenOnResign = false

    init(services: GlintServices) {
        model = SearchModel(
            engine: services.engine,
            entitlements: { services.entitlements },
            sourcePaths: { services.status.sources.map(\.path) },
            report: services.report
        )
        model.groupByKind = services.settings.groupResultsByKind
        model.scope = services.settings.defaultKinds
        if !services.settings.hasSearched {
            model.onFirstSearch = { services.settings.hasSearched = true }
        }
        let host = NSHostingController(rootView: SearchPanelView(model: model, services: services))
        host.sizingOptions = [.preferredContentSize]
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        panel.contentViewController = host
        panel.onResignKey = { [weak self] in
            guard let self, !self.keepOpenOnResign else { return }
            self.hide()
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let state = Signposts.search.beginInterval(Signposts.Name.panelShow)
        position()
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            Signposts.search.endInterval(Signposts.Name.panelShow, state)
        }
    }

    func hide() {
        keepOpenOnResign = false
        panel.orderOut(nil)
    }

    func applySettings(_ settings: AppSettings) {
        model.groupByKind = settings.groupResultsByKind
        model.scope = settings.defaultKinds
    }

    /// Centers horizontally on the screen with the mouse, in the upper third, like Spotlight.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.72 - size.height)
        panel.setFrameTopLeftPoint(NSPoint(x: origin.x, y: origin.y + size.height))
    }
}
