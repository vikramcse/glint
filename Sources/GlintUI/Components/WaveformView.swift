import SwiftUI

/// Whole-file waveform with the matched window highlighted and an optional playhead.
struct WaveformView: View {
    let peaks: [Float]
    /// Matched window as fractions of the file duration.
    var highlight: ClosedRange<Double>?
    var playhead: Double?

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let barWidth = size.width / CGFloat(peaks.count)
            let midY = size.height / 2
            for (index, peak) in peaks.enumerated() {
                let x = CGFloat(index) * barWidth
                let fraction = (Double(index) + 0.5) / Double(peaks.count)
                let height = max(1.5, CGFloat(peak) * size.height)
                let rect = CGRect(x: x + barWidth * 0.15, y: midY - height / 2, width: max(1, barWidth * 0.7), height: height)
                let isMatch = highlight?.contains(fraction) ?? false
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth * 0.35), with: .color(isMatch ? .accentColor : .secondary.opacity(0.45)))
            }
            if let playhead {
                let x = size.width * CGFloat(playhead)
                context.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.primary))
            }
        }
        .accessibilityHidden(true)
    }
}
