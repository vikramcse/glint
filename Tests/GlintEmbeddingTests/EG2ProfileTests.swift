import Foundation
import MLX
import Testing

@testable import GlintEmbedding

@Suite("EG2 profile", .serialized, .enabled(if: ProcessInfo.processInfo.environment["GLINT_EG2_PROFILE"] != nil))
struct EG2ProfileTests {
    static func ms(_ start: ContinuousClock.Instant) -> Double {
        Double((ContinuousClock.now - start).components.attoseconds) / 1e15
    }

    @Test func breakdown() async throws {
        let directory = EmbeddingGemma2ParityTests.modelDirectory
        let config = try EG2Configuration.load(from: directory)
        let tokenizer = try await TokenizerLoader.load(directory)
        let processor = EG2Processor(tokenizer: tokenizer, config: config)
        let model = EG2Model(config, towers: .text)
        try model.loadWeights(from: directory)
        let query = "when the client mentioned the deadline"

        print("default device \(Device.defaultDevice())")
        let a = MLXRandom.normal([16, 512]).asType(.bfloat16)
        let w = MLXRandom.normal([512, 2048]).asType(.bfloat16)
        eval(matmul(a, w))
        var start = ContinuousClock.now
        for _ in 0..<50 { eval(matmul(a, w)) }
        print("tiny matmul eval \(Self.ms(start) / 50) ms")
        let layer = model.languageModel.layers[0]
        let h = MLXRandom.normal([1, 16, 512]).asType(.bfloat16)
        let fullMask = MLXArray.ones([1, 1, 1, 16], type: Bool.self)
        let positions = MLXArray(0..<Int32(16)).reshaped(1, 16)
        eval(layer(h, mask: fullMask, positions: positions, perLayerInput: nil))
        start = ContinuousClock.now
        for _ in 0..<20 { eval(layer(h, mask: fullMask, positions: positions, perLayerInput: nil)) }
        print("one layer \(Self.ms(start) / 20) ms")
        start = ContinuousClock.now
        for _ in 0..<20 { eval(layer.mlp(h)) }
        print("one mlp \(Self.ms(start) / 20) ms")
        start = ContinuousClock.now
        for _ in 0..<20 { eval(layer.attention(h, mask: fullMask, positions: positions)) }
        print("one attention \(Self.ms(start) / 20) ms")
        let embedded = model.languageModel.embed(MLXArray([Int32](repeating: 5, count: 16), [1, 16]))
        eval(embedded)
        start = ContinuousClock.now
        for _ in 0..<20 { eval(model.languageModel.ple!(embedded)) }
        print("per-layer inputs \(Self.ms(start) / 20) ms")
        start = ContinuousClock.now
        for _ in 0..<20 { eval(model.languageModel.embed(MLXArray([Int32](repeating: 5, count: 16), [1, 16]))) }
        print("embed lookup \(Self.ms(start) / 20) ms")

        start = ContinuousClock.now
        for _ in 0..<100 { _ = try processor.prepare(.text(query), purpose: .query) }
        print("tokenize \(Self.ms(start) / 100) ms")

        let item = try processor.prepare(.text(query), purpose: .query)
        let batch = processor.batch([item])
        for _ in 0..<3 { eval(try model(batch)) }
        start = ContinuousClock.now
        for _ in 0..<20 { eval(try model(batch)) }
        print("model same shape \(Self.ms(start) / 20) ms (\(item.ids.count) tokens)")

        // Graph construction only (no eval).
        start = ContinuousClock.now
        var outputs: [MLXArray] = []
        for _ in 0..<20 { outputs.append(try model(batch)) }
        print("graph build \(Self.ms(start) / 20) ms")
        eval(outputs)

        let compiledText = model.compileText()
        for length in [16, 32, 48] {
            let ids = MLXArray([Int32](repeating: 1_000, count: length), [1, length])
            let mask = MLXArray.ones([1, length], type: Int32.self)
            eval(compiledText(ids, mask))
            start = ContinuousClock.now
            for _ in 0..<20 { eval(compiledText(ids, mask)) }
            print("compiled length \(length): \(Self.ms(start) / 20) ms")
        }
        for length in [8, 16, 24, 33, 47] {
            let ids = MLXArray([Int32](repeating: 1_000, count: length), [1, length])
            let padded = EG2Batch(inputIDs: ids, attentionMask: MLXArray.ones([1, length], type: Int32.self))
            start = ContinuousClock.now
            eval(try model(padded))
            let first = Self.ms(start)
            start = ContinuousClock.now
            eval(try model(padded))
            print("length \(length): first \(first) ms, second \(Self.ms(start)) ms")
        }
    }
}
