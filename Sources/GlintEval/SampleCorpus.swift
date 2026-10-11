import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Generates a small, fully synthetic eval corpus we own outright (no third-party media):
/// notes, rendered screenshots with text, and a multi-page PDF with a chart. The full
/// 3,000-file persona corpus lives outside the repo; this one runs on every pull request.
enum SampleCorpus {
    /// Writes `<directory>/corpus/…` and `<directory>/queries.json`.
    static func write(to directory: URL) throws {
        let root = directory.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in documents { try writeText(text, to: root.appendingPathComponent(path)) }
        for (path, lines) in screenshots { try writeScreenshot(lines, to: root.appendingPathComponent(path)) }
        try writePitchDeck(to: root.appendingPathComponent("work/Acme pitch.pdf"))
        try JSONEncoder.pretty.encode(EvalQuerySet(queries: queries)).write(to: directory.appendingPathComponent("queries.json"))
    }

    static let documents: [(String, String)] = [
        (
            "notes/product-launch.md",
            "# Product launch plan\n\nLaunch date moves to March. Marketing owns the press kit; engineering ships the onboarding fixes first. Risks: pricing page copy and the waitlist email."
        ),
        (
            "notes/standup-2026-09-14.txt",
            "Standup notes. The client mentioned the deadline is Friday the 19th. Priya will send the revised contract. Budget approval pending from finance."
        ),
        (
            "recipes/pasta.txt",
            "Weeknight pasta sauce: crush ripe tomatoes with garlic and olive oil, simmer twenty minutes, finish with torn basil and parmesan."
        ),
        (
            "recipes/bread.txt",
            "Sourdough loaf: feed the starter the night before, autolyse flour and water for an hour, bulk ferment until doubled, bake in a dutch oven."
        ),
        (
            "travel/goa-itinerary.md",
            "Goa trip itinerary: arrive Dabolim airport, check in at the Seaview hotel in Candolim, sunset at Chapora fort, spice plantation tour on day three."
        ),
        (
            "work/retro.txt",
            "Sprint retrospective: what went well was pairing on the search ranking. What to improve: flaky CI on the indexing tests and slow code review turnaround."
        ),
        (
            "code/vector_scan.swift",
            "// Scores every row of the matrix against the query with one matrix-vector multiply\nfunc scan(matrix: [Float], query: [Float]) -> [Float] { [] }"
        ),
        (
            "finance/q3-summary.txt",
            "Q3 summary: revenue grew 18 percent year over year, led by Europe. Gross margin improved to 71 percent. Hiring paused in support."
        ),
    ]

    static let screenshots: [(String, [String])] = [
        ("Screenshots/flight.png", ["Flight confirmation", "IndiGo 6E 2341", "BLR to GOI · 12 Dec", "Booking ref QX7P2M"]),
        ("Screenshots/receipt.png", ["Seaview Hotel Candolim", "Receipt #4471", "2 nights · INR 18,400", "Paid by card"]),
        ("Screenshots/wifi.png", ["Office Wi-Fi", "Network: Glint-Guest", "Password: blue-mug-42"]),
    ]

    static let queries: [EvalQuery] = [
        EvalQuery(id: "flight-confirmation", text: "flight confirmation", mustPass: true, relevant: ["Screenshots/flight.png": 2]),
        EvalQuery(
            id: "hotel-receipt-goa", text: "the receipt from the hotel in Goa", mustPass: true,
            relevant: ["Screenshots/receipt.png": 2, "travel/goa-itinerary.md": 1]),
        EvalQuery(id: "wifi-password", text: "guest wifi password", mustPass: true, relevant: ["Screenshots/wifi.png": 2]),
        EvalQuery(id: "pricing-chart", text: "pricing chart for the Acme pitch", mustPass: true, relevant: ["work/Acme pitch.pdf": 2]),
        EvalQuery(
            id: "revenue-by-region", text: "chart showing revenue by region",
            relevant: ["work/Acme pitch.pdf": 2, "finance/q3-summary.txt": 1]),
        EvalQuery(
            id: "client-deadline", text: "when the client mentioned the deadline", mustPass: true,
            relevant: ["notes/standup-2026-09-14.txt": 2]),
        EvalQuery(id: "tomato-recipe", text: "recipe with tomatoes and basil", relevant: ["recipes/pasta.txt": 2]),
        EvalQuery(id: "baking", text: "how to bake bread", relevant: ["recipes/bread.txt": 2]),
        EvalQuery(id: "launch-plan", text: "plan for the product launch", relevant: ["notes/product-launch.md": 2]),
        EvalQuery(
            id: "goa-trip", text: "trip to the beach in India", relevant: ["travel/goa-itinerary.md": 2, "Screenshots/flight.png": 1]),
        EvalQuery(id: "flaky-ci", text: "flaky tests in continuous integration", relevant: ["work/retro.txt": 2]),
        EvalQuery(id: "quarterly-results", text: "quarterly financial results", relevant: ["finance/q3-summary.txt": 2]),
        EvalQuery(id: "matrix-code", text: "matrix vector multiply", relevant: ["code/vector_scan.swift": 2]),
        // Negative queries: nothing in the corpus matches, so the right answer is no results.
        EvalQuery(id: "none-elephant", text: "elephant safari", relevant: [:]),
        EvalQuery(id: "none-guitar", text: "guitar chords for a love song", relevant: [:]),
        EvalQuery(id: "none-dentist", text: "dentist appointment", relevant: [:]),
    ]

    // MARK: Writers

    private static func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeScreenshot(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let width = 1_200
        let height = 140 + lines.count * 90
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, line) in lines.enumerated() {
            let size: CGFloat = index == 0 ? 64 : 48
            draw(line, in: context, at: CGPoint(x: 60, y: CGFloat(height - 110 - index * 90)), size: size, bold: index == 0)
        }
        guard let image = context.makeImage(),
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }

    private static func writePitchDeck(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var box = CGRect(x: 0, y: 0, width: 960, height: 540)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }

        context.beginPDFPage(nil)
        draw("Acme Corp — Partnership Proposal", in: context, at: CGPoint(x: 60, y: 440), size: 40, bold: true)
        draw("Prepared for the Acme leadership team", in: context, at: CGPoint(x: 60, y: 390), size: 24, bold: false)
        context.endPDFPage()

        context.beginPDFPage(nil)
        draw("Pricing", in: context, at: CGPoint(x: 60, y: 460), size: 36, bold: true)
        draw("Starter $19 · Team $49 · Enterprise custom", in: context, at: CGPoint(x: 60, y: 410), size: 22, bold: false)
        let bars: [(String, CGFloat)] = [("Starter", 120), ("Team", 260), ("Enterprise", 340)]
        for (index, bar) in bars.enumerated() {
            let x = CGFloat(120 + index * 220)
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.85, alpha: 1))
            context.fill(CGRect(x: x, y: 60, width: 120, height: bar.1))
            draw(bar.0, in: context, at: CGPoint(x: x, y: 30), size: 18, bold: false)
        }
        context.endPDFPage()

        context.beginPDFPage(nil)
        draw("Revenue by region", in: context, at: CGPoint(x: 60, y: 460), size: 36, bold: true)
        draw("Europe 42% · North America 35% · Asia Pacific 23%", in: context, at: CGPoint(x: 60, y: 410), size: 22, bold: false)
        context.endPDFPage()
        context.closePDF()
    }

    private static func draw(_ text: String, in context: CGContext, at point: CGPoint, size: CGFloat, bold: Bool) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
