import Foundation

/// What the indexer needs to know about the volume a source folder lives on.
public protocol VolumeProbing: Sendable {
    /// The folder can be listed now. An unplugged drive or a disconnected share cannot, and its
    /// files must be kept rather than treated as deleted.
    func isReachable(_ path: String) -> Bool
    /// The folder is on a network share (SMB, NFS, AFP). FSEvents only reports changes made on
    /// this Mac, so these sources are rescanned on a timer as well.
    func isNetworkVolume(_ path: String) -> Bool
}

/// The real file system.
public struct SystemVolumeProbe: VolumeProbing {
    public init() {}

    public func isReachable(_ path: String) -> Bool {
        FileManager.default.isReadableFile(atPath: path) && !FileScanner.isUnmountedVolume(URL(fileURLWithPath: path))
    }

    public func isNetworkVolume(_ path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey])
        return values?.volumeIsLocal == false
    }
}
