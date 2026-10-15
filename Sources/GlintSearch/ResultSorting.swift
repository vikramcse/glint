import Foundation
import GlintCore

extension Array where Element == SearchResult {
    /// The results in `sort` order. Relevance keeps the order they came in; other fields break
    /// ties by relevance, and files without a length sort after those with one either way.
    public func sorted(by sort: ResultSort) -> [SearchResult] {
        guard sort.field != .relevance else { return self }
        let ranked = enumerated().map { (rank: $0.offset, file: $0.element.file) }
        let order = ranked.sorted { lhs, rhs in
            if sort.field == .duration, (lhs.file.duration == nil) != (rhs.file.duration == nil) {
                return lhs.file.duration != nil
            }
            switch Self.compare(lhs.file, rhs.file, by: sort.field) {
            case .orderedAscending: return sort.ascending
            case .orderedDescending: return !sort.ascending
            case .orderedSame: return lhs.rank < rhs.rank
            }
        }
        return order.map { self[$0.rank] }
    }

    private static func compare(_ lhs: FileSummary, _ rhs: FileSummary, by field: ResultSort.Field) -> ComparisonResult {
        switch field {
        case .relevance: .orderedSame
        case .modified: order(lhs.modified, rhs.modified)
        case .name: lhs.name.localizedStandardCompare(rhs.name)
        case .size: order(lhs.size, rhs.size)
        case .kind: order(lhs.kind.rawValue, rhs.kind.rawValue)
        case .duration: order(lhs.duration ?? 0, rhs.duration ?? 0)
        }
    }

    private static func order<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
    }
}
