import Foundation
import GlintCore
import Photos
import UniformTypeIdentifiers

/// The Apple Photos library through PhotoKit. Read-only, and never touches the network:
/// assets whose originals live only in iCloud are skipped rather than downloaded.
public final class PhotoKitLibrary: NSObject, PhotoLibraryProviding, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var isRegistered = false

    public override init() {
        super.init()
    }

    deinit {
        if isRegistered { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    }

    public func authorizationStatus() -> PhotoLibraryAuthorization {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func requestAuthorization() async -> PhotoLibraryAuthorization {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    public func localAssets() async throws -> [PhotoAssetInfo] {
        guard authorizationStatus() == .authorized else { return [] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.fetchLocalAssets())
            }
        }
    }

    public func exportOriginal(assetIdentifier: String, to directory: URL) async throws -> URL {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject,
            let resource = Self.originalResource(of: asset)
        else { throw CocoaError(.fileNoSuchFile) }
        let name = resource.originalFilename.isEmpty ? "asset" : resource.originalFilename.replacingOccurrences(of: "/", with: "-")
        let destination = directory.appendingPathComponent(name)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options)
        return destination
    }

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        lock.withLock {
            continuations[id] = continuation
            if !isRegistered {
                PHPhotoLibrary.shared().register(self)
                isRegistered = true
            }
        }
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        let current = lock.withLock { Array(continuations.values) }
        for continuation in current { continuation.yield() }
    }

    // MARK: Fetching

    private static func fetchLocalAssets() -> [PhotoAssetInfo] {
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        let assets = PHAsset.fetchAssets(with: options)
        var result: [PhotoAssetInfo] = []
        result.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            guard let resource = originalResource(of: asset), isLocallyAvailable(resource) else { return }
            let type = UTType(resource.uniformTypeIdentifier) ?? (asset.mediaType == .video ? .quickTimeMovie : .jpeg)
            result.append(
                PhotoAssetInfo(
                    identifier: asset.localIdentifier,
                    filename: resource.originalFilename,
                    kind: asset.mediaType == .video ? .video : .image,
                    contentType: type,
                    size: fileSize(resource),
                    modified: asset.modificationDate ?? asset.creationDate ?? .distantPast
                ))
        }
        return result
    }

    /// The edited version when there is one (what the user sees in Photos), else the original.
    static func originalResource(of asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] =
            asset.mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
        for type in preferred {
            if let match = resources.first(where: { $0.type == type }) { return match }
        }
        return nil
    }

    /// PhotoKit reports local availability only through key-value coding; when the key is
    /// missing the export (with network access off) is the final check.
    private static func isLocallyAvailable(_ resource: PHAssetResource) -> Bool {
        guard resource.responds(to: NSSelectorFromString("locallyAvailable")) else { return true }
        return (resource.value(forKey: "locallyAvailable") as? Bool) ?? true
    }

    private static func fileSize(_ resource: PHAssetResource) -> Int64 {
        guard resource.responds(to: NSSelectorFromString("fileSize")) else { return 0 }
        return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
    }

    private static func map(_ status: PHAuthorizationStatus) -> PhotoLibraryAuthorization {
        switch status {
        case .authorized, .limited: .authorized
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }
}
