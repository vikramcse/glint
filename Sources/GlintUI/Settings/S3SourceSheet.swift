import GlintCore
import SwiftUI

/// S3-compatible services with known endpoints. Choosing one fills in the endpoint, region and
/// addressing style; everything stays editable.
enum S3Preset: String, CaseIterable, Identifiable {
    case aws, r2, backblaze, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aws: String(localized: "Amazon S3")
        case .r2: String(localized: "Cloudflare R2")
        case .backblaze: String(localized: "Backblaze B2")
        case .other: String(localized: "Other (MinIO, Wasabi…)")
        }
    }

    var region: String {
        switch self {
        case .aws, .other: "us-east-1"
        case .r2: "auto"
        case .backblaze: "us-west-004"
        }
    }

    /// The endpoint for `region`; `<account-id>` is left for the user to fill in for R2.
    func endpoint(region: String) -> String {
        switch self {
        case .aws: "https://s3.\(region).amazonaws.com"
        case .r2: "https://<account-id>.r2.cloudflarestorage.com"
        case .backblaze: "https://s3.\(region).backblazeb2.com"
        case .other: ""
        }
    }

    var pathStyle: Bool { self == .r2 || self == .other }
}

/// Adds an S3-compatible bucket, or a prefix in one.
struct S3SourceSheet: View {
    let services: GlintServices
    let onDone: () -> Void

    @State private var preset = S3Preset.aws
    @State private var endpoint = S3Preset.aws.endpoint(region: S3Preset.aws.region)
    @State private var region = S3Preset.aws.region
    @State private var bucket = ""
    @State private var folder = ""
    @State private var accessKeyID = ""
    @State private var secretKey = ""
    @State private var pathStyle = false
    @State private var isWorking = false
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                bucketFields
                credentialFields
                Section {
                    TextField("Folder (prefix)", text: $folder, prompt: Text("Whole bucket"))
                } footer: {
                    Text(
                        """
                        Glint lists the files here every 15 minutes and downloads each one once to index it. \
                        Copies are deleted right after; only the index stays on this Mac.
                        """)
                }
            }
            .formStyle(.grouped)
            if let message {
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(message.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 20)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { onDone() }
                    .keyboardShortcut(.cancelAction)
                Button("Test Connection") { Task { await test() } }
                    .disabled(!isComplete || isWorking)
                Button("Add") { Task { await add() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isComplete || isWorking)
            }
            .padding(20)
        }
        .frame(width: 500)
        .navigationTitle(Text(verbatim: RemoteService.s3.displayName))
    }

    // MARK: Fields

    @ViewBuilder private var bucketFields: some View {
        Section {
            Picker("Service", selection: $preset) {
                ForEach(S3Preset.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: preset) { _, preset in
                region = preset.region
                endpoint = preset.endpoint(region: region)
                pathStyle = preset.pathStyle
            }
            TextField("Endpoint", text: $endpoint, prompt: Text(verbatim: "https://s3.example.com"))
            TextField("Region", text: $region)
                .onChange(of: region) { _, region in
                    if preset == .aws || preset == .backblaze { endpoint = preset.endpoint(region: region) }
                }
            TextField("Bucket", text: $bucket)
            Toggle("Path-style addressing", isOn: $pathStyle)
        }
    }

    @ViewBuilder private var credentialFields: some View {
        Section {
            TextField("Access key ID", text: $accessKeyID)
            SecureField("Secret access key", text: $secretKey)
        } header: {
            Text("Credentials")
        } footer: {
            Text("Use a key that can only list and read this bucket. The secret is stored in your Keychain.")
        }
    }

    private var isComplete: Bool {
        !bucket.trimmed.isEmpty && !accessKeyID.trimmed.isEmpty && !secretKey.isEmpty && endpoint.hasPrefix("http")
            && !endpoint.contains("<")
    }

    private var config: RemoteSourceConfig {
        RemoteSourceConfig(
            service: .s3, endpoint: endpoint.trimmed, region: region.trimmed, bucket: bucket.trimmed, folder: folder.trimmed,
            accessKeyID: accessKeyID.trimmed, pathStyle: pathStyle)
    }

    // MARK: Actions

    private func test() async {
        isWorking = true
        message = nil
        do {
            let count = try await services.indexing.checkRemoteSource(config, secret: secretKey)
            message = (String(localized: "Connected. Glint can index \(count.formatted()) files here."), false)
        } catch {
            message = (ErrorPresenter.message(for: error), true)
        }
        isWorking = false
    }

    private func add() async {
        isWorking = true
        message = (String(localized: "Connecting…"), false)
        do {
            try await services.indexing.addRemoteSource(config, secret: secretKey)
            await services.status.refreshSources()
            onDone()
        } catch {
            message = (ErrorPresenter.message(for: error), true)
        }
        isWorking = false
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
