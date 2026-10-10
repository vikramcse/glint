import Foundation

/// Keeps the `k` highest-scoring elements seen, using a bounded min-heap (O(n log k)).
struct TopK<Element> {
    private(set) var heap: [(score: Float, element: Element)] = []
    let k: Int

    init(_ k: Int) {
        self.k = max(0, k)
        heap.reserveCapacity(self.k)
    }

    /// The lowest score that would still enter the heap.
    var threshold: Float { heap.count < k ? -.infinity : heap[0].score }

    mutating func insert(_ element: Element, score: Float) {
        guard k > 0 else { return }
        if heap.count < k {
            heap.append((score, element))
            siftUp(heap.count - 1)
        } else if score > heap[0].score {
            heap[0] = (score, element)
            siftDown(0)
        }
    }

    /// Elements sorted by descending score.
    func sorted() -> [(score: Float, element: Element)] {
        heap.sorted { $0.score > $1.score }
    }

    private mutating func siftUp(_ index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child].score < heap[parent].score else { return }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ index: Int) {
        var parent = index
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var smallest = parent
            if left < heap.count, heap[left].score < heap[smallest].score { smallest = left }
            if right < heap.count, heap[right].score < heap[smallest].score { smallest = right }
            guard smallest != parent else { return }
            heap.swapAt(parent, smallest)
            parent = smallest
        }
    }
}
