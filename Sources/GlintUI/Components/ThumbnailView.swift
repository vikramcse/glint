import AppKit
import GlintCore
import SwiftUI

/// Decoded thumbnails shared by every list, so scrolling never decodes twice.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()

    init() {
        cache.countLimit = 600
    }

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return NSImage(data: data)
        }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

/// A precomputed thumbnail, or the file's Finder icon when there is none.
struct ThumbnailView: View {
    let url: URL?
    let filePath: String
    let kind: MediaKind
    var cornerRadius: CGFloat = 6
    var contentMode: ContentMode = .fill

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: filePath))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { return }
            if let cached = ThumbnailCache.shared.cached(url) {
                image = cached
            } else {
                image = await ThumbnailCache.shared.load(url)
            }
        }
    }
}
