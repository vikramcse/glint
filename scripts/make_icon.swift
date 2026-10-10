// Renders the Glint app icon into an .iconset folder: a deep indigo-to-teal squircle with
// a magnifying glass and a four-point glint. Run: swift scripts/make_icon.swift <out.iconset>
import AppKit
import CoreGraphics

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data? {
    let size = CGFloat(pixels)
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // macOS icon grid: 824/1024 body with soft shadow.
    let inset = size * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = body.width * 0.225
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.025, color: CGColor(gray: 0, alpha: 0.35))
    context.addPath(path)
    context.setFillColor(CGColor(red: 0.12, green: 0.1, blue: 0.35, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.clip()
    let colors = [
        CGColor(red: 0.16, green: 0.11, blue: 0.45, alpha: 1),
        CGColor(red: 0.20, green: 0.33, blue: 0.80, alpha: 1),
        CGColor(red: 0.18, green: 0.72, blue: 0.80, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1]) {
        context.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.maxX, y: body.maxY), options: [])
    }
    // Soft top highlight.
    context.setFillColor(CGColor(gray: 1, alpha: 0.08))
    context.fillEllipse(in: CGRect(x: body.minX - body.width * 0.2, y: body.midY, width: body.width * 1.4, height: body.height))
    context.restoreGState()

    // Magnifying glass.
    let lensCenter = CGPoint(x: body.midX - body.width * 0.06, y: body.midY + body.height * 0.05)
    let lensRadius = body.width * 0.24
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
    context.setLineWidth(body.width * 0.07)
    context.strokeEllipse(in: CGRect(x: lensCenter.x - lensRadius, y: lensCenter.y - lensRadius, width: lensRadius * 2, height: lensRadius * 2))
    context.setLineCap(.round)
    context.setLineWidth(body.width * 0.095)
    let handleStart = CGPoint(x: lensCenter.x + lensRadius * 0.74, y: lensCenter.y - lensRadius * 0.74)
    context.move(to: handleStart)
    context.addLine(to: CGPoint(x: handleStart.x + body.width * 0.17, y: handleStart.y - body.width * 0.17))
    context.strokePath()

    // Four-point glint inside the lens.
    func glint(at center: CGPoint, radius: CGFloat, alpha: CGFloat) {
        let waist = radius * 0.22
        context.setFillColor(CGColor(red: 1, green: 0.95, blue: 0.75, alpha: alpha))
        context.move(to: CGPoint(x: center.x, y: center.y + radius))
        context.addQuadCurve(to: CGPoint(x: center.x + radius, y: center.y), control: CGPoint(x: center.x + waist, y: center.y + waist))
        context.addQuadCurve(to: CGPoint(x: center.x, y: center.y - radius), control: CGPoint(x: center.x + waist, y: center.y - waist))
        context.addQuadCurve(to: CGPoint(x: center.x - radius, y: center.y), control: CGPoint(x: center.x - waist, y: center.y - waist))
        context.addQuadCurve(to: CGPoint(x: center.x, y: center.y + radius), control: CGPoint(x: center.x - waist, y: center.y + waist))
        context.fillPath()
    }
    glint(at: CGPoint(x: lensCenter.x + lensRadius * 0.08, y: lensCenter.y + lensRadius * 0.1), radius: lensRadius * 0.62, alpha: 1)
    glint(at: CGPoint(x: lensCenter.x - lensRadius * 0.45, y: lensCenter.y - lensRadius * 0.38), radius: lensRadius * 0.2, alpha: 0.85)

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
