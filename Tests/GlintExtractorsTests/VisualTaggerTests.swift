import CoreGraphics
import Testing

@testable import GlintExtractors

@Suite("Visual tags")
struct VisualTaggerTests {
    @Test(arguments: [
        ((0.92, 0.92, 0.88), "white"),
        ((0.69, 0.69, 0.59), "white"),
        ((0.05, 0.05, 0.06), "black"),
        ((0.5, 0.5, 0.52), "gray"),
        ((0.91, 0.61, 0.79), "pink"),
        ((0.85, 0.1, 0.1), "red"),
        ((0.2, 0.3, 0.8), "blue"),
        ((0.1, 0.15, 0.35), "navy"),
        ((0.2, 0.6, 0.25), "green"),
        ((0.95, 0.85, 0.2), "yellow"),
    ])
    func namesColors(rgb: (Double, Double, Double), expected: String) {
        #expect(ColorNamer.name(red: rgb.0, green: rgb.1, blue: rgb.2) == expected)
    }

    @Test func medianIgnoresPixelsOutsideThePerson() throws {
        // Left half white (the "person"), right half red (background).
        let context = try #require(
            CGContext(
                data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 50, y: 0, width: 50, height: 100))
        let image = try #require(context.makeImage())
        let pixels = try #require(RGBAPixels(image))
        let mask = PersonMask(width: 2, height: 1, bytesPerRow: 2, bytes: [255, 0])
        let color = try #require(pixels.medianColor(in: CGRect(x: 0, y: 0, width: 1, height: 1), mask: mask))
        #expect(ColorNamer.name(red: color.red, green: color.green, blue: color.blue) == "white")
    }

    @Test func blankImageHasNoPeople() throws {
        let context = try #require(
            CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let tags = VisualTagger().tags(for: image)
        #expect(!tags.contains { $0.hasPrefix("person in") })
    }
}
