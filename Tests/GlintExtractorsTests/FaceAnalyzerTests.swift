import CoreGraphics
import Foundation
import GlintCore
import GlintTestSupport
import Testing

@testable import GlintExtractors

@Suite("FaceAnalyzer")
struct FaceAnalyzerTests {
    @Test func bundledRecognizerLoads() {
        #expect(FaceAnalyzer.isAvailable)
    }

    @Test func identityVectorsAreUnitLength() throws {
        let context = try #require(
            CGContext(
                data: nil, width: 112, height: 112, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.6, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 112, height: 112))
        let image = try #require(context.makeImage())
        let print = try #require(Recognizer.shared?.identity(of: image))
        #expect(print.count == 128)
        #expect(abs(print.reduce(0) { $0 + $1 * $1 } - 1) < 1e-3)
    }

    @Test func findsNoFacesInAGradient() throws {
        let directory = try TemporaryDirectory()
        let url = try Fixtures.writeGradientImage(in: directory.url, size: CGSize(width: 800, height: 600))
        let image = try ImageProcessing.downscaledImage(at: url, maxPixel: 1_024)
        #expect(FaceAnalyzer().faces(in: image).isEmpty)
    }

    @Test func similarityRecoversRotationScaleAndShift() throws {
        let angle = 0.3
        let expected = CGAffineTransform(rotationAngle: angle).scaledBy(x: 2, y: 2).translatedBy(x: 5, y: -3)
        let source = FaceAlignment.template
        let target = source.map { $0.applying(expected) }
        let found = try #require(FaceAlignment.similarity(from: source, to: target))
        for (point, wanted) in zip(source.map { $0.applying(found) }, target) {
            #expect(abs(point.x - wanted.x) < 1e-6 && abs(point.y - wanted.y) < 1e-6)
        }
    }
}
