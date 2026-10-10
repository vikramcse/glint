import GlintLicensing
import SwiftUI

/// License state, activation and deactivation. Every `LicenseState` has a designed row.
struct LicenseSettings: View {
    let services: GlintServices
    @State private var key = ""
    @State private var isWorking = false
    @State private var message: String?

    private var license: LicenseManager { services.license }

    var body: some View {
        Form {
            Section {
                LicenseStatusRow(state: license.state)
            }
            if license.entitlements.canActivate {
                Section("Activate") {
                    TextField(text: $key, prompt: Text(verbatim: "GLINT1-…")) { Text("License key") }
                        .font(.body.monospaced())
                        .onSubmit(activate)
                    HStack {
                        Button("Activate", action: activate)
                            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                        Button("Buy Glint Pro…") { services.actions?.openPurchasePage() }
                        if isWorking { ProgressView().controlSize(.small) }
                    }
                }
            } else {
                Section {
                    Button("Deactivate This Mac", role: .destructive) {
                        isWorking = true
                        Task {
                            do { try await license.deactivate() } catch { message = ErrorPresenter.message(for: error) }
                            isWorking = false
                        }
                    }
                    .disabled(isWorking)
                } footer: {
                    Text("Frees this Mac’s seat so you can use your license on another Mac.")
                }
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func activate() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isWorking = true
        message = nil
        Task {
            do {
                try await license.activate(key: trimmed)
                key = ""
                message = String(localized: "Glint Pro is active. Thank you!")
            } catch {
                message = ErrorPresenter.message(for: error)
            }
            isWorking = false
        }
    }
}

struct LicenseStatusRow: View {
    let state: LicenseState

    var body: some View {
        switch state {
        case .none:
            Label("Glint Free", systemImage: "seal")
        case .trial(let daysLeft, let endsAt):
            Label {
                VStack(alignment: .leading) {
                    Text("Pro trial: \(daysLeft) days left")
                    Text("Ends \(endsAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "hourglass")
            }
        case .trialExpired:
            Label {
                VStack(alignment: .leading) {
                    Text("Your Pro trial has ended")
                    Text("Search still works for photos, screenshots, documents and PDFs. Video and audio results stay visible but locked.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "seal")
            }
        case .active(let payload):
            Label {
                VStack(alignment: .leading) {
                    Text("Glint Pro is active")
                    Text("License for Glint \(payload.majorVersion).x on up to \(payload.seats) Macs").font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
        case .revoked:
            Label("This license is no longer active", systemImage: "xmark.seal")
                .foregroundStyle(.red)
        case .seatLimitReached:
            Label("This license is already active on 2 Macs", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }
}
