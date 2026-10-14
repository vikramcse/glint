import Foundation
import GlintCore
import GlintSearch
import GlintStore
import GlintTestSupport

@testable import GlintLocalAPI

/// Maps a few queries to fixed directions so semantic results are deterministic.
struct FakeEncoder: QueryEncoding {
    let space: VectorSpace

    func encode(query: String) async throws -> Embedding {
        var values = [Float](repeating: 0, count: space.dimension)
        values[query.contains("beach") ? 0 : (query.contains("deadline") ? 2 : space.dimension - 1)] = 1
        return Embedding(normalizing: values, space: space)
    }
}

actor FakeIndexing: IndexingService {
    var status = IndexStatus(phase: .indexing, indexed: [.image: 1, .audio: 1, .pdf: 1], pending: 4, sourceCount: 1)
    var folders: [SourceInfo] = []

    func setSources(_ sources: [SourceInfo]) { folders = sources }
    func statusUpdates() async -> AsyncStream<IndexStatus> { AsyncStream { $0.finish() } }
    func currentStatus() async -> IndexStatus { status }
    func sources() async throws -> [SourceInfo] { folders }
    func addSource(_ url: URL) async throws -> SourceInfo { throw CocoaError(.featureUnsupported) }
    func removeSource(_ id: SourceID) async throws {}
    func reindexSource(_ id: SourceID) async throws {}
    func setExclusions(_ rules: ExclusionRules) async throws {}
    func exclusions() async -> ExclusionRules { .default }
    func pause() async {}
    func resume() async {}
    func deleteIndex() async throws {}
}

/// A small real index: files on disk under a temp folder, committed with fixed vectors.
struct APIHarness {
    let router: LocalAPIRouter
    let library: URL
    let directory: TemporaryDirectory
    static let token = String(repeating: "ab", count: 32)
    static let port: UInt16 = 4_242

    static func make() async throws -> APIHarness {
        let directory = try TemporaryDirectory(prefix: "glint-api")
        let library = try directory.subdirectory("Library")
        let url = directory.url.appendingPathComponent("index.sqlite")
        let space = VectorSpace(modelID: "fake/1", dimension: 8)
        let writer = try IndexWriter(url: url)
        let source = try await writer.addSource(path: library.path, bookmark: nil)

        let corpus: [(String, MediaKind, String?, Int, ChunkLocator)] = [
            ("beach.jpg", .image, nil, 0, .whole),
            ("Acme pitch.pdf", .pdf, "Pricing chart showing revenue by region", 1, .page(2)),
            ("standup.m4a", .audio, "the client mentioned the deadline is friday", 2, .time(start: 724, end: 734)),
            ("sunset.jpg", .image, nil, 0, .whole),
        ]
        for entry in corpus { try Data("x\(entry.0)".utf8).write(to: library.appendingPathComponent(entry.0)) }
        _ = try await writer.reconcile(
            sourceID: source,
            scanned: corpus.map { name, kind, _, _, _ in
                ScannedFile(
                    path: library.appendingPathComponent(name).path, kind: kind, contentType: .data, size: 1,
                    modified: Date(timeIntervalSince1970: 1_700_000_000))
            })
        for record in try await writer.claimPending(limit: 10, kinds: Set(MediaKind.allCases)) {
            guard let entry = corpus.first(where: { $0.0 == record.name }) else { continue }
            var vector = [Float](repeating: 0, count: 8)
            vector[entry.3] = 1
            if entry.0 == "sunset.jpg" { vector[1] = 0.3 }
            _ = try await writer.commit(
                fileID: record.id, contentHash: record.name, space: space,
                chunks: [ChunkWrite(ordinal: 0, locator: entry.4, text: entry.2, thumbnail: nil, vector: vector)])
        }

        let engine = SearchEngine(
            reader: try IndexReader(url: url),
            vectorIndex: FlatVectorIndex(space: space, useGPU: false),
            encoder: FakeEncoder(space: space),
            thumbnails: ThumbnailStore(directory: try directory.subdirectory("Thumbnails"))
        )
        try await engine.loadVectors()
        let indexing = FakeIndexing()
        await indexing.setSources([
            SourceInfo(
                id: source, path: library.path, isExternalVolume: false, isAccessible: true, itemCount: 6,
                indexed: 4, pending: 2)
        ])
        let router = LocalAPIRouter(engine: engine, indexing: indexing, token: token)
        return APIHarness(router: router, library: library, directory: directory)
    }

    static func request(
        _ method: String, _ path: String, body: String? = nil, token: String? = APIHarness.token,
        host: String = "127.0.0.1:\(APIHarness.port)", extraHeaders: [String: String] = [:]
    ) -> HTTPRequest {
        var headers = extraHeaders
        headers["Host"] = host
        if let token { headers["Authorization"] = "Bearer \(token)" }
        if body != nil { headers["Content-Type"] = "application/json" }
        return HTTPRequest(method: method, path: path, headers: headers, body: Data((body ?? "").utf8))
    }

    func send(_ request: HTTPRequest) async -> HTTPResponse {
        await router.handle(request, port: Self.port)
    }
}

extension HTTPResponse {
    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }

    var errorCode: String? {
        (json["error"] as? [String: Any])?["code"] as? String
    }

    var results: [[String: Any]] {
        json["results"] as? [[String: Any]] ?? []
    }
}
