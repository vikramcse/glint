import Foundation
import GlintCore

/// Groups face identity vectors into people, incrementally: each new face joins the person
/// whose average face it is closest to, or starts a new person. People whose average faces
/// drift together are merged, except that two people the user named are never merged.
public struct FaceClusters: Sendable {
    public struct Group: Sendable {
        /// The stored person, or `nil` for a group created by this run.
        public var person: PersonID?
        public var isNamed: Bool
        /// Sum of member vectors; its direction is the average face.
        var sum: [Float]
        public var count: Int
        /// Index of the group this one was merged into, if any.
        public var mergedInto: Int?
    }

    /// Cosine similarity to a person's average face needed to join them.
    public var joinThreshold: Float
    /// Cosine similarity between two people's average faces needed to merge them.
    public var mergeThreshold: Float
    public private(set) var groups: [Group] = []
    private var unitCentroids: [[Float]] = []

    /// Calibrated with `glint-eval faces` on LFW (150 people, 8 photos each, among 2,000
    /// strangers): 0.55/0.60 groups 97.5% of same-person pairs with 99.0% precision; 0.45/0.50
    /// reaches 99.4% but merges strangers (89.6% precision). A split person is easy to fix by
    /// naming both groups the same; a wrong merge is not.
    public init(joinThreshold: Float = 0.55, mergeThreshold: Float = 0.6) {
        self.joinThreshold = joinThreshold
        self.mergeThreshold = mergeThreshold
    }

    /// Adds an already-assigned face to a stored person.
    public mutating func seed(person: PersonID, isNamed: Bool, print: [Float]) -> Int {
        if let index = groups.firstIndex(where: { $0.person == person }) {
            add(print, to: index)
            return index
        }
        groups.append(Group(person: person, isNamed: isNamed, sum: print, count: 1))
        unitCentroids.append(Self.normalized(print))
        return groups.count - 1
    }

    /// Assigns a new face, returning its group's index (follow `resolve` after merges).
    public mutating func assign(_ print: [Float]) -> Int {
        var best: (index: Int, similarity: Float)?
        for index in groups.indices where groups[index].mergedInto == nil {
            let similarity = Self.dot(unitCentroids[index], print)
            if similarity >= joinThreshold, similarity > best?.similarity ?? -1 { best = (index, similarity) }
        }
        if let best {
            add(print, to: best.index)
            return best.index
        }
        groups.append(Group(person: nil, isNamed: false, sum: print, count: 1))
        unitCentroids.append(Self.normalized(print))
        return groups.count - 1
    }

    /// Merges groups in `touched` into any close group, the larger or named one absorbing the
    /// other. Returns the merges as (from, into) indexes.
    @discardableResult
    public mutating func mergeClose(_ touched: Set<Int>) -> [(from: Int, into: Int)] {
        var merges: [(from: Int, into: Int)] = []
        var queue = Array(touched).sorted()
        while let index = queue.popLast() {
            guard groups[index].mergedInto == nil else { continue }
            var best: (index: Int, similarity: Float)?
            for other in groups.indices where other != index && groups[other].mergedInto == nil {
                guard !(groups[index].isNamed && groups[other].isNamed) else { continue }
                let similarity = Self.dot(unitCentroids[index], unitCentroids[other])
                if similarity >= mergeThreshold, similarity > best?.similarity ?? -1 { best = (other, similarity) }
            }
            guard let other = best?.index else { continue }
            let keepOther = groups[other].isNamed || (!groups[index].isNamed && groups[other].count >= groups[index].count)
            let (from, into) = keepOther ? (index, other) : (other, index)
            // Keep the stored person's id when a group from this run absorbs them.
            if groups[into].person == nil {
                (groups[into].person, groups[from].person) = (groups[from].person, nil)
                (groups[into].isNamed, groups[from].isNamed) = (groups[from].isNamed, false)
            }
            for dimension in groups[into].sum.indices { groups[into].sum[dimension] += groups[from].sum[dimension] }
            groups[into].count += groups[from].count
            unitCentroids[into] = Self.normalized(groups[into].sum)
            groups[from].mergedInto = into
            merges.append((from, into))
            queue.append(into)
        }
        return merges
    }

    /// The group `index` ended up in after merges.
    public func resolve(_ index: Int) -> Int {
        var current = index
        while let next = groups[current].mergedInto { current = next }
        return current
    }

    private mutating func add(_ print: [Float], to index: Int) {
        for dimension in groups[index].sum.indices where dimension < print.count { groups[index].sum[dimension] += print[dimension] }
        groups[index].count += 1
        unitCentroids[index] = Self.normalized(groups[index].sum)
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? vector.map { $0 / norm } : vector
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for index in 0..<min(a.count, b.count) { sum += a[index] * b[index] }
        return sum
    }
}
