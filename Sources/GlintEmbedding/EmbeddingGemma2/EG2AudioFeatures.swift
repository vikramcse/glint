import Foundation
import MLX

/// Gemma 4 log-mel features: 20 ms Hann frames every 10 ms, 512-point FFT magnitude, 128 HTK
/// mel bins up to 8 kHz, log(mel + 0.001). Port of `Gemma4AudioFeatureExtractor`.
struct EG2AudioFeatureExtractor: Sendable {
    var sampleRate = 16_000
    var melBins = 128
    var frameLength = 320
    var hopLength = 160
    var fftLength = 512
    var melFloor: Float = 0.001
    /// The reference truncates at 30 s.
    var maxSamples = 480_000
    var padToMultipleOf = 128

    struct Output {
        /// (frames, 128).
        var features: MLXArray
        /// (frames,) true for frames of real audio.
        var mask: [Bool]
    }

    func callAsFunction(_ samples: [Float]) -> Output {
        var waveform = Array(samples.prefix(maxSamples))
        let realLength = waveform.count
        let target = ((max(waveform.count, 1) + padToMultipleOf - 1) / padToMultipleOf) * padToMultipleOf
        waveform += [Float](repeating: 0, count: target - waveform.count)

        let padLeft = frameLength / 2
        let padded = [Float](repeating: 0, count: padLeft) + waveform
        let attention = [Bool](repeating: false, count: padLeft) + (0..<target).map { $0 < realLength }
        let unfoldSize = frameLength + 1
        let frameCount = max(0, (padded.count - unfoldSize) / hopLength + 1)

        var frames = [Float](repeating: 0, count: frameCount * frameLength)
        for frame in 0..<frameCount {
            let start = frame * hopLength
            for n in 0..<frameLength { frames[frame * frameLength + n] = padded[start + n] * Self.window[n] }
        }
        let framesArray = MLXArray(frames, [frameCount, frameLength])
        let spectrum = abs(rfft(framesArray, n: fftLength, axis: -1))
        let mel = matmul(spectrum, MLXArray(Self.melFilterValues, [257, melBins]))
        let logMel = log(mel + melFloor)
        let mask = (0..<frameCount).map { attention[$0 * hopLength + unfoldSize - 1] }
        return Output(features: logMel, mask: mask)
    }

    /// Soft tokens the audio contributes: the mask after two stride-2 subsamplings.
    static func tokenCount(mask: [Bool]) -> Int {
        var current = mask
        for _ in 0..<2 {
            let outputLength = (current.count + 2 - 3) / 2 + 1
            current = Array(stride(from: 0, to: current.count, by: 2).map { current[$0] }.prefix(outputLength))
        }
        return current.filter { $0 }.count
    }

    static let window: [Float] = (0..<320).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / 320) }

    /// HTK mel filter bank (257 × 128, row-major), as `transformers.audio_utils.mel_filter_bank`.
    static let melFilterValues: [Float] = {
        let bins = 257
        let filters = 128
        func hzToMel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
        func melToHz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2595) - 1) }
        let melMin = hzToMel(0)
        let melMax = hzToMel(8_000)
        let points = (0..<(filters + 2)).map { melToHz(melMin + (melMax - melMin) * Double($0) / Double(filters + 1)) }
        var bank = [Float](repeating: 0, count: bins * filters)
        for bin in 0..<bins {
            let frequency = Double(bin) * 8_000 / Double(bins - 1)
            for filter in 0..<filters {
                let down = (frequency - points[filter]) / (points[filter + 1] - points[filter])
                let up = (points[filter + 2] - frequency) / (points[filter + 2] - points[filter + 1])
                bank[bin * filters + filter] = Float(max(0, min(down, up)))
            }
        }
        return bank
    }()
}
