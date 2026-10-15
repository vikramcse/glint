import CoreGraphics
import Foundation
import GlintCore
import Testing

@testable import GlintStore

private func makeDatabaseURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glint-people-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("index.sqlite")
}

private let space = VectorSpace(modelID: "test/1", dimension: 4)

/// A unit vector near axis `person`, nudged by `jitter` along the next axis, so faces of one
/// person are close (cosine ~0.98) and different people are orthogonal.
private func face(_ person: Int, jitter: Float = 0, box: CGRect = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.2)) -> FaceWrite {
    var print = [Float](repeating: 0, count: 8)
    print[person] = 1
    print[(person + 1) % 8] = jitter
    let norm = print.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return FaceWrite(box: box, quality: 0.8, print: print.map { $0 / norm }, thumbnail: "t/\(person)-\(jitter).jpg")
}

@Suite("FaceClusters")
struct FaceClustersTests {
    @Test func groupsCloseFacesAndSeparatesOthers() {
        var clusters = FaceClusters()
        let a1 = clusters.assign(face(0).print)
        let a2 = clusters.assign(face(0, jitter: 0.2).print)
        let b = clusters.assign(face(3).print)
        #expect(a1 == a2)
        #expect(a1 != b)
    }

    @Test func neverMergesTwoNamedPeople() {
        var clusters = FaceClusters()
        let first = clusters.seed(person: PersonID(1), isNamed: true, print: face(0).print)
        let second = clusters.seed(person: PersonID(2), isNamed: true, print: face(0, jitter: 0.1).print)
        let merges = clusters.mergeClose([first, second])
        #expect(merges.isEmpty)
    }

    @Test func newGroupAbsorbingAStoredPersonKeepsTheirID() {
        var clusters = FaceClusters()
        let stored = clusters.seed(person: PersonID(7), isNamed: false, print: face(0).print)
        // Force a split, then let the merge pass join them.
        clusters.joinThreshold = 1.01
        var touched: Set<Int> = []
        for jitter in [Float(0.1), 0.15, 0.2] { touched.insert(clusters.assign(face(0, jitter: jitter).print)) }
        clusters.mergeClose(touched)
        let root = clusters.resolve(stored)
        #expect(clusters.groups[root].person == PersonID(7))
        #expect(clusters.groups[root].count == 4)
    }
}

@Suite("People")
struct PeopleStoreTests {
    /// Adds `count` photos and returns their ids, claimed and ready to commit.
    private func photos(_ writer: IndexWriter, count: Int, folder: String = "/s") async throws -> [FileID] {
        let source = try await writer.addSource(path: folder, bookmark: nil)
        let files = (0..<count).map {
            ScannedFile(
                path: "\(folder)/\($0).jpg", kind: .image, contentType: .jpeg, size: Int64(10 + $0),
                modified: Date(timeIntervalSince1970: 1_000 + Double($0)))
        }
        _ = try await writer.reconcile(sourceID: source, scanned: files)
        return try await writer.claimPending(limit: count, kinds: [.image]).map(\.id).sorted()
    }

    private func commit(_ writer: IndexWriter, _ file: FileID, faces: [FaceWrite], hash: String? = nil) async throws {
        _ = try await writer.commit(
            fileID: file, contentHash: hash ?? "h\(file.rawValue)", space: space,
            chunks: [ChunkWrite(ordinal: 0, locator: .whole, text: nil, thumbnail: nil, vector: [1, 0, 0, 0], faces: faces)])
    }

    @Test func groupsFacesIntoPeopleSeenInSeveralFiles() async throws {
        let url = try makeDatabaseURL()
        let writer = try IndexWriter(url: url)
        let reader = try IndexReader(url: url)
        let files = try await photos(writer, count: 4)
        try await commit(writer, files[0], faces: [face(0), face(3)])
        try await commit(writer, files[1], faces: [face(0, jitter: 0.2)])
        try await commit(writer, files[2], faces: [face(0, jitter: 0.1), face(3, jitter: 0.1)])
        try await commit(writer, files[3], faces: [face(5)])

        #expect(try await writer.clusterFaces() == 6)
        let people = try await reader.people(minimumFiles: 2)
        #expect(people.map(\.fileCount) == [3, 2])
        #expect(people.allSatisfy { $0.faceThumbnail != nil })
        // The stranger seen once is grouped but not listed.
        #expect(try await reader.people(minimumFiles: 1).count == 3)

        let first = try #require(people.first)
        let shown = try await reader.files(of: first.id)
        #expect(Set(shown.map(\.file.id)) == Set(files[0...2]))
        #expect(shown.allSatisfy { $0.chunk?.ordinal == 0 })
        // Nothing left to assign.
        #expect(try await writer.clusterFaces() == 0)
    }

    @Test func reindexingAFileKeepsItsPeopleAndNames() async throws {
        let url = try makeDatabaseURL()
        let writer = try IndexWriter(url: url)
        let reader = try IndexReader(url: url)
        let files = try await photos(writer, count: 2)
        try await commit(writer, files[0], faces: [face(0)])
        try await commit(writer, files[1], faces: [face(0, jitter: 0.1)])
        try await writer.clusterFaces()
        let person = try #require(try await reader.people(minimumFiles: 2).first)
        try await writer.renamePerson(person.id, to: "Ada")

        try await commit(writer, files[0], faces: [face(0, jitter: 0.05)])
        try await writer.clusterFaces()
        let people = try await reader.people(minimumFiles: 2)
        #expect(people.map(\.id) == [person.id])
        #expect(people.first?.name == "Ada")
    }

    @Test func namingTwoPeopleTheSameMergesThem() async throws {
        let url = try makeDatabaseURL()
        let writer = try IndexWriter(url: url)
        let reader = try IndexReader(url: url)
        let files = try await photos(writer, count: 4)
        try await commit(writer, files[0], faces: [face(0)])
        try await commit(writer, files[1], faces: [face(0)])
        try await commit(writer, files[2], faces: [face(3)])
        try await commit(writer, files[3], faces: [face(3)])
        try await writer.clusterFaces()
        let people = try await reader.people(minimumFiles: 2)
        #expect(people.count == 2)

        try await writer.renamePerson(people[0].id, to: "Grace")
        let merged = try await writer.renamePerson(people[1].id, to: " grace ")
        #expect(merged == people[0].id)
        let after = try await reader.people(minimumFiles: 2)
        #expect(after.count == 1)
        #expect(after.first?.fileCount == 4)
        #expect(after.first?.name == "Grace")
    }

    @Test func copiedFilesShareFacesAndRemovedSourcesTakeThemAlong() async throws {
        let url = try makeDatabaseURL()
        let writer = try IndexWriter(url: url)
        let reader = try IndexReader(url: url)
        let original = try await photos(writer, count: 1, folder: "/a")
        try await commit(writer, original[0], faces: [face(0)], hash: "same")
        try await writer.clusterFaces()
        let copy = try await photos(writer, count: 1, folder: "/b")
        _ = try await writer.copyIndex(from: original[0], to: copy[0], contentHash: "same", space: space)

        // Two copies of one photo are one photo of the person.
        #expect(try await reader.people(minimumFiles: 2).isEmpty)
        let person = try #require(try await reader.people(minimumFiles: 1).first)
        #expect(person.fileCount == 1)
        #expect(try await reader.files(of: person.id).map(\.file.id) == [copy[0]])

        let sources = try await writer.sources()
        let removed = try await writer.removeSource(try #require(sources.first { $0.path == "/b" }).id)
        // The original still uses the crop, so it is not orphaned.
        #expect(removed.orphanedThumbnails.isEmpty)
        #expect(try await reader.people(minimumFiles: 1).first?.fileCount == 1)

        let last = try await writer.removeSource(try #require(sources.first { $0.path == "/a" }).id)
        #expect(last.orphanedThumbnails == ["t/0-0.0.jpg"])
        #expect(try await reader.people(minimumFiles: 1).isEmpty)
    }

    @Test func upgradedLibrariesAskForAFaceRescan() async throws {
        let url = try makeDatabaseURL()
        let writer = try IndexWriter(url: url)
        #expect(try await writer.setting(IndexWriter.facesBackfillKey) == nil)
        let files = try await photos(writer, count: 2)
        try await commit(writer, files[0], faces: [])
        try await commit(writer, files[1], faces: [])
        #expect(try await writer.requeueForFaces() == 2)
        #expect(try await writer.counts().pending[.image] == 2)
    }
}
