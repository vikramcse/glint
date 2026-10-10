// glint-eval: retrieval eval harness.
//
//   glint-eval bench [--dir D] [--photos N --screenshots N --pdfs N --docs N --audio N --videos N]
//                    [--model apple|hashing|pipeline] [--only kind,kind] [--out report.json]
//   glint-eval sample <dir>                     write <dir>/corpus and <dir>/queries.json
//   glint-eval run <dir> [--queries q.json] [--model apple|hashing]
//                  [--baseline report.json] [--out report.json]
//
// Exits non-zero when a gate fails: a metric drops more than 1 point overall or 2 points
// for a media type versus the baseline, or a must-pass query leaves the top 10.

import Foundation
import GlintCore
import GlintEmbedding
import GlintIndexer
import GlintSearch
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
            + String(format: "%4d   %.3f   %.3f   %.3f", scores.queries, scores.recallAt10, scores.mrr, scores.ndcgAt10)
    }
    print("\nModel: \(report.model)")
    print("kind         n   R@10    MRR     nDCG@10")
    print(row("overall", report.overall))
    for (kind, scores) in report.perKind.sorted(by: { $0.key < $1.key }) { print(row(kind, scores)) }
    print(String(format: "\nQuery latency p50 %.1f ms, p95 %.1f ms", report.latencyP50Milliseconds, report.latencyP95Milliseconds))
    let misses = report.outcomes.filter { $0.recallAt10 < 1 }
    if !misses.isEmpty {
        print("\nMisses:")
        for miss in misses { print("  \(miss.id) (R@10 \(String(format: "%.2f", miss.recallAt10))): top \(miss.top.prefix(3))") }
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
    default:
        guard let apple = try? AppleOnDeviceEmbeddingProvider() else { fail("on-device embedding unavailable") }
        benchProvider = apple
    }
    let kinds = option("--only", in: arguments).map { $0.split(separator: ",").map(String.init) } ?? BenchCounts.kinds
    do {
        try await BenchCorpus.ensure(at: benchDirectory, counts: counts)
        print("Corpus: \(benchDirectory.path)\nModel: \(benchProvider.descriptor.space)\n")
        let runs = try await BenchRunner(corpus: benchDirectory, provider: benchProvider).run(kinds: kinds)
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
    default:
        guard let apple = try? AppleOnDeviceEmbeddingProvider() else { fail("on-device embedding unavailable") }
        provider = apple
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let baseline = option("--baseline", in: arguments).flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        .flatMap { try? decoder.decode(EvalReport.self, from: $0) }

    do {
        let report = try await EvalRunner(corpus: corpus, queries: set.queries, provider: provider).run()
        let failures = EvalGates.failures(report: report, baseline: baseline)
        printReport(report, failures: failures)
        if let out = option("--out", in: arguments) {
            try JSONEncoder.pretty.encode(report).write(to: URL(fileURLWithPath: out))
        }
        exit(failures.isEmpty ? 0 : 1)
    } catch {
        fail(String(describing: error))
    }

default:
    print("usage: glint-eval sample <dir> | run <dir> [--queries q.json] [--model apple|hashing] [--baseline r.json] [--out r.json]")
    exit(2)
}
