import GlintLicensing
import SwiftUI

/// The upgrade sheet: what Pro adds, the price, and a way to buy or enter a key.
public struct UpgradeView: View {
    let services: GlintServices
    let reason: PaywallReason
    let onClose: (() -> Void)?
    @Environment(\.dismiss) private var environmentDismiss
    @State private var key = ""
    @State private var message: String?
    @State private var isWorking = false

    /// - Parameter onClose: closes the hosting window; falls back to the environment's dismiss.
    public init(services: GlintServices, reason: PaywallReason, onClose: (() -> Void)? = nil) {
        self.services = services
        self.reason = reason
        self.onClose = onClose
    }

    private func dismiss() {
        if let onClose { onClose() } else { environmentDismiss() }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text("Glint Pro").font(.title.bold())
                    Text(headline).foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Text("Free").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Pro").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                }
                row("Photos, screenshots, documents, PDF text", free: true)
                row("Video moments and audio search", free: false)
                row("PDF and slide visuals (charts, scans)", free: false)
                row("Find similar", free: false)
                row("Unlimited items, folders and external drives", free: false)
                row("Full filters and saved searches", free: false)
            }
            Text("One-time purchase. All 1.x updates on two Macs.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button {
                    services.actions?.openPurchasePage()
                } label: {
                    Text("Buy Glint Pro — $49").frame(minWidth: 160)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .accessibilityIdentifier("upgrade.buy")
                Spacer()
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("upgrade.notNow")
            }
            Divider()
            HStack {
                TextField(text: $key, prompt: Text("Already have a key?")) { Text("License key") }
                    .font(.body.monospaced())
                    .onSubmit(activate)
                    .accessibilityIdentifier("upgrade.key")
                Button("Activate", action: activate)
                    .accessibilityIdentifier("upgrade.activate")
                    .disabled(key.isEmpty || isWorking)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("upgrade.message")
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear { services.report(.paywallViewed(reason)) }
    }

    private var headline: String {
        switch reason {
        case .itemLimit: String(localized: "You’ve reached the 10,000 items included with Glint Free.")
        case .lockedResult: String(localized: "Open video moments and audio matches with Pro.")
        case .sourceLimit: String(localized: "Add unlimited folders and external drives with Pro.")
        case .menu, .feature: String(localized: "Search everything you have, to the second.")
        }
    }

    private func row(_ title: LocalizedStringKey, free: Bool) -> some View {
        GridRow {
            Text(title)
            Image(systemName: free ? "checkmark" : "minus")
                .foregroundStyle(free ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .accessibilityLabel(free ? Text("Included in Free") : Text("Not in Free"))
            Image(systemName: "checkmark")
                .foregroundStyle(.tint)
                .accessibilityLabel(Text("Included in Pro"))
        }
    }

    private func activate() {
        isWorking = true
        Task {
            do {
                try await services.license.activate(key: key.trimmingCharacters(in: .whitespacesAndNewlines))
                dismiss()
            } catch {
                message = ErrorPresenter.message(for: error)
            }
            isWorking = false
        }
    }
}
