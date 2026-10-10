import CryptoKit
import Foundation
import GlintCore

/// A downloadable model checkpoint, pinned to exact files and checksums.
public struct ModelArtifact: Sendable, Hashable, Identifiable {
    public struct File: Sendable, Hashable {
        public var path: String
        public var size: Int64
        public var sha256: String
    }

    public var id: String
    public var displayName: String
    /// Where files are fetched from: `<baseURL>/<path>`.
    public var baseURL: URL
    public var files: [File]

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// `mlx-community/embeddinggemma-2-bf16` at a pinned revision (Google source 914f7f8).
    /// Builds can point `GlintModelBaseURL` in Info.plist at our CDN mirror of the same files.
    public static func embeddingGemma2(baseURL: URL? = nil) -> ModelArtifact {
        let defaultBase = URL(
            string: "https://huggingface.co/mlx-community/embeddinggemma-2-bf16/resolve/1a4ffddb7905d3f63486748deabe091a01fb6201")
        return ModelArtifact(
            id: "embeddinggemma-2-bf16",
            displayName: "EmbeddingGemma 2",
            baseURL: baseURL ?? defaultBase ?? URL(fileURLWithPath: "/"),
            files: [
                File(path: "config.json", size: 5_258, sha256: "24bc60679eecb0a61bcf9f5ecf7b01bbd9603b8e47aa469fe9f0569e17c55ed9"),
                File(
                    path: "tokenizer_config.json", size: 1_599, sha256: "17bd5d6e9364ca49a534e1502076593317c298d4a663623091ed45388f004874"),
                File(path: "tokenizer.json", size: 32_170_510, sha256: "4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4"),
                File(
                    path: "model.safetensors", size: 1_488_914_930,
                    sha256: "ffaf2604b011ad0634022529bac930a4f6a2feba22687d8d5890434d186b459c"),
            ]
        )
    }
}

/// Where a model stands on this Mac.
public enum ModelInstallState: Sendable, Hashable {
    case notInstalled
    case downloading(received: Int64, total: Int64)
    case verifying
    case installed(URL)
    case failed(String)

    public var fraction: Double? {
        if case .downloading(let received, let total) = self, total > 0 { return Double(received) / Double(total) }
        return nil
    }
}

public enum ModelStoreError: GlintError, Equatable {
    case checksumMismatch(String)
    case http(Int)
    case cancelled

    public var category: ErrorCategory {
        switch self {
        case .checksumMismatch: .corrupt
        case .http: .network
        case .cancelled: .cancelled
        }
    }

    public var description: String {
        switch self {
        case .checksumMismatch(let file): "Checksum mismatch for \(file)"
        case .http(let status): "Download failed (HTTP \(status))"
        case .cancelled: "Download cancelled"
        }
    }
}

/// Downloads models once, resumably, verifying every file's SHA-256 before it is used.
/// Files land in `<directory>/<artifact id>/`; partial downloads resume with HTTP ranges.
public actor ModelStore {
    public let directory: URL
    private let session: URLSession
    private var states: [String: ModelInstallState] = [:]
    private var subscribers: [UUID: AsyncStream<ModelInstallState>.Continuation] = [:]
    private var task: Task<URL, any Error>?

    public init(directory: URL, session: URLSession = .shared) {
        self.directory = directory
        self.session = session
    }

    public func location(of artifact: ModelArtifact) -> URL {
        directory.appendingPathComponent(artifact.id, isDirectory: true)
    }

    /// Installed when every file is present with its verified marker.
    public func state(of artifact: ModelArtifact) -> ModelInstallState {
        if let state = states[artifact.id], state != .notInstalled { return state }
        return isInstalled(artifact) ? .installed(location(of: artifact)) : .notInstalled
    }

    public func updates() -> AsyncStream<ModelInstallState> {
        let (stream, continuation) = AsyncStream.makeStream(of: ModelInstallState.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    /// Downloads (or resumes) and verifies the artifact. Returns its directory.
    @discardableResult
    public func install(_ artifact: ModelArtifact) async throws -> URL {
        if isInstalled(artifact) {
            publish(artifact, .installed(location(of: artifact)))
            return location(of: artifact)
        }
        if let task { return try await task.value }
        let job = Task { try await self.performInstall(artifact) }
        task = job
        defer { task = nil }
        do {
            return try await job.value
        } catch {
            publish(artifact, error is CancellationError ? .notInstalled : .failed(String(describing: error)))
            throw error
        }
    }

    public func cancel() {
        task?.cancel()
    }

    public func remove(_ artifact: ModelArtifact) throws {
        let folder = location(of: artifact)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        publish(artifact, .notInstalled)
    }

    // MARK: Internals

    private func isInstalled(_ artifact: ModelArtifact) -> Bool {
        let folder = location(of: artifact)
        return artifact.files.allSatisfy { file in
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(file.path).path)
                && (try? String(contentsOf: marker(for: file, in: folder), encoding: .utf8)) == file.sha256
        }
    }

    private func marker(for file: ModelArtifact.File, in folder: URL) -> URL {
        folder.appendingPathComponent(".\(file.path).verified")
    }

    private func performInstall(_ artifact: ModelArtifact) async throws -> URL {
        let folder = location(of: artifact)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var completed: Int64 = 0
        for file in artifact.files {
            let destination = folder.appendingPathComponent(file.path)
            if (try? String(contentsOf: marker(for: file, in: folder), encoding: .utf8)) == file.sha256,
                FileManager.default.fileExists(atPath: destination.path)
            {
                completed += file.size
                continue
            }
            try await download(file, from: artifact, to: destination, alreadyReceived: completed)
            publish(artifact, .verifying)
            let digest = try Self.sha256(of: destination.appendingPathExtension("partial"))
            guard digest == file.sha256 else {
                try? FileManager.default.removeItem(at: destination.appendingPathExtension("partial"))
                throw ModelStoreError.checksumMismatch(file.path)
            }
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: destination.appendingPathExtension("partial"), to: destination)
            try file.sha256.write(to: marker(for: file, in: folder), atomically: true, encoding: .utf8)
            completed += file.size
        }
        publish(artifact, .installed(folder))
        Log.embedding.info("Installed model \(artifact.id, privacy: .public)")
        return folder
    }

    /// Streams one file into `<destination>.partial`, resuming from its current size.
    private func download(_ file: ModelArtifact.File, from artifact: ModelArtifact, to destination: URL, alreadyReceived: Int64)
        async throws
    {
        let partial = destination.appendingPathExtension("partial")
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        var offset = Int64(try handle.seekToEnd())
        if offset >= file.size { return }

        var request = URLRequest(url: artifact.baseURL.appendingPathComponent(file.path))
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let stream = ChunkStream.start(request, configuration: session.configuration)
        var lastPublish = ContinuousClock.now
        for try await event in stream {
            switch event {
            case .response(let status):
                if status == 200, offset > 0 {
                    // The server ignored the range; start over.
                    try handle.truncate(atOffset: 0)
                    offset = 0
                } else if status != 200, status != 206 {
                    throw ModelStoreError.http(status)
                }
            case .data(let chunk):
                try Task.checkCancellation()
                try handle.write(contentsOf: chunk)
                offset += Int64(chunk.count)
                if ContinuousClock.now - lastPublish > .milliseconds(250) {
                    publish(artifact, .downloading(received: alreadyReceived + offset, total: artifact.totalBytes))
                    lastPublish = .now
                }
            }
        }
    }

    private func publish(_ artifact: ModelArtifact, _ state: ModelInstallState) {
        states[artifact.id] = state
        for continuation in subscribers.values { continuation.yield(state) }
    }

    /// Streaming SHA-256 (1 MB reads), hex encoded.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Bridges a URLSession data task to an async stream of network-sized chunks.
private final class ChunkStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case response(Int)
        case data(Data)
    }

    private let continuation: AsyncThrowingStream<Event, any Error>.Continuation

    private init(_ continuation: AsyncThrowingStream<Event, any Error>.Continuation) {
        self.continuation = continuation
    }

    static func start(_ request: URLRequest, configuration: URLSessionConfiguration) -> AsyncThrowingStream<Event, any Error> {
        AsyncThrowingStream { continuation in
            let delegate = ChunkStream(continuation)
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: request)
            continuation.onTermination = { _ in
                task.cancel()
                session.invalidateAndCancel()
            }
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        continuation.yield(.response((response as? HTTPURLResponse)?.statusCode ?? 0))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        session.finishTasksAndInvalidate()
    }
}
