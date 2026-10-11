import Foundation
import Testing
import Tokenizers

@testable import GlintEmbedding

/// The compact tokenizer must produce exactly Hugging Face's token ids. Needs the checkpoint
/// (no Metal):
///   GLINT_EG2_DIR=<checkpoint dir> swift test --filter EG2TokenizerParity
///
/// Hard cases are checked against ids from Hugging Face's Rust tokenizer
/// (`scripts/model/make_tokenizer_fixtures.py`). A ~30k-text corpus (sources, COCO captions
/// when `scripts/coco_bench.py` has run, random Unicode) is checked against swift-transformers,
/// skipping text it gets wrong: it keys merges by Swift `String`, which equates canonically
/// equivalent characters (Kelvin sign and K), and replaces spaces per grapheme, missing a space
/// before a combining mark. To check the whole corpus against Hugging Face instead, set
/// GLINT_TOKENIZER_DUMP and run `scripts/model/check_tokenizer_dump.py`.
@Suite(
    "EG2Tokenizer parity", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["GLINT_EG2_DIR"] != nil))
struct EG2TokenizerParityTests {
    static let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GLINT_EG2_DIR"] ?? "/")

    static let edgeCases = [
        "", " ", "  ", "   leading", "trailing   ", "a", "aaaaaaaaaaaaaaaa", "\n\n\n\t\t  \n",
        "the receipt from the hotel in Goa", "task: search result | query: car",
        "Grüße aus Zürich – café naïve façade", "東京タワーの夜景", "서울의 봄", "مرحبا بالعالم", "नमस्ते दुनिया",
        "emoji 👩‍👩‍👧‍👦 🇮🇳 🧑🏽‍💻 ❤️‍🔥", "combining e\u{301} a\u{308}\u{301} \u{301}start",
        "zero\u{200B}width\u{FEFF}joiners", "math ∑∫√∞ ≠ ≤", "control \u{0001}\u{0007}\u{007F}", "\u{10FFFF}\u{E000}",
        "<eos>", "a<eos>b", "<bos><eos><pad>", "<|image|><image|><|image>", "<unknown> <0x41> <|\"|>", "<<eos>>", "<",
        "func scan(_ matrix: VectorMatrix) -> [Float] { return [] } // x += 1",
        "https://example.com/path?q=1&r=2#frag", "1234567890 3.14159 -42 1e10",
        String(repeating: "word ", count: 400), String(repeating: "🙂", count: 50),
    ]

    static func corpus() -> [String] {
        var texts = edgeCases
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            texts.append(text)
        }
        for name in ["README.md", "PRD.md"] {
            if let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) { texts.append(text) }
        }
        let captions = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/glint-bench/coco/annotations/captions_val2017.json")
        if let data = try? Data(contentsOf: captions),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let annotations = json["annotations"] as? [[String: Any]]
        {
            texts += annotations.compactMap { $0["caption"] as? String }
        }
        // Random strings over every plane, including characters outside the vocabulary.
        var state: UInt64 = 7
        func next() -> UInt32 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt32(truncatingIfNeeded: state >> 33)
        }
        for _ in 0..<5_000 {
            var text = ""
            for _ in 0..<(Int(next() % 40) + 1) {
                let pick = next() % 10
                let value: UInt32 =
                    pick < 4 ? 0x20 + next() % 0x5F : pick < 6 ? 0xA0 + next() % 0x2F00 : pick < 8 ? 0x4E00 + next() % 0x5000 : next() % 0x10FFFF
                if let scalar = Unicode.Scalar(value) { text.unicodeScalars.append(scalar) }
            }
            texts.append(text)
        }
        return texts
    }

    @Test func matchesHuggingFaceOnHardCases() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/tokenizer_cases.json")
        // ExactJSON: the cases include byte-order marks, which JSONSerialization strips.
        guard case .array(let rows) = try ExactJSON.parse(Data(contentsOf: fixture)) else {
            Issue.record("unreadable fixture")
            return
        }
        let compact = try EG2Tokenizer(directory: Self.directory)
        #expect(rows.count == 42)
        for case .object(let row) in rows {
            guard case .string(let text)? = row.first(where: { $0.key == "text" })?.value,
                case .array(let values)? = row.first(where: { $0.key == "ids" })?.value
            else { continue }
            let expected = values.compactMap { value -> Int? in if case .number(let id) = value { id } else { nil } }
            #expect(compact.encode(text).map(Int.init) == expected, "\(text.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }

    /// Whether swift-transformers tokenizes `text` correctly (see the suite comment).
    static func referenceHandles(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            scalar.properties.canonicalCombiningClass == .notReordered
                && String(scalar).decomposedStringWithCanonicalMapping.unicodeScalars.elementsEqual([scalar])
                && !(scalar.properties.generalCategory == .nonspacingMark || scalar.properties.generalCategory == .enclosingMark
                    || scalar.properties.generalCategory == .spacingMark)
        }
    }

    @Test func matchesSwiftTransformers() async throws {
        let reference = try await AutoTokenizer.from(modelFolder: Self.directory)
        let compact = try EG2Tokenizer(directory: Self.directory)
        let all = Self.corpus()
        let texts = all.filter(Self.referenceHandles)
        print("Skipped \(all.count - texts.count) texts swift-transformers gets wrong")
        var mismatches: [String] = []
        for text in texts {
            let expected = reference.encode(text: text, addSpecialTokens: false)
            let actual = compact.encode(text).map(Int.init)
            if expected != actual { mismatches.append(text) }
        }
        print("Compared \(texts.count) texts, \(mismatches.count) mismatches")
        // GLINT_TOKENIZER_DUMP=<file>: write every text with its ids, to check against Hugging
        // Face's Rust tokenizer (scripts/model/check_tokenizer_dump.py).
        if let dump = ProcessInfo.processInfo.environment["GLINT_TOKENIZER_DUMP"] {
            let rows = all.map { ["text": $0, "ids": compact.encode($0).map(Int.init)] as [String: Any] }
            try JSONSerialization.data(withJSONObject: rows).write(to: URL(fileURLWithPath: dump))
        }
        for text in mismatches.prefix(5) {
            let expected = reference.encode(text: text, addSpecialTokens: false)
            let actual = compact.encode(text).map(Int.init)
            let first = (0..<min(expected.count, actual.count)).first { expected[$0] != actual[$0] } ?? min(expected.count, actual.count)
            print("  \(text.unicodeScalars.map { String($0.value, radix: 16) })")
            print("    differ at \(first): reference \(expected[first...].prefix(8)) compact \(actual[first...].prefix(8))")
        }
        #expect(mismatches.isEmpty)
    }
}
