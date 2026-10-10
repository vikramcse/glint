import CryptoKit
import Foundation
import Testing

@testable import GlintEmbedding

/// Serves fixed bodies by path, honouring `Range: bytes=N-`, and counts requests.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodies: [String: Data] = [:]
    nonisolated(unsafe) static var requests: [String] = []
    nonisolated(unsafe) static var ignoreRanges = false
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "models.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let (body, range) = Self.lock.withLock { () -> (Data?, String?) in
            Self.requests.append(url.lastPathComponent + (request.value(forHTTPHeaderField: "Range").map { " \($0)" } ?? ""))
            return (Self.bodies[url.lastPathComponent], Self.ignoreRanges ? nil : request.value(forHTTPHeaderField: "Range"))
        }
        guard let body else {
            respond(url, status: 404)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var status = 200
        var payload = body
        if let range, let start = Int(range.dropFirst("bytes=".count).dropLast()) {
            status = 206
            payload = body.subdata(in: start..<body.count)
        }
        respond(url, status: status)
        // Deliver in a few chunks like a real connection.
        var offset = 0
        while offset < payload.count {
            let end = min(offset + 4_096, payload.count)
            client?.urlProtocol(self, didLoad: payload.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func respond(_ url: URL, status: Int) {
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
    }

    override func stopLoading() {}
}

@Suite("ModelStore", .serialized)
struct ModelStoreTests {
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func makeStore() throws -> (ModelStore, ModelArtifact, URL) {
        let base = try #require(URL(string: "https://models.test/repo"))
        let weights = Data((0..<50_000).map { UInt8($0 % 251) })
        let config = Data("{\"text_config\":{}}".utf8)
        StubProtocol.bodies = ["model.safetensors": weights, "config.json": config]
        StubProtocol.requests = []
        StubProtocol.ignoreRanges = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
        let artifact = ModelArtifact(
            id: "test-model", displayName: "Test", baseURL: base,
            files: [
                .init(path: "config.json", size: Int64(config.count), sha256: Self.sha(config)),
                .init(path: "model.safetensors", size: Int64(weights.count), sha256: Self.sha(weights)),
            ])
        return (ModelStore(directory: directory, session: URLSession(configuration: configuration)), artifact, directory)
    }

    @Test func installsAndVerifies() async throws {
        let (store, artifact, _) = try makeStore()
        #expect(await store.state(of: artifact) == .notInstalled)
        let folder = try await store.install(artifact)
        #expect(try Data(contentsOf: folder.appendingPathComponent("model.safetensors")) == StubProtocol.bodies["model.safetensors"])
        #expect(await store.state(of: artifact) == .installed(folder))

        // A second install is a no-op.
        StubProtocol.requests = []
        _ = try await store.install(artifact)
        #expect(StubProtocol.requests.isEmpty)
    }

    @Test func resumesPartialDownloadsWithRanges() async throws {
        let (store, artifact, directory) = try makeStore()
        let folder = directory.appendingPathComponent(artifact.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let weights = try #require(StubProtocol.bodies["model.safetensors"])
        try weights.prefix(20_000).write(to: folder.appendingPathComponent("model.safetensors.partial"))

        _ = try await store.install(artifact)
        #expect(StubProtocol.requests.contains("model.safetensors bytes=20000-"))
        #expect(try Data(contentsOf: folder.appendingPathComponent("model.safetensors")) == weights)
    }

    @Test func restartsWhenServerIgnoresRange() async throws {
        let (store, artifact, directory) = try makeStore()
        StubProtocol.ignoreRanges = true
        let folder = directory.appendingPathComponent(artifact.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 1_000).write(to: folder.appendingPathComponent("model.safetensors.partial"))
        _ = try await store.install(artifact)
        #expect(try Data(contentsOf: folder.appendingPathComponent("model.safetensors")) == StubProtocol.bodies["model.safetensors"])
    }

    @Test func rejectsCorruptDownloads() async throws {
        let (store, artifact, directory) = try makeStore()
        StubProtocol.bodies["model.safetensors"] = Data(repeating: 1, count: 50_000)
        await #expect(throws: ModelStoreError.checksumMismatch("model.safetensors")) {
            _ = try await store.install(artifact)
        }
        let folder = directory.appendingPathComponent(artifact.id)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.safetensors").path))
        #expect(await store.state(of: artifact) != .installed(folder))
    }

    @Test func removeDeletesEverything() async throws {
        let (store, artifact, directory) = try makeStore()
        _ = try await store.install(artifact)
        try await store.remove(artifact)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(artifact.id).path))
        #expect(await store.state(of: artifact) == .notInstalled)
    }

    @Test func pinnedArtifactDescribesTheCheckpoint() {
        let artifact = ModelArtifact.embeddingGemma2()
        #expect(artifact.files.map(\.path).contains("model.safetensors"))
        #expect(artifact.totalBytes > 1_400_000_000)
        #expect(artifact.baseURL.absoluteString.contains("1a4ffddb7905d3f63486748deabe091a01fb6201"))
    }
}
