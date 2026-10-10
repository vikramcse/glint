import CoreGraphics
import Foundation
import GlintCore
import ImageIO
import UniformTypeIdentifiers

/// Precomputed display images (photo thumbnails, PDF pages, video keyframes), keyed by content
/// hash so copies and moves share one file. The results view only ever reads these.
public struct ThumbnailStore: Sendable {
    public let directory: URL
    /// Longest side of stored thumbnails in pixels (2x a 200 pt cell).
    public let maxPixelSize: Int

    public init(directory: URL, maxPixelSize: Int = 400) {
        self.directory = directory
        self.maxPixelSize = maxPixelSize
    }

    /// Relative path for a thumbnail; stored in `chunks.thumb`.
    public func relativePath(contentHash: String, key: String) -> String {
        let safeKey = key.replacingOccurrences(of: "/", with: "_")
        return "\(contentHash.prefix(2))/\(contentHash)-\(safeKey).jpg"
    }

    public func url(forRelativePath path: String) -> URL {
        directory.appendingPathComponent(path)
    }

    /// Downscales and writes `image` as JPEG. Returns the relative path.
    @discardableResult
    public func save(_ image: CGImage, contentHash: String, key: String) throws -> String {
        let path = relativePath(contentHash: contentHash, key: key)
        let url = url(forRelativePath: path)
        if FileManager.default.fileExists(atPath: url.path) { return path }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let scaled = downscaled(image) ?? image
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return path
    }

    /// Loads a stored thumbnail.
    public func image(atRelativePath path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url(forRelativePath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Deletes stored thumbnails by relative path; missing files are ignored.
    public func delete(relativePaths: [String]) {
        for path in relativePaths { try? FileManager.default.removeItem(at: url(forRelativePath: path)) }
    }

    public func deleteAll() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Total bytes used, for Settings > Models.
    public func diskUsage() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private func downscaled(_ image: CGImage) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxPixelSize else { return nil }
        let scale = Double(maxPixelSize) / Double(longest)
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
