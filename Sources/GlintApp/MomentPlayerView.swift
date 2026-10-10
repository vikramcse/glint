import AVKit
import GlintSearch
import GlintUI
import SwiftUI

/// Plays a video or audio file from the matched moment.
struct MomentPlayerView: View {
    let result: SearchResult
    let start: Double
    @State private var player: AVPlayer

    init(result: SearchResult, start: Double) {
        self.result = result
        self.start = start
        _player = State(initialValue: AVPlayer(url: result.file.url))
    }

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: player)
                .frame(minWidth: 480, minHeight: result.file.kind == .audio ? 80 : 270)
            HStack {
                Label {
                    Text("Moment at \(Formatting.timecode(start))")
                } icon: {
                    Image(systemName: "clock")
                }
                .monospacedDigit()
                Spacer()
                Button("Replay Moment") { seekAndPlay() }
                Button("Open in Default App") { NSWorkspace.shared.open(result.file.url) }
            }
            .padding(10)
        }
        .onAppear(perform: seekAndPlay)
        .onDisappear { player.pause() }
    }

    private func seekAndPlay() {
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in player.play() }
        }
    }
}
