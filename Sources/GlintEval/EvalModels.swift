import Foundation
import GlintCore

/// A golden query with graded relevance judgments (paths relative to the corpus root).
struct EvalQuery: Codable, Sendable {
    var id: String
    var text: String
    /// Must stay in the top 10 on every build.
    var mustPass: Bool?
    /// Path → grade (2 exact, 1 relevant).
    var relevant: [String: Int]
}

struct EvalQuerySet: Codable, Sendable {
    var queries: [EvalQuery]
}

/// Aggregate scores for a set of queries.
struct Scores: Codable, Sendable, Hashable {
    var queries: Int
    var recallAt10: Double
    var mrr: Double
    var ndcgAt10: Double
}

/// Per-query outcome, kept in the report for debugging misses.
struct QueryOutcome: Codable, Sendable {
    var id: String
    var kind: String
    var recallAt10: Double
    var reciprocalRank: Double
    var ndcgAt10: Double
    var latencyMilliseconds: Double
    var top: [String]
    var mustPass: Bool
}

/// Everything one eval run produced.
struct EvalReport: Codable, Sendable {
    var model: String
    var date: Date
    var corpusFiles: Int
    var indexingSeconds: Double
    var overall: Scores
    var perKind: [String: Scores]
    var latencyP50Milliseconds: Double
    var latencyP95Milliseconds: Double
    var outcomes: [QueryOutcome]
}

/// Regression gates from the PRD: no metric may drop more than 1 point overall or 2 points
/// for any media type, and no must-pass query may fall out of the top 10.
enum EvalGates {
    static func failures(report: EvalReport, baseline: EvalReport?) -> [String] {
        var failures: [String] = []
        for outcome in report.outcomes where outcome.mustPass && outcome.recallAt10 == 0 {
            failures.append("must-pass query \(outcome.id) has no relevant result in the top 10")
        }
        guard let baseline else { return failures }
        failures += compare("overall", report.overall, baseline.overall, tolerance: 0.01)
        for (kind, base) in baseline.perKind {
            guard let current = report.perKind[kind] else { continue }
            failures += compare(kind, current, base, tolerance: 0.02)
        }
        return failures
    }

    private static func compare(_ label: String, _ current: Scores, _ base: Scores, tolerance: Double) -> [String] {
        var failures: [String] = []
        let pairs = [
            ("Recall@10", current.recallAt10, base.recallAt10), ("MRR", current.mrr, base.mrr),
            ("nDCG@10", current.ndcgAt10, base.ndcgAt10),
        ]
        for (name, now, before) in pairs where before - now > tolerance + 1e-9 {
            failures.append(String(format: "%@ %@ dropped from %.3f to %.3f", label, name, before, now))
        }
        return failures
    }
}
