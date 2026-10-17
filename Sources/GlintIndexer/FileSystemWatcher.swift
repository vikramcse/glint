import CoreServices
import Foundation
import GlintCore

/// A batch of changed paths reported by FSEvents.
public struct FileSystemChange: Sendable, Hashable {
    public var paths: Set<String>
    /// FSEvents dropped events or asked for a full rescan of these roots.
    public var rescanRoots: Set<String>
}

/// Wraps an FSEvents stream for a set of folders and delivers coalesced batches.
public final class FileSystemWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.glint.fsevents", qos: .utility)
    private static let queueKey = DispatchSpecificKey<Void>()
    /// What the FSEvents context points at. The callback holds the watcher only weakly, so an event
    /// that races with the last release never touches a deallocating watcher.
    private final class WeakBox: @unchecked Sendable {
        weak var watcher: FileSystemWatcher?
    }
    private let box = WeakBox()
    private var stream: FSEventStreamRef?
    private let continuation: AsyncStream<FileSystemChange>.Continuation
    /// Coalesced batches of changes.
    public let changes: AsyncStream<FileSystemChange>

    public init() {
        (changes, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        queue.setSpecific(key: Self.queueKey, value: ())
        box.watcher = self
    }

    deinit {
        // The last release can come from the FSEvents callback itself, on `queue`; a `queue.sync`
        // there would deadlock.
        onQueue { stopLocked() }
        continuation.finish()
    }

    /// Starts (or restarts) watching `paths`.
    public func watch(_ paths: [String], latency: TimeInterval) {
        onQueue {
            stopLocked()
            guard !paths.isEmpty else { return }
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: nil, release: nil, copyDescription: nil
            )
            let flags = UInt32(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagWatchRoot
            )
            // FSEvents watches real paths; `/var/…` must be given as `/private/var/…`.
            let realPaths = paths.map { path in
                guard let resolved = realpath(path, nil) else { return path }
                defer { free(resolved) }
                return String(cString: resolved)
            }
            guard
                let stream = FSEventStreamCreate(
                    kCFAllocatorDefault, Self.callback, &context, realPaths as CFArray,
                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
                )
            else {
                Log.indexer.error("Could not create FSEvents stream")
                return
            }
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            self.stream = stream
        }
    }

    public func stop() {
        onQueue { stopLocked() }
    }

    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            body()
        } else {
            queue.sync(execute: body)
        }
    }

    private func stopLocked() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func deliver(paths: [String], flags: [FSEventStreamEventFlags]) {
        var change = FileSystemChange(paths: [], rescanRoots: [])
        let rescanFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
        )
        for (path, flag) in zip(paths, flags) {
            if flag & rescanFlags != 0 {
                change.rescanRoots.insert(path)
            } else {
                change.paths.insert(path)
            }
        }
        continuation.yield(change)
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info, let watcher = Unmanaged<WeakBox>.fromOpaque(info).takeUnretainedValue().watcher else { return }
        let array = unsafeBitCast(paths, to: NSArray.self)
        let pathList = (0..<count).compactMap { array[$0] as? String }
        let flagList = (0..<count).map { flags[$0] }
        watcher.deliver(paths: pathList, flags: flagList)
    }
}
