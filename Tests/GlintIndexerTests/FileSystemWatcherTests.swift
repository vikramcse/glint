import Foundation
import Testing

@testable import GlintIndexer

@Suite("FileSystemWatcher")
struct FileSystemWatcherTests {
    @Test func reportsCreatedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let watcher = FileSystemWatcher()
        watcher.watch([directory.path], latency: 0.05)
        try await Task.sleep(for: .milliseconds(200))
        try Data("x".utf8).write(to: directory.appendingPathComponent("new.txt"))

        let received = await withTaskGroup(of: Set<String>?.self) { group in
            group.addTask {
                for await change in watcher.changes {
                    let names = Set(change.paths.map { URL(fileURLWithPath: $0).lastPathComponent })
                    if names.contains("new.txt") { return names }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        watcher.stop()
        #expect(received?.contains("new.txt") == true)
    }
}
