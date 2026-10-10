import AppKit
import CoreGraphics
import CoreText
import Foundation
import GlintCore
import ImageIO
import UniformTypeIdentifiers

/// Generates test files at run time so no binary fixtures live in the repository.
public enum Fixtures {
    public enum FixtureError: Error {
        case cannotCreate(String)
    }

    // MARK: Text

    /// Writes `text` with an encoding, optionally prefixed with the encoding's byte-order mark.
    @discardableResult
    public static func writeText(
        _ text: String, named name: String, in directory: URL,
        encoding: String.Encoding = .utf8, byteOrderMark: Bool = false
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        guard var data = text.data(using: encoding, allowLossyConversion: false) else {
            throw FixtureError.cannotCreate("text in \(encoding)")
        }
        if byteOrderMark {
            switch encoding {
            case .utf8: data = Data([0xEF, 0xBB, 0xBF]) + data
            case .utf16LittleEndian: data = Data([0xFF, 0xFE]) + data
            case .utf16BigEndian: data = Data([0xFE, 0xFF]) + data
            default: break
            }
        }
        try data.write(to: url)
        return url
    }

    /// Writes raw bytes (for corrupt and zero-byte files).
    @discardableResult
    public static func writeData(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Writes an RTF document containing `text` in bold and regular runs.
    @discardableResult
    public static func writeRTF(_ text: String, named name: String = "document.rtf", in directory: URL) throws -> URL {
        let string = NSMutableAttributedString(
            string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)]
        )
        string.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: NSRange(location: 0, length: min(5, string.length)))
        let data = try string.data(
            from: NSRange(location: 0, length: string.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: PDF

    /// Writes a US Letter PDF with one page per string, drawn with Core Text so PDFKit can
    /// extract the text. An empty string makes a page with no text layer.
    @discardableResult
    public static func writePDF(pages: [String], named name: String = "document.pdf", in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw FixtureError.cannotCreate("PDF context")
        }
        for text in pages {
            context.beginPDFPage(nil)
            if !text.isEmpty {
                draw(text, in: mediaBox.insetBy(dx: 54, dy: 54), fontSize: 18, context: context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    // MARK: Images

    /// Writes a PNG with `text` drawn large in black on white, readable by Vision OCR.
    @discardableResult
    public static func writeTextImage(
        _ text: String, named name: String = "words.png", in directory: URL,
        size: CGSize = CGSize(width: 1_200, height: 400)
    ) throws -> URL {
        let context = try bitmapContext(size: size)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        draw(text, in: CGRect(origin: .zero, size: size).insetBy(dx: 40, dy: 40), fontSize: 72, context: context)
        return try writePNG(context, to: directory.appendingPathComponent(name))
    }

    /// Writes a PNG filled with a horizontal gradient between two colors (no text).
    @discardableResult
    public static func writeGradientImage(
        named name: String = "gradient.png", in directory: URL,
        size: CGSize = CGSize(width: 2_000, height: 1_500),
        from start: CGColor = CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1),
        to end: CGColor = CGColor(red: 0.9, green: 0.6, blue: 0.1, alpha: 1)
    ) throws -> URL {
        let context = try bitmapContext(size: size)
        guard let gradient = CGGradient(colorsSpace: context.colorSpace, colors: [start, end] as CFArray, locations: nil) else {
            throw FixtureError.cannotCreate("gradient")
        }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: 0), options: [])
        return try writePNG(context, to: directory.appendingPathComponent(name))
    }

    // MARK: Audio

    /// Writes a 16-bit PCM WAV sine tone.
    @discardableResult
    public static func writeToneWAV(
        duration: Double, frequency: Double = 440, sampleRate: Int = 44_100, channels: Int = 1,
        named name: String = "tone.wav", in directory: URL
    ) throws -> URL {
        let frames = Int(duration * Double(sampleRate))
        var pcm = Data(capacity: frames * channels * 2)
        for frame in 0..<frames {
            let value = sin(2 * .pi * frequency * Double(frame) / Double(sampleRate)) * 0.5
            let sample = Int16(value * Double(Int16.max))
            for _ in 0..<channels {
                withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
            }
        }
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        header.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * channels * 2))
        append(UInt16(channels * 2))
        append(UInt16(16))
        header.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        let url = directory.appendingPathComponent(name)
        try (header + pcm).write(to: url)
        return url
    }

    // MARK: Helpers

    /// A `FileRef` for a fixture, with kind and type inferred from the extension.
    public static func fileRef(_ url: URL, id: Int64 = 1) throws -> FileRef {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .contentTypeKey])
        guard let type = values.contentType ?? UTType(filenameExtension: url.pathExtension),
            let kind = MediaKind(contentType: type)
        else { throw FixtureError.cannotCreate("FileRef for .\(url.pathExtension)") }
        return FileRef(
            id: FileID(id), url: url, kind: kind, contentType: type,
            size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? Date()
        )
    }

    static func bitmapContext(size: CGSize) throws -> CGContext {
        guard
            let context = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw FixtureError.cannotCreate("bitmap context") }
        return context
    }

    static func writePNG(_ context: CGContext, to url: URL) throws -> URL {
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw FixtureError.cannotCreate("PNG") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.cannotCreate("PNG") }
        return url
    }

    /// Draws wrapped black text with Core Text inside `rect` (Core Graphics coordinates).
    static func draw(_ text: String, in rect: CGRect, fontSize: CGFloat, context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        context.saveGState()
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}
