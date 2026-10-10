import AVFoundation
import Foundation
import GlintCore
import Observation

/// Plays one matched moment at a time inline in results (audio and video previews).
@MainActor
@Observable
public final class InlinePlayback {
    public private(set) var playingID: FileID?
    public private(set) var progress: Double = 0
    @ObservationIgnored public private(set) var player: AVPlayer?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var duration: Double = 0

    public init() {}

    public func isPlaying(_ id: FileID) -> Bool { playingID == id }

    /// Plays `url` from `start` seconds, or stops if it is already playing.
    public func toggle(id: FileID, url: URL, start: Double, duration: Double?) {
        if playingID == id {
            stop()
            return
        }
        stop()
        let player = AVPlayer(url: url)
        self.duration = duration ?? 0
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) {
            [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.duration > 0 else { return }
                self.progress = min(1, time.seconds / self.duration)
            }
        }
        player.play()
        self.player = player
        playingID = id
    }

    public func stop() {
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
        playingID = nil
        progress = 0
    }
}
