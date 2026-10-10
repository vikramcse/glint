import GlintSearch
import SwiftUI

/// A snippet with matched terms emphasized, the way Mail and Spotlight highlight matches.
struct SnippetText: View {
    let snippet: Snippet
    var lineLimit = 2

    var body: some View {
        Text(attributed)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
    }

    private var attributed: AttributedString {
        var result = AttributedString(snippet.text)
        for range in snippet.highlights {
            guard let lower = AttributedString.Index(range.lowerBound, within: result),
                let upper = AttributedString.Index(range.upperBound, within: result)
            else { continue }
            result[lower..<upper].font = .callout.weight(.semibold)
            result[lower..<upper].foregroundColor = .primary
        }
        return result
    }
}
