import AppKit
import GlintCore
import GlintSearch
import PDFKit
import SwiftUI

/// What to show when a PDF result opens: the matched page and the words to highlight.
public struct PDFMatchTarget: Sendable, Hashable {
    public var url: URL
    /// Zero-based page from the match.
    public var pageIndex: Int
    public var terms: [String]

    public init(url: URL, pageIndex: Int, terms: [String]) {
        self.url = url
        self.pageIndex = pageIndex
        self.terms = terms
    }

    /// The target for a PDF search result.
    public init(result: SearchResult) {
        self.init(
            url: result.file.url, pageIndex: result.match.locator.pageIndex ?? 0,
            terms: result.match.snippet.map(Self.highlightTerms(from:)) ?? [])
    }

    /// The distinct words the snippet highlights (what the query matched), longest first so
    /// a phrase wins over a word inside it. One-letter matches are skipped.
    public static func highlightTerms(from snippet: Snippet) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for range in snippet.highlights {
            let term = String(snippet.text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count >= 2, seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
        }
        return terms.sorted { $0.count > $1.count }
    }

    /// A page index that exists in a document of `pageCount` pages.
    public static func clampedPage(_ index: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return min(max(index, 0), pageCount - 1)
    }
}

/// Glint's PDF window: opens at the matched page with query terms highlighted.
public struct PDFPageViewer: View {
    let target: PDFMatchTarget
    @State private var document: PDFDocument?
    @State private var currentPage = 0

    public init(target: PDFMatchTarget) {
        self.target = target
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let document {
                PDFKitView(document: document, target: target, currentPage: $currentPage)
            } else {
                ContentUnavailableView(String(localized: "Can’t Open This PDF"), systemImage: "doc.questionmark")
            }
            Divider()
            HStack {
                if let document {
                    Text("Page \(currentPage + 1) of \(document.pageCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open in Preview") { Self.openInPreview(target.url) }
            }
            .padding(10)
        }
        .frame(minWidth: 520, minHeight: 600)
        .task(id: target) {
            document = PDFDocument(url: target.url)
            currentPage = PDFMatchTarget.clampedPage(target.pageIndex, pageCount: document?.pageCount ?? 0)
        }
    }

    static func openInPreview(_ url: URL) {
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// `PDFView` scrolled to the target page, with matches on that page highlighted.
private struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    let target: PDFMatchTarget
    @Binding var currentPage: Int

    func makeCoordinator() -> Coordinator { Coordinator(currentPage: $currentPage) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        context.coordinator.observe(view)
        show(in: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
            show(in: view)
        }
    }

    private func show(in view: PDFView) {
        let index = PDFMatchTarget.clampedPage(target.pageIndex, pageCount: document.pageCount)
        guard let page = document.page(at: index) else { return }
        var selections: [PDFSelection] = []
        for term in target.terms {
            for selection in document.findString(term, withOptions: [.caseInsensitive, .diacriticInsensitive])
            where selection.pages.contains(page) {
                selection.color = NSColor.findHighlightColor
                selections.append(selection)
            }
        }
        view.highlightedSelections = selections.isEmpty ? nil : selections
        DispatchQueue.main.async {
            if let first = selections.first {
                view.go(to: first)
            } else {
                view.go(to: page)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        let currentPage: Binding<Int>
        private var observer: (any NSObjectProtocol)?

        init(currentPage: Binding<Int>) {
            self.currentPage = currentPage
        }

        func observe(_ view: PDFView) {
            observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) {
                [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let view, let page = view.currentPage, let document = view.document else { return }
                    self?.currentPage.wrappedValue = document.index(for: page)
                }
            }
        }
    }
}
