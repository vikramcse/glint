import Foundation

/// Standard retrieval metrics over graded relevance judgments, used by the eval harness.
///
/// Grades: 2 = exact match, 1 = relevant, 0 (or absent) = not relevant.
public enum RetrievalMetrics {
    /// Fraction of relevant items (grade ≥ 1) found in the top `k`.
    public static func recall(ranked: [String], relevant: [String: Int], k: Int = 10) -> Double {
        let wanted = Set(relevant.filter { $0.value > 0 }.keys)
        guard !wanted.isEmpty else { return 0 }
        let found = Set(ranked.prefix(k)).intersection(wanted)
        return Double(found.count) / Double(wanted.count)
    }

    /// Reciprocal rank of the first relevant item (0 when none is ranked).
    public static func reciprocalRank(ranked: [String], relevant: [String: Int]) -> Double {
        guard let index = ranked.firstIndex(where: { (relevant[$0] ?? 0) > 0 }) else { return 0 }
        return 1 / Double(index + 1)
    }

    /// Normalized discounted cumulative gain at `k` with gain 2^grade − 1.
    public static func ndcg(ranked: [String], relevant: [String: Int], k: Int = 10) -> Double {
        func dcg(_ grades: [Int]) -> Double {
            grades.prefix(k).enumerated().reduce(0) { sum, item in
                sum + (pow(2, Double(item.element)) - 1) / log2(Double(item.offset) + 2)
            }
        }
        let ideal = dcg(relevant.values.filter { $0 > 0 }.sorted(by: >))
        guard ideal > 0 else { return 0 }
        return dcg(ranked.map { relevant[$0] ?? 0 }) / ideal
    }

    /// Nearest-rank percentile of `values` (0...100).
    public static func percentile(_ values: [Double], _ percent: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((percent / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }
}
