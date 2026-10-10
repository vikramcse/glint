import Testing

@testable import GlintSearch

@Suite("RetrievalMetrics")
struct RetrievalMetricsTests {
    let relevant = ["a": 2, "b": 1, "z": 0]

    @Test func recallCountsGradedItemsInTopK() {
        #expect(RetrievalMetrics.recall(ranked: ["x", "a", "y"], relevant: relevant, k: 10) == 0.5)
        #expect(RetrievalMetrics.recall(ranked: ["b", "a"], relevant: relevant) == 1)
        #expect(RetrievalMetrics.recall(ranked: ["x", "b"], relevant: relevant, k: 1) == 0)
    }

    @Test func reciprocalRankUsesFirstRelevant() {
        #expect(RetrievalMetrics.reciprocalRank(ranked: ["x", "z", "b"], relevant: relevant) == 1.0 / 3)
        #expect(RetrievalMetrics.reciprocalRank(ranked: ["x"], relevant: relevant) == 0)
    }

    @Test func ndcgIsOneForIdealOrder() {
        #expect(abs(RetrievalMetrics.ndcg(ranked: ["a", "b"], relevant: relevant) - 1) < 1e-9)
        let swapped = RetrievalMetrics.ndcg(ranked: ["b", "a"], relevant: relevant)
        #expect(swapped < 1 && swapped > 0.5)
        #expect(RetrievalMetrics.ndcg(ranked: [], relevant: relevant) == 0)
    }

    @Test func percentileUsesNearestRank() {
        let values = (1...100).map(Double.init)
        #expect(RetrievalMetrics.percentile(values, 50) == 50)
        #expect(RetrievalMetrics.percentile(values, 95) == 95)
        #expect(RetrievalMetrics.percentile([], 95) == 0)
    }
}
