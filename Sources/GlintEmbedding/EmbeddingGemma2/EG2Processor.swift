import CoreGraphics
import Foundation
import GlintCore
import MLX

/// Turns Glint inputs into EmbeddingGemma 2 token sequences, following the reference
/// processor and chat template: text gets a task prompt; each image becomes
/// `<boi> <image>×n <eoi>`, each video frame `<boi> <video>×n <eoi>`, and audio
/// `<boa> <audio>×n <eoa>`; media alone carries no prompt.
struct EG2Processor: @unchecked Sendable {
    let tokenizer: EG2Tokenizer
    let config: EG2Configuration
    var imageProcessor = EG2ImageProcessor(maxSoftTokens: 280)
    var frameProcessor = EG2ImageProcessor(maxSoftTokens: 140)
    var audioFeatures = EG2AudioFeatureExtractor()
    /// Longest token sequence embedded; long text is truncated (chunks are ~512 tokens).
    var maxTokens = 2_048

    static let queryPrompt = "task: search result | query: "
    static let documentPrompt = "title: none | text: "
    static let bosToken = 2
    static let eosToken = 1

    /// One prepared sequence with its media.
    struct Item {
        var ids: [Int32]
        var images: [EG2ImageProcessor.Output] = []
        var frames: [EG2ImageProcessor.Output] = []
        var audio: [EG2AudioFeatureExtractor.Output] = []
    }

    func prepare(_ input: EmbeddingInput, purpose: EmbeddingPurpose) throws -> Item {
        var item = Item(ids: [Int32(Self.bosToken)])
        let parts: [EmbeddingInput] =
            if case .interleaved(let parts) = input { parts } else { [input] }
        let hasText = parts.contains {
            switch $0 {
            case .text, .document: true
            default: false
            }
        }
        if hasText {
            append(text: prompt(for: parts, purpose: purpose), to: &item)
        }
        for part in parts { try append(part, to: &item) }
        let mediaTokens = Set(
            [config.imageTokenId, config.videoTokenId, config.audioTokenId, config.eoiTokenId, config.eoaTokenIndex].map(Int32.init))
        item.ids = try Self.closed(item.ids, maxTokens: maxTokens, mediaTokens: mediaTokens)
        return item
    }

    /// `ids` closed with <eos> in at most `maxTokens` tokens: trailing text is trimmed to fit,
    /// but never media, whose spans must stay whole.
    static func closed(_ ids: [Int32], maxTokens: Int, mediaTokens: Set<Int32>) throws -> [Int32] {
        var ids = ids
        if ids.count > maxTokens - 1 {
            // Room for <eos> leaves `maxTokens - 1` tokens; media past that can't be kept.
            if let lastMedia = ids.lastIndex(where: mediaTokens.contains), lastMedia >= maxTokens - 1 {
                throw EG2Error.inputTooLong(tokens: ids.count)
            }
            ids = Array(ids.prefix(maxTokens - 1))
        }
        // The reference tokenizer closes every sequence with <eos>, and it takes part in pooling.
        ids.append(Int32(eosToken))
        return ids
    }

    /// The task prompt: the model guide's `title: {title | "none"} | text: ` for documents.
    private func prompt(for parts: [EmbeddingInput], purpose: EmbeddingPurpose) -> String {
        guard purpose != .query else { return Self.queryPrompt }
        for case .document(let title, _) in parts where !title.isEmpty {
            return "title: \(title) | text: "
        }
        return Self.documentPrompt
    }

    private func append(text: String, to item: inout Item) {
        item.ids += tokenizer.encode(text)
    }

    private func append(_ part: EmbeddingInput, to item: inout Item) throws {
        switch part {
        case .text(let text), .document(_, let text):
            append(text: text, to: &item)
        case .image(let image):
            guard let processed = imageProcessor.process(image) else { throw EmbeddingError.encodingFailed }
            item.images.append(processed)
            item.ids += mediaSpan(start: config.boiTokenId, token: config.imageTokenId, count: processed.softTokens, end: config.eoiTokenId)
        case .video(let clip):
            appendFrames(of: clip, to: &item)
            if let audio = clip.audio { try append(.audio(audio), to: &item) }
        case .audio(let clip):
            append(audio: clip, to: &item)
        case .interleaved(let parts):
            for nested in parts { try append(nested, to: &item) }
        }
    }

    private func appendFrames(of clip: VideoClip, to item: inout Item) {
        for frame in clip.frames {
            guard let processed = frameProcessor.process(frame) else { continue }
            item.frames.append(processed)
            item.ids += mediaSpan(start: config.boiTokenId, token: config.videoTokenId, count: processed.softTokens, end: config.eoiTokenId)
        }
    }

    private func append(audio clip: AudioClip, to item: inout Item) {
        let samples = clip.sampleRate == 16_000 ? clip.samples : Self.resample(clip.samples, from: clip.sampleRate)
        let features = audioFeatures(samples)
        let tokens = EG2AudioFeatureExtractor.tokenCount(mask: features.mask)
        guard tokens > 0 else { return }
        item.audio.append(features)
        item.ids += mediaSpan(start: config.boaTokenId, token: config.audioTokenId, count: tokens, end: config.eoaTokenIndex)
    }

    private func mediaSpan(start: Int, token: Int, count: Int, end: Int) -> [Int32] {
        [Int32(start)] + [Int32](repeating: Int32(token), count: count) + [Int32(end)]
    }

    /// Pads a length up to a small set of buckets so compiled graphs are reused.
    static func bucketed(_ length: Int) -> Int {
        let step = length <= 64 ? 16 : length <= 512 ? 64 : 256
        return (length + step - 1) / step * step
    }

    /// Batches items of any lengths: right-padded ids and mask, and stacked media in order.
    func batch(_ items: [Item], padTo minimumLength: Int = 0) -> EG2Batch {
        let length = max(items.map(\.ids.count).max() ?? 1, minimumLength)
        var ids = [Int32](repeating: Int32(config.textConfig.padTokenId), count: items.count * length)
        var mask = [Int32](repeating: 0, count: items.count * length)
        for (row, item) in items.enumerated() {
            for (column, id) in item.ids.enumerated() {
                ids[row * length + column] = id
                mask[row * length + column] = 1
            }
        }
        var batch = EG2Batch(inputIDs: MLXArray(ids, [items.count, length]), attentionMask: MLXArray(mask, [items.count, length]))
        let images = items.flatMap(\.images)
        if !images.isEmpty { (batch.pixelValues, batch.imagePositionIDs) = stack(images, processor: imageProcessor) }
        let frames = items.flatMap(\.frames)
        if !frames.isEmpty { (batch.videoPixelValues, batch.videoPositionIDs) = stack(frames, processor: frameProcessor) }
        let audio = items.flatMap(\.audio)
        if !audio.isEmpty {
            let frameCount = audio.map { $0.features.dim(0) }.max() ?? 0
            let padded = audio.map { output -> MLXArray in
                let missing = frameCount - output.features.dim(0)
                return missing > 0 ? MLX.padded(output.features, widths: [[0, missing], 0]) : output.features
            }
            batch.audioFeatures = stacked(padded, axis: 0)
            batch.audioFeaturesMask = stacked(
                audio.map { MLXArray(($0.mask + [Bool](repeating: false, count: frameCount - $0.mask.count))) }, axis: 0)
        }
        return batch
    }

    private func stack(_ outputs: [EG2ImageProcessor.Output], processor: EG2ImageProcessor) -> (MLXArray, MLXArray) {
        let pixels = MLXArray(outputs.flatMap(\.patches), [outputs.count, processor.maxPatches, processor.patchDimension])
        let positions = MLXArray(outputs.flatMap(\.positions), [outputs.count, processor.maxPatches, 2])
        return (pixels, positions)
    }

    /// Linear resampling to 16 kHz for clips that arrive at another rate.
    static func resample(_ samples: [Float], from rate: Double) -> [Float] {
        guard rate > 0, !samples.isEmpty else { return samples }
        let ratio = rate / 16_000
        let count = Int(Double(samples.count) / ratio)
        return (0..<count).map { index in
            let position = Double(index) * ratio
            let lower = Int(position)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(position - Double(lower))
            return samples[lower] * (1 - fraction) + samples[upper] * fraction
        }
    }
}
