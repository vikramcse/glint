// glint-eval: retrieval eval harness.
//
//   glint-eval bench [--dir D] [--photos N --screenshots N --pdfs N --docs N --audio N --videos N]
//                    [--model gemma|apple|pipeline] [--model-dir D] [--only kind,kind] [--out report.json]
//   glint-eval sample <dir>                     write <dir>/corpus and <dir>/queries.json
//   glint-eval run <dir> [--queries q.json] [--model gemma|apple|hashing] [--model-dir D] [--dimensions N]
//                  [--baseline report.json] [--out report.json] [--margin M|off] [--z K|off] [--titles] [--loose-keywords N|all]
//                  [--text-bits 8|16] [--media-bits 8|16] [--fusion rrf|scores] [--per-file] [--adaptive on|off]
//                  [--semantic-weight W] [--keyword-weight W] [--confident S|off] [--confident-margin M]
//                  [--fuse-text off] [--diagnose rankings.json] [--index-cache D] [--loose-support Z]
//                  [--sound-labels off|keywords|embedded]
//                  --index-cache keeps the index in D and reuses it next time (same corpus and model)
//                  --diagnose writes where every relevant file ranks in the raw semantic and keyword
//                  lists before any cutoff, to tell a model miss from a filter miss
//   glint-eval query <text>... --model-dir D [--index index.sqlite] [--dimensions N] [--idle-unload S]
//                    run queries against a real index (read-only) and print every
//                    semantic score next to what the app would show
//
// Exits non-zero when a gate fails: a metric drops more than 1 point overall or 2 points
// for a media type versus the baseline, or a must-pass query leaves the top 10.

import Foundation
import GlintCore
import GlintEmbedding
import GlintExtractors
import GlintIndexer
import GlintSearch
import GlintStore
import GlintTestSupport

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func printReport(_ report: EvalReport, failures: [String]) {
    func row(_ label: String, _ scores: Scores) -> String {
        label.padding(toLength: 10, withPad: " ", startingAt: 0)
            + String(
                format: "%4d   %.3f   %.3f   %.3f     %.3f       %.3f    %.3f", scores.queries, scores.recallAt10, scores.mrr,
                scores.ndcgAt10, scores.precision ?? .nan, scores.recall ?? .nan, scores.f1 ?? .nan)
    }
    print("\nModel: \(report.model)")
    print("kind         n   R@10    MRR     nDCG@10   Precision   Recall   F1")
    print(row("overall", report.overall))
    for (kind, scores) in report.perKind.sorted(by: { $0.key < $1.key }) { print(row(kind, scores)) }
    print(String(format: "\nQuery latency p50 %.1f ms, p95 %.1f ms", report.latencyP50Milliseconds, report.latencyP95Milliseconds))
    if let negatives = report.negatives {
        print(
            String(
                format: "negative  %4d   %.0f%% returned nothing, %.1f results on average", negatives.queries,
                negatives.emptyRate * 100, negatives.averageReturned))
    }
    let misses = report.outcomes.filter { $0.recallAt10 < 1 && $0.isNegative != true }
    if !misses.isEmpty {
        print("\nMisses:")
        for miss in misses { print("  \(miss.id) (R@10 \(String(format: "%.2f", miss.recallAt10))): top \(miss.top.prefix(3))") }
    }
    let noisy = report.outcomes.filter { ($0.precision ?? 1) < 1 }
    if !noisy.isEmpty {
        print("\nReturned unrelated files:")
        for outcome in noisy {
            let precision = String(format: "%.2f", outcome.precision ?? 0)
            print("  \(outcome.id): \(outcome.returned ?? 0) results, precision \(precision); top \(outcome.top.prefix(3))")
        }
    }
    if failures.isEmpty {
        print("\n✓ All gates passed")
    } else {
        print("\n✗ Gates failed:")
        for failure in failures { print("  - \(failure)") }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "sample":
    guard arguments.count >= 2 else { fail("usage: glint-eval sample <dir>") }
    do {
        try SampleCorpus.write(to: URL(fileURLWithPath: arguments[1]))
        print("Wrote sample corpus to \(arguments[1])")
    } catch {
        fail(String(describing: error))
    }

case "bench":
    var counts = BenchCounts()
    for kind in BenchCounts.kinds {
        guard let value = option("--\(kind)", in: arguments).flatMap(Int.init) else { continue }
        switch kind {
        case "photos": counts.photos = value
        case "screenshots": counts.screenshots = value
        case "pdfs": counts.pdfs = value
        case "docs": counts.docs = value
        case "audio": counts.audio = value
        default: counts.videos = value
        }
    }
    let benchDirectory = URL(
        fileURLWithPath: option("--dir", in: arguments)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("glint-bench-corpus").path, isDirectory: true)
    let benchProvider: any EmbeddingProvider
    switch option("--model", in: arguments) ?? "apple" {
    case "hashing", "pipeline": benchProvider = PipelineEmbeddingProvider()
    case "gemma":
        guard let path = option("--model-dir", in: arguments) else { fail("--model gemma needs --model-dir <checkpoint>") }
        do {
            benchProvider = try await EmbeddingGemma2Provider(directory: URL(fileURLWithPath: path), towers: .text)
        } catch {
            fail("could not load EmbeddingGemma 2: \(error)")
        }
    default:
        guard let apple = try? AppleOnDeviceEmbeddingProvider() else { fail("on-device embedding unavailable") }
        benchProvider = apple
    }
    let kinds = option("--only", in: arguments).map { $0.split(separator: ",").map(String.init) } ?? BenchCounts.kinds
    do {
        try await BenchCorpus.ensure(at: benchDirectory, counts: counts)
        print("Corpus: \(benchDirectory.path)\nModel: \(benchProvider.descriptor.space)\n")
        var runner = BenchRunner(corpus: benchDirectory, provider: benchProvider)
        if let lanes = option("--lanes", in: arguments).flatMap(Int.init) { runner.options.embeddingLanes = lanes }
        if let batch = option("--batch", in: arguments).flatMap(Int.init) { runner.options.embeddingBatchSize = batch }
        if let workers = option("--workers", in: arguments).flatMap(Int.init) { runner.options.concurrentFiles = workers }
        let runs = try await runner.run(kinds: kinds)
        if let out = option("--out", in: arguments) {
            let report = BenchReport(
                model: benchProvider.descriptor.space.description, date: Date(),
                machine: "\(ProcessInfo.processInfo.activeProcessorCount) cores, \(ProcessInfo.processInfo.physicalMemory >> 30) GB",
                runs: runs)
            try JSONEncoder.pretty.encode(report).write(to: URL(fileURLWithPath: out))
        }
    } catch {
        fail(String(describing: error))
    }

case "run":
    guard arguments.count >= 2 else { fail("usage: glint-eval run <dir> [options]") }
    let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let corpus = directory.appendingPathComponent("corpus", isDirectory: true)
    let queriesURL = option("--queries", in: arguments).map(URL.init(fileURLWithPath:)) ?? directory.appendingPathComponent("queries.json")
    guard let data = try? Data(contentsOf: queriesURL), let set = try? JSONDecoder().decode(EvalQuerySet.self, from: data) else {
        fail("could not read queries at \(queriesURL.path)")
    }
    let provider: any EmbeddingProvider
    switch option("--model", in: arguments) ?? "apple" {
    case "hashing": provider = HashingEmbeddingProvider()
    case "gemma":
        guard let path = option("--model-dir", in: arguments) else { fail("--model gemma needs --model-dir <checkpoint>") }
        let dimensions = option("--dimensions", in: arguments).flatMap(Int.init) ?? 512
        do {
            provider = try await EmbeddingGemma2Provider(
                directory: URL(fileURLWithPath: path), dimensions: dimensions,
                quantization: option("--text-bits", in: arguments) == "16" ? .none : .int8,
                mediaQuantization: option("--media-bits", in: arguments) == "16" ? .none : .int8)
        } catch {
            fail("could not load EmbeddingGemma 2: \(error)")
        }
    default:
        guard let apple = try? AppleOnDeviceEmbeddingProvider() else { fail("on-device embedding unavailable") }
        provider = apple
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let baseline = option("--baseline", in: arguments).flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        .flatMap { try? decoder.decode(EvalReport.self, from: $0) }

    do {
        var runner = EvalRunner(corpus: corpus, queries: set.queries, provider: provider)
        if let margin = option("--margin", in: arguments) { runner.similarityMargin = .some(Float(margin)) }
        if let z = option("--z", in: arguments) { runner.minimumZScore = .some(Float(z)) }
        if let z = option("--robust-z", in: arguments) { runner.minimumRobustZScore = .some(Float(z)) }
        if let confident = option("--confident", in: arguments) { runner.confidentSimilarity = .some(Float(confident)) }
        if let path = option("--diagnose", in: arguments) { runner.diagnosePath = URL(fileURLWithPath: path) }
        if option("--fuse-text", in: arguments) == "off" { runner.indexerOptions.fuseTextIntoMedia = false }
        if let margin = option("--confident-margin", in: arguments).flatMap(Float.init) { runner.ranker.confidentMargin = margin }
        if arguments.contains("--titles") { runner.indexerOptions.documentTitles = true }
        if let loose = option("--loose-keywords", in: arguments) { runner.looseKeywordLimit = .some(Int(loose)) }
        if let fusion = option("--fusion", in: arguments) { runner.ranker.fusion = fusion == "rrf" ? .reciprocalRank : .scores }
        if arguments.contains("--per-file") { runner.ranker.fusesPerFile = true }
        if let labels = option("--sound-labels", in: arguments) {
            guard let mode = ExtractionOptions.SoundLabels(rawValue: labels) else { fail("--sound-labels off|keywords|embedded") }
            runner.extractionOptions.soundLabels = mode
        }
        if let support = option("--loose-support", in: arguments) { runner.ranker.looseSemanticSupport = Float(support) }
        if let cache = option("--index-cache", in: arguments) { runner.indexCache = URL(fileURLWithPath: cache, isDirectory: true) }
        if let adaptive = option("--adaptive", in: arguments) { runner.adaptsWeights = adaptive != "off" }
        if let weight = option("--semantic-weight", in: arguments).flatMap(Double.init) { runner.ranker.semanticWeight = weight }
        if let weight = option("--keyword-weight", in: arguments).flatMap(Double.init) {
            runner.ranker.keywordWeight = weight
            runner.ranker.nameWeight = weight * 1.2
        }
        let report = try await runner.run()
        let failures = EvalGates.failures(report: report, baseline: baseline)
        printReport(report, failures: failures)
        if let out = option("--out", in: arguments) {
            try JSONEncoder.pretty.encode(report).write(to: URL(fileURLWithPath: out))
        }
        exit(failures.isEmpty ? 0 : 1)
    } catch {
        fail(String(describing: error))
    }

case "query":
    var texts: [String] = []
    var rest = arguments.dropFirst()[...]
    while let next = rest.popFirst() {
        if next.hasPrefix("--") { _ = rest.popFirst() } else { texts.append(next) }
    }
    guard !texts.isEmpty, let modelDir = option("--model-dir", in: arguments) else {
        fail("usage: glint-eval query <text>... --model-dir D [--index index.sqlite] [--dimensions N]")
    }
    do {
        let paths = try AppPaths.standard()
        let database = option("--index", in: arguments).map(URL.init(fileURLWithPath:)) ?? paths.database
        let dimensions = option("--dimensions", in: arguments).flatMap(Int.init) ?? 512
        // --idle-unload S: release the model after S seconds idle and wait past it between
        // queries, to check that a reloaded model gives the same scores.
        let idle = option("--idle-unload", in: arguments).flatMap(Double.init)
        let provider = try await EmbeddingGemma2Provider(
            directory: URL(fileURLWithPath: modelDir), towers: .text, dimensions: dimensions,
            idleUnload: idle.map { .milliseconds(Int($0 * 1_000)) })
        let gate = PriorityGate(quietPeriod: .milliseconds(1))
        let encoder = GatedQueryEncoder(provider: provider, gate: gate)
        let vectorIndex = FlatVectorIndex(space: provider.descriptor.space)
        let engine = SearchEngine(
            reader: try IndexReader(url: database), vectorIndex: vectorIndex, encoder: encoder,
            thumbnails: ThumbnailStore(directory: paths.thumbnails))
        let loaded = try await engine.loadVectors()
        print("Loaded \(loaded) vectors in \(provider.descriptor.space); semantic cutoff \(encoder.minimumSimilarity)")
        let names = Dictionary(
            try await engine.recent(kinds: Set(MediaKind.allCases), limit: 100_000).map { ($0.file.id, $0.file.name) },
            uniquingKeysWith: { first, _ in first })
        for (index, text) in texts.enumerated() {
            if let idle, index > 0 { try await Task.sleep(for: .milliseconds(Int(idle * 2_000))) }
            print("\n\"\(text)\"")
            let embedding = try await encoder.encode(query: text)
            var best: [FileID: Float] = [:]
            let (hits, statistics) = try await vectorIndex.searchWithStatistics(embedding, limit: 100_000, filter: .none)
            if let statistics {
                print(String(format: "  library mean %.3f, deviation %.3f over %d rows", statistics.mean, statistics.deviation, loaded))
            }
            for hit in hits {
                best[hit.fileID] = max(best[hit.fileID] ?? -1, hit.score)
            }
            print("  semantic (best chunk per file):")
            for (id, score) in best.sorted(by: { $0.value > $1.value }) {
                let mark = score >= encoder.minimumSimilarity ? "✓" : " "
                let z = statistics.map { ($0.deviation > 0 ? (score - $0.mean) / $0.deviation : 0) } ?? 0
                print(String(format: "    %@ %.3f  z %5.2f  %@", mark, score, z, names[id] ?? "#\(id.rawValue)"))
            }
            let shown = try await engine.mergedResults(for: SearchQuery(text: text)).items
            let labels = shown.map { "\($0.file.name) [\($0.sources.label)]" }.joined(separator: ", ")
            print("  app shows: \(shown.isEmpty ? "nothing" : labels)")
        }
    } catch {
        fail(String(describing: error))
    }

default:
    print(
        "usage: glint-eval sample <dir> | run <dir> [--queries q.json] [--model gemma|apple|hashing] [--model-dir D] "
            + "[--dimensions N] [--baseline r.json] [--out r.json]"
    )
    exit(2)
}

extension MatchSources {
    var label: String {
        [(MatchSources.semantic, "semantic"), (.keyword, "keyword"), (.name, "name")]
            .filter { contains($0.0) }.map(\.1).joined(separator: "+")
    }
}
