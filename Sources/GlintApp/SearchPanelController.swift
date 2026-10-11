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
            // Borderless: a titled window's title-bar safe area feeds back into SwiftUI's
            // preferred size and loops the constraint pass.
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
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
    var onHide: (() -> Void)?

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
        let content = PanelHostView(content: SearchPanelView(model: model, services: services)) { [weak self] height in
            self?.resize(toHeight: height)
        }
        let host = NSHostingController(rootView: content)
        // The panel is sized explicitly from the measured content height. Automatic sizing lets
        // the window's height feed back into the content's size and loops the constraint pass.
        host.sizingOptions = []
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
        if isVisible { hide() } else { show() }
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
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        onHide?()
    }

    /// Grows and shrinks downward from a fixed top edge as results come and go, like Spotlight.
    private func resize(toHeight height: CGFloat) {
        let height = ceil(height)
        var frame = panel.frame
        guard abs(frame.height - height) > 0.5 else { return }
        let top = frame.maxY
        frame.size = NSSize(width: SearchPanelController.width, height: height)
        frame.origin.y = top - height
        panel.setFrame(frame, display: panel.isVisible)
    }

    static let width: CGFloat = 720

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

/// Gives the panel content a definite height and reports it, independent of the window size.
private struct PanelHostView: View {
    let content: SearchPanelView
    let onHeightChange: (CGFloat) -> Void

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                onHeightChange($0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
    }
}
