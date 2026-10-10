import SwiftUI

/// Settings › Models: which model is active, download progress, and the quality preset.
struct ModelStatusView: View {
    let models: any ModelControlling
    let canChoose: Bool
    let showUpgrade: () -> Void
    @State private var confirmingRemoval = false

    var body: some View {
        LabeledContent("Search model") {
            Text(models.activeModelName)
        }
        switch models.state {
        case .notInstalled:
            VStack(alignment: .leading, spacing: 6) {
                Text(models.state.summary)
                Text("Finds photos, video moments and audio by meaning, in any language. Runs entirely on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Download") { models.download() }
            }
        case .downloading:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: models.state.fraction ?? 0) {
                    Text(models.state.summary).font(.callout)
                }
                Button("Cancel", role: .cancel) { models.cancelDownload() }
            }
        case .verifying, .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text(models.state.summary)
            }
        case .active:
            if models.reembedding > 0 {
                Text("Updating \(models.reembedding.formatted()) items for the new model. Keyword search works meanwhile.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker(
                "Quality",
                selection: Binding(
                    get: { models.dimensions },
                    set: { value in
                        if canChoose { models.setDimensions(value) } else { showUpgrade() }
                    })
            ) {
                Text("Best (768)").tag(768)
                Text("Balanced (512)").tag(512)
                Text("Compact (256)").tag(256)
            }
            .help(Text("Higher quality uses more disk and memory. Changing it updates the index in the background."))
            if !canChoose {
                Text("Quality presets are part of Glint Pro.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Remove Model…", role: .destructive) { confirmingRemoval = true }
                .confirmationDialog(Text("Remove EmbeddingGemma 2?"), isPresented: $confirmingRemoval) {
                    Button("Remove", role: .destructive) { models.remove() }
                } message: {
                    Text("Search falls back to the basic built-in model until you download it again.")
                }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).foregroundStyle(.red).font(.callout)
                Button("Try Again") { models.download() }
            }
        }
    }
}
