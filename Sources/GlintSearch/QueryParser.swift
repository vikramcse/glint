import Foundation
import GlintCore

/// A filter token typed or picked in the search field ("kind:video", "in:Downloads", "date:week").
public enum SearchToken: Sendable, Hashable, Identifiable {
    case kind(MediaKind)
    case folder(String)
    case modifiedSince(DateRangePreset)

    public var id: String {
        switch self {
        case .kind(let kind): "kind:\(kind.rawValue)"
        case .folder(let path): "in:\(path)"
        case .modifiedSince(let preset): "date:\(preset.rawValue)"
        }
    }
}

/// Relative date ranges offered as tokens.
public enum DateRangePreset: String, Sendable, Hashable, CaseIterable {
    case today, week, month, year

    public func startDate(relativeTo now: Date, calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        switch self {
        case .today: return startOfToday
        case .week: return calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
        case .month: return calendar.date(byAdding: .month, value: -1, to: startOfToday) ?? startOfToday
        case .year: return calendar.date(byAdding: .year, value: -1, to: startOfToday) ?? startOfToday
        }
    }
}

/// A query split into free text and filter tokens.
public struct ParsedQuery: Sendable, Hashable {
    public var text: String
    public var tokens: [SearchToken]

    public init(text: String, tokens: [SearchToken] = []) {
        self.text = text
        self.tokens = tokens
    }

    /// Builds the filter.
    public func filter(sources: [String] = [], now: Date = Date()) -> SearchFilter {
        var filter = SearchFilter()
        for token in tokens {
            switch token {
            case .kind(let kind):
                filter.kinds.insert(kind)
            case .folder(let name):
                let matches = sources.filter {
                    $0 == name || URL(fileURLWithPath: $0).lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
                }
                filter.folders.append(contentsOf: matches.isEmpty ? [name] : matches)
            case .modifiedSince(let preset):
                let start = preset.startDate(relativeTo: now)
                filter.modifiedAfter = max(filter.modifiedAfter ?? start, start)
            }
        }
        return filter
    }
}

/// Parses inline tokens: `kind:` (or `type:`), `in:` (or `folder:`) and `date:`.
public enum QueryParser {
    public static func parse(_ input: String) -> ParsedQuery {
        var words: [String] = []
        var tokens: [SearchToken] = []
        for word in input.split(separator: " ", omittingEmptySubsequences: false) {
            if let token = token(from: String(word)) {
                tokens.append(token)
            } else {
                words.append(String(word))
            }
        }
        return ParsedQuery(text: words.joined(separator: " ").trimmingCharacters(in: .whitespaces), tokens: tokens)
    }

    static func token(from word: String) -> SearchToken? {
        guard let colon = word.firstIndex(of: ":") else { return nil }
        let key = word[..<colon].lowercased()
        let value = String(word[word.index(after: colon)...])
        guard !value.isEmpty else { return nil }
        switch key {
        case "kind", "type":
            return kind(named: value.lowercased()).map(SearchToken.kind)
        case "in", "folder":
            return .folder(value)
        case "date", "modified":
            return DateRangePreset(rawValue: value.lowercased()).map(SearchToken.modifiedSince)
        default:
            return nil
        }
    }

    static func kind(named name: String) -> MediaKind? {
        switch name {
        case "image", "images", "photo", "photos", "screenshot", "screenshots": .image
        case "video", "videos", "movie", "movies", "clip", "clips": .video
        case "audio", "sound", "voice", "memo", "memos", "recording", "recordings": .audio
        case "pdf", "pdfs": .pdf
        case "doc", "docs", "document", "documents", "text", "note", "notes": .document
        default: nil
        }
    }
}
