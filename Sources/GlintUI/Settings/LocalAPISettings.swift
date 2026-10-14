import AppKit
import GlintCore
import Observation
import SwiftUI

/// What the local API is doing, as the app reports it.
public enum LocalAPIDisplayStatus: Hashable, Sendable {
    case off
    case starting
    case running(port: UInt16)
    case failed(String)

    public var text: String {
        switch self {
        case .off: String(localized: "Off")
        case .starting: String(localized: "Starting…")
        case .running(let port): String(localized: "On · 127.0.0.1:\(String(port)) · this Mac only")
        case .failed(let message): message
        }
    }
}

/// The app's handle on the local API for Settings. The UI flips `AppSettings.localAPIEnabled`;
/// the app observes that setting, starts or stops the server, and updates `status`.
@MainActor
@Observable
public final class LocalAPIControl {
    public var status: LocalAPIDisplayStatus = .off
    /// Shell command that registers glint-mcp with Claude Code.
    public let mcpCommand: String
    /// Rotates the bearer token so every connected agent must reconnect.
    @ObservationIgnored public var resetAccess: (@MainActor () async -> Void)?

    public init(mcpCommand: String, resetAccess: (@MainActor () async -> Void)? = nil) {
        self.mcpCommand = mcpCommand
        self.resetAccess = resetAccess
    }
}

/// Settings › Privacy › Apps and agents.
struct LocalAPISection: View {
    let services: GlintServices
    let control: LocalAPIControl
    @State private var copied = false

    var body: some View {
        @Bindable var settings = services.settings
        Section {
            Toggle("Allow apps and agents to search Glint", isOn: $settings.localAPIEnabled)
            LabeledContent("Status") {
                Text(control.status.text)
                    .foregroundStyle(statusStyle)
                    .monospacedDigit()
            }
            if settings.localAPIEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add Glint to Claude Code:")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(verbatim: control.mcpCommand)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Spacer()
                        Button(copied ? String(localized: "Copied") : String(localized: "Copy")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(control.mcpCommand, forType: .string)
                            copied = true
                        }
                        .controlSize(.small)
                    }
                }
                if let reset = control.resetAccess {
                    Button("Reset Access…") { Task { await reset() } }
                        .help(Text("Issue a new access token; connected agents must reconnect."))
                }
            }
        } header: {
            Text("Apps and agents")
        } footer: {
            Text(
                """
                Agents on this Mac can search your index through Glint’s local API. It listens only on this Mac, \
                needs a private access token, and never sends anything off the device.
                """
            )
        }
    }

    private var statusStyle: AnyShapeStyle {
        switch control.status {
        case .running: AnyShapeStyle(.green)
        case .failed: AnyShapeStyle(.red)
        case .off, .starting: AnyShapeStyle(.secondary)
        }
    }
}
