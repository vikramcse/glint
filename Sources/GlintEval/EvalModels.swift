import Foundation
import GlintCore

/// A golden query with graded relevance judgments (paths relative to the corpus root).
struct EvalQuery: Codable, Sendable {
    var id: String
    var text: String
    /// Must stay in the top 10 on every build.
    var mustPass: Bool?
    /// Path → grade (2 exact, 1 relevant). Empty for a negative query: nothing in the corpus
    /// matches, so the best answer is no results.
    var relevant: [String: Int]
    /// Files that are neither right nor wrong (for example a tiny, distant car); they count
    /// for nothing whether returned or not.
    var ignored: [String]?

    var isNegative: Bool { !relevant.values.contains { $0 > 0 } }
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
    /// Fraction of everything returned that is relevant (missing in older reports).
    var precision: Double?
    /// Fraction of relevant files returned at all, at any rank.
    var recall: Double?
    /// Harmonic mean of `precision` and `recall`, per query, averaged.
    var f1: Double?
}

/// How often queries for things the corpus does not contain come back empty.
struct NegativeScores: Codable, Sendable, Hashable {
    var queries: Int
    /// Fraction of negative queries that returned nothing.
    var emptyRate: Double
    var averageReturned: Double
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
    /// Results returned in all, and the fraction of them that are relevant.
    var returned: Int?
    var precision: Double?
    var recall: Double?
    var isNegative: Bool?
}

/// Everything one eval run produced.
struct EvalReport: Codable, Sendable {
    var model: String
    var date: Date
    var corpusFiles: Int
    var indexingSeconds: Double
    var overall: Scores
    var perKind: [String: Scores]
    var negatives: NegativeScores?
    var latencyP50Milliseconds: Double
    var latencyP95Milliseconds: Double
    var outcomes: [QueryOutcome]
}

/// Regression gates from the PRD: no metric may drop more than 1 point overall or 2 points
/// for any media type, and no must-pass query may fall out of the top 10.
enum EvalGates {
    static func failures(report: EvalReport, baseline: EvalReport?) -> [String] {
        var failures: [String] = []
        for outcome in report.outcomes where outcome.mustPass && outcome.recallAt10 == 0 && outcome.isNegative != true {
            failures.append("must-pass query \(outcome.id) has no relevant result in the top 10")
        }
        guard let baseline else { return failures }
        failures += compare("overall", report.overall, baseline.overall, tolerance: 0.01)
        for (kind, base) in baseline.perKind {
            guard let current = report.perKind[kind] else { continue }
            failures += compare(kind, current, base, tolerance: 0.02)
        }
        // Queries for things the corpus doesn't contain: a looser cutoff must not start
        // returning unrelated files for them.
        if let now = report.negatives, let before = baseline.negatives {
            if before.emptyRate - now.emptyRate > 0.1 + 1e-9 {
                failures.append(
                    String(
                        format: "negative queries returning nothing dropped from %.0f%% to %.0f%%", before.emptyRate * 100,
                        now.emptyRate * 100))
            }
            if now.averageReturned - before.averageReturned > 1 + 1e-9 {
                failures.append(
                    String(
                        format: "negative queries return %.1f results on average, up from %.1f", now.averageReturned, before.averageReturned
                    ))
            }
        }
        return failures
    }

    private static func compare(_ label: String, _ current: Scores, _ base: Scores, tolerance: Double) -> [String] {
        var failures: [String] = []
        var pairs = [
            ("Recall@10", current.recallAt10, base.recallAt10), ("MRR", current.mrr, base.mrr),
            ("nDCG@10", current.ndcgAt10, base.ndcgAt10),
        ]
        if let now = current.precision, let before = base.precision { pairs.append(("Precision", now, before)) }
        if let now = current.f1, let before = base.f1 { pairs.append(("F1", now, before)) }
        for (name, now, before) in pairs where before - now > tolerance + 1e-9 {
            failures.append(String(format: "%@ %@ dropped from %.3f to %.3f", label, name, before, now))
        }
        return failures
    }
}
