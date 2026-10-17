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

    init(url: URL?, filePath: String, kind: MediaKind, cornerRadius: CGFloat = 6, contentMode: ContentMode = .fill) {
        self.url = url
        self.filePath = filePath
        self.kind = kind
        self.cornerRadius = cornerRadius
        self.contentMode = contentMode
        // A cached thumbnail shows on the first frame instead of flashing the Finder icon.
        _image = State(initialValue: url.flatMap { ThumbnailCache.shared.cached($0) })
    }

    var body: some View {
        framed
            .clipShape(.rect(cornerRadius: cornerRadius))
            // Clipping hides a filled image's overflow but not from clicks, which would land on neighbours.
            .contentShape(.rect(cornerRadius: cornerRadius))
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

    /// A filled thumbnail takes exactly the space it is offered and crops the image to it;
    /// sized by the image instead, it would spill over its neighbours.
    @ViewBuilder private var framed: some View {
        if contentMode == .fill {
            Color.clear.overlay { content }
        } else {
            content
        }
    }

    @ViewBuilder private var content: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: filePath))
                .resizable()
                .scaledToFit()
                .padding(4)
        }
    }
}
