// Renders the Glint app icon: a graphite loupe on a warm paper tile, with a streak of light
// on the glass (the glint). Drawn in a 1024 grid, so every size is rendered, not scaled.
// Run: swift scripts/make_icon.swift [App/Assets.xcassets/AppIcon.appiconset]
import AppKit
import CoreGraphics

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "App/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.displayP3)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    let red = CGFloat((hex >> 16) & 0xFF) / 255, green = CGFloat((hex >> 8) & 0xFF) / 255, blue = CGFloat(hex & 0xFF) / 255
    return CGColor(colorSpace: space, components: [red, green, blue, alpha])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
    CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
}

/// The macOS icon shape: a superellipse (continuous corners), not a rounded rectangle.
func squircle(_ rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let exponent: CGFloat = 5
    for step in 0...720 {
        let angle = CGFloat(step) / 720 * 2 * .pi
        let x = rect.width / 2 * (cos(angle) < 0 ? -1 : 1) * pow(abs(cos(angle)), 2 / exponent)
        let y = rect.height / 2 * (sin(angle) < 0 ? -1 : 1) * pow(abs(sin(angle)), 2 / exponent)
        let point = CGPoint(x: rect.midX + x, y: rect.midY + y)
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

func render(_ pixels: Int) -> Data? {
    guard
        let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 16, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
    else { return nil }
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    /// A thin band of reflected light along an arc, fading out at both ends.
    func streak(_ center: CGPoint, inner: CGFloat, outer: CGFloat, from start: CGFloat, to end: CGFloat, alpha: CGFloat) {
        let band = CGMutablePath()
        band.addArc(center: center, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        band.addArc(center: center, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        band.closeSubpath()
        context.saveGState()
        context.addPath(band)
        context.clip()
        let fade = gradient([(0, rgb(0xFFFFFF, 0)), (0.35, rgb(0xFFFFFF, alpha)), (0.65, rgb(0xFFFFFF, alpha)), (1, rgb(0xFFFFFF, 0))])
        context.drawLinearGradient(
            fade, start: CGPoint(x: center.x + cos(start) * outer, y: center.y + sin(start) * outer),
            end: CGPoint(x: center.x + cos(end) * outer, y: center.y + sin(end) * outer), options: [])
        context.restoreGState()
    }

    // Tile: the 824 pt body of the macOS icon grid, warm paper with a hairline edge.
    let tile = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.30))
    context.addPath(tile)
    context.setFillColor(rgb(0xE4DDD0))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(tile)
    context.clip()
    context.drawLinearGradient(
        gradient([(0, rgb(0xF8F5EF)), (1, rgb(0xE4DDD0))]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    context.addPath(tile)
    context.setLineWidth(4)
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(
        gradient([(0, rgb(0xFFFFFF, 0.55)), (0.5, rgb(0xFFFFFF, 0)), (1, rgb(0x000000, 0.18))]),
        start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    context.restoreGState()

    let center = CGPoint(x: 462, y: 566)
    let outer: CGFloat = 214
    let glass: CGFloat = 168
    let angle = -CGFloat.pi / 4

    // Handle, under the ring, with a steel ferrule where it meets the ring.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 10, height: -22), blur: 34, color: rgb(0x3B2F1E, 0.30))
    context.translateBy(x: center.x + cos(angle) * (outer - 10), y: center.y + sin(angle) * (outer - 10))
    context.rotate(by: angle)
    context.addPath(CGPath(roundedRect: CGRect(x: 0, y: -44, width: 250, height: 88), cornerWidth: 44, cornerHeight: 44, transform: nil))
    context.clip()
    context.drawLinearGradient(
        gradient([(0, rgb(0x4A4E57)), (0.45, rgb(0x2A2D33)), (1, rgb(0x16181C))]), start: CGPoint(x: 0, y: 44),
        end: CGPoint(x: 0, y: -44), options: [])
    context.setFillColor(rgb(0xB9BCC2))
    context.fill(CGRect(x: 18, y: -44, width: 26, height: 88))
    context.setFillColor(rgb(0xFFFFFF, 0.35))
    context.fill(CGRect(x: 18, y: 14, width: 26, height: 20))
    context.restoreGState()

    // Ring, casting a shadow on the paper.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 8, height: -20), blur: 36, color: rgb(0x3B2F1E, 0.32))
    context.setFillColor(rgb(0x202227))
    context.fillEllipse(in: circle(center, outer))
    context.restoreGState()
    context.saveGState()
    context.addEllipse(in: circle(center, outer))
    context.clip()
    context.drawLinearGradient(
        gradient([(0, rgb(0x5A5F69)), (0.5, rgb(0x2B2E35)), (1, rgb(0x15171B))]),
        start: CGPoint(x: center.x - outer, y: center.y + outer), end: CGPoint(x: center.x + outer, y: center.y - outer), options: [])
    context.restoreGState()

    // Glass: clear and slightly blue, lighter where it catches the sky, shaded by the ring.
    context.saveGState()
    context.addEllipse(in: circle(center, glass))
    context.clip()
    context.drawLinearGradient(
        gradient([(0, rgb(0xE9F2FC)), (0.55, rgb(0xB7CEEA)), (1, rgb(0x7E9FCB))]),
        start: CGPoint(x: center.x - glass, y: center.y + glass), end: CGPoint(x: center.x + glass, y: center.y - glass), options: [])
    context.setShadow(offset: CGSize(width: 4, height: -8), blur: 24, color: rgb(0x0B1630, 0.55))
    context.addRect(circle(center, glass + 60))
    context.addEllipse(in: circle(center, glass))
    context.setFillColor(rgb(0x000000))
    context.fillPath(using: .evenOdd)
    context.restoreGState()

    // The glint: a streak of light along the upper left of the glass, and a small spark opposite.
    streak(center, inner: glass - 46, outer: glass - 24, from: .pi * 0.58, to: .pi * 1.02, alpha: 0.95)
    context.setFillColor(rgb(0xFFFFFF, 0.9))
    context.fillEllipse(in: circle(CGPoint(x: center.x + glass * 0.5, y: center.y - glass * 0.5), 11))

    // Bevel on the ring's upper left.
    context.setStrokeColor(rgb(0xFFFFFF, 0.22))
    context.setLineWidth(3)
    context.addArc(center: center, radius: outer - 3, startAngle: .pi * 0.55, endAngle: .pi * 1.05, clockwise: false)
    context.strokePath()

    guard let image = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        guard let data = render(points * scale) else { fatalError("Could not render \(name)") }
        try data.write(to: output.appendingPathComponent(name))
    }
}
print("Wrote \(output.path)")
