import AppKit
import CoreGraphics
import CoreText
import Foundation
import GlintTestSupport
import ImageIO
import UniformTypeIdentifiers

/// How many files of each kind the throughput benchmark generates.
struct BenchCounts: Codable, Sendable {
    var photos = 40
    var screenshots = 40
    var pdfs = 12
    var docs = 120
    var audio = 6
    var videos = 4

    static let kinds = ["photos", "screenshots", "pdfs", "docs", "audio", "videos"]

    func count(_ kind: String) -> Int {
        switch kind {
        case "photos": photos
        case "screenshots": screenshots
        case "pdfs": pdfs
        case "docs": docs
        case "audio": audio
        default: videos
        }
    }
}

/// Generates a realistic throughput corpus once: one subfolder per kind, reused across runs.
/// Photos are 12 MP JPEGs with texture and camera EXIF, screenshots are Retina PNGs full of
/// text, PDFs have 10 text pages with a chart, audio is 1–3 minutes, video is 1080p H.264.
enum BenchCorpus {
    static func ensure(at root: URL, counts: BenchCounts) async throws {
        let lorem = """
            Quarterly planning notes for the Acme account. Revenue grew in Europe while pricing pressure \
            increased in Asia Pacific. The client mentioned the deadline is Friday, and legal still needs \
            to review the contract. Next steps: finalize the pitch deck, confirm travel to Goa, and send \
            the onboarding checklist to the new hires. Budget approval is pending from finance.
            """
        for kind in BenchCounts.kinds {
            let folder = root.appendingPathComponent(kind, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.count) ?? 0
            let wanted = counts.count(kind)
            guard existing < wanted else { continue }
            print("Generating \(wanted - existing) \(kind)…")
            for index in existing..<wanted {
                switch kind {
                case "photos": try writePhoto(index: index, to: folder.appendingPathComponent(String(format: "IMG_%04d.jpg", index)))
                case "screenshots":
                    try writeScreenshot(index: index, text: lorem, to: folder.appendingPathComponent("Screenshot \(index).png"))
                case "pdfs": try writePDF(index: index, text: lorem, to: folder.appendingPathComponent("Report \(index).pdf"))
                case "docs":
                    let body = (0..<(4 + index % 12)).map { "## Section \($0)\n\n\(lorem)\n" }.joined(separator: "\n")
                    try "# Notes \(index)\n\n\(body)".write(to: folder.appendingPathComponent("notes-\(index).md"), atomically: true, encoding: .utf8)
                case "audio":
                    try Fixtures.writeToneWAV(
                        duration: Double(60 + (index % 3) * 60), frequency: 220 + Double(index * 40), named: "memo-\(index).wav", in: folder)
                default:
                    try await Fixtures.writeVideo(
                        duration: Double(30 + (index % 2) * 30), named: "clip-\(index).mp4", in: folder,
                        size: CGSize(width: 1_920, height: 1_080), framesPerSecond: 30)
                }
            }
        }
    }

    private static func context(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        return context
    }

    private static func writePhoto(index: Int, to url: URL) throws {
        var generator = SeededGenerator(seed: UInt64(index + 1))
        let context = try context(width: 4_032, height: 3_024)
        for _ in 0..<400 {
            context.setFillColor(
                CGColor(
                    red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                    blue: .random(in: 0...1, using: &generator), alpha: .random(in: 0.3...1, using: &generator)))
            let rect = CGRect(
                x: .random(in: 0...4_032, using: &generator), y: .random(in: 0...3_024, using: &generator),
                width: .random(in: 20...900, using: &generator), height: .random(in: 20...900, using: &generator))
            if Bool.random(using: &generator) { context.fillEllipse(in: rect) } else { context.fill(rect) }
        }
        // Every tenth photo shows a sign, exercising the camera-photo OCR path.
        if index % 10 == 0 {
            context.setFillColor(CGColor(gray: 0.95, alpha: 1))
            context.fill(CGRect(x: 900, y: 1_100, width: 2_200, height: 700))
            draw("DEADLINE FRIDAY", in: context, at: CGPoint(x: 1_000, y: 1_350), size: 220)
        }
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 16 Pro"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "iPhone 16 Pro back camera"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func writeScreenshot(index: Int, text: String, to url: URL) throws {
        let context = try context(width: 2_880, height: 1_800)
        context.setFillColor(CGColor(gray: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2_880, height: 1_800))
        let words = text.split(separator: " ")
        for line in 0..<28 {
            let start = (line * 9 + index) % words.count
            let sentence = (0..<12).map { String(words[(start + $0) % words.count]) }.joined(separator: " ")
            draw(sentence, in: context, at: CGPoint(x: 120, y: 1_700 - line * 58), size: 34)
        }
        guard let image = context.makeImage(),
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }

    private static func writePDF(index: Int, text: String, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        for page in 0..<10 {
            context.beginPDFPage(nil)
            draw("Report \(index) — page \(page + 1)", in: context, at: CGPoint(x: 60, y: 720), size: 22)
            let words = text.split(separator: " ")
            for line in 0..<24 {
                let sentence = (0..<10).map { String(words[(line * 10 + $0 + page) % words.count]) }.joined(separator: " ")
                draw(sentence, in: context, at: CGPoint(x: 60, y: 680 - line * 20), size: 11)
            }
            for bar in 0..<5 {
                context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.85, alpha: 1))
                context.fill(CGRect(x: 80 + bar * 90, y: 60, width: 60, height: 40 + ((bar + page) % 5) * 30))
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func draw(_ text: String, in context: CGContext, at point: CGPoint, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(gray: 0.1, alpha: 1)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }
}

/// Deterministic random numbers so the corpus is identical on every machine.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
