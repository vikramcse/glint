import Foundation
import GlintCore
import GlintSearch
import Testing

@testable import GlintUI

/// Records sources; fails for paths containing "denied".
private actor FakeIndexing: IndexingService {
    var added: [URL] = []

    func statusUpdates() async -> AsyncStream<IndexStatus> { AsyncStream { $0.finish() } }
    func currentStatus() async -> IndexStatus { IndexStatus(sourceCount: added.count) }
    func sources() async throws -> [SourceInfo] {
        added.enumerated().map {
            SourceInfo(id: SourceID(Int64($0.offset)), path: $0.element.path, isExternalVolume: false, isAccessible: true, itemCount: 0)
        }
    }
    func addSource(_ url: URL) async throws -> SourceInfo {
        if url.path.contains("denied") { throw CocoaError(.fileReadNoPermission) }
        added.append(url)
        return SourceInfo(id: SourceID(Int64(added.count)), path: url.path, isExternalVolume: false, isAccessible: true, itemCount: 0)
    }
    func removeSource(_ id: SourceID) async throws {}
    func reindexSource(_ id: SourceID) async throws {}
    func setExclusions(_ rules: ExclusionRules) async throws {}
    func exclusions() async -> ExclusionRules { .default }
    func pause() async {}
    func resume() async {}
    func deleteIndex() async throws {}
}

@MainActor
private final class FakeActions: ResultActions {
    var folders: [URL] = []
    var pickerShown = 0
    var errors: [String] = []

    func chooseFolders(message: String, allowsMultipleSelection: Bool) -> [URL] {
        pickerShown += 1
        return folders
    }
    func presentError(_ message: String) { errors.append(message) }
    func open(_ result: SearchResult) {}
    func revealInFinder(_ results: [SearchResult]) {}
    func quickLook(_ results: [SearchResult], selected: SearchResult?) {}
    func copy(_ results: [SearchResult]) {}
    func dismissPanel() {}
    func showMainWindow() {}
    func openFullDiskAccessSettings() {}
}

@MainActor
@Suite("Adding folders")
struct SourceAdderTests {
    private func makeServices(_ indexing: FakeIndexing, actions: FakeActions) async throws -> (GlintServices, Any) {
        let (engine, directory) = try await makeEngine()
        let suite = "glint-adder-\(UUID().uuidString)"
        let services = GlintServices(
            engine: engine, indexing: indexing,
            settings: AppSettings(defaults: UserDefaults(suiteName: suite) ?? .standard),
            modelDescription: ModelDescription(options: []),
            storageUsage: { 0 }
        )
        services.actions = actions
        return (services, directory)
    }

    @Test func pickerSelectionBecomesSources() async throws {
        let indexing = FakeIndexing()
        let actions = FakeActions()
        actions.folders = [URL(fileURLWithPath: "/Users/a/Desktop"), URL(fileURLWithPath: "/Users/a/Footage")]
        let (services, keep) = try await makeServices(indexing, actions: actions)
        _ = keep
        let message = await SourceAdder.pickAndAdd(services: services)
        #expect(message == nil)
        #expect(actions.pickerShown == 1)
        #expect(await indexing.added.map(\.lastPathComponent) == ["Desktop", "Footage"])
        #expect(services.status.sources.count == 2)
    }

    @Test func cancellingThePickerAddsNothing() async throws {
        let indexing = FakeIndexing()
        let actions = FakeActions()
        let (services, keep) = try await makeServices(indexing, actions: actions)
        _ = keep
        #expect(await SourceAdder.pickAndAdd(services: services) == nil)
        #expect(await indexing.added.isEmpty)
    }

    @Test func permissionFailuresAreReportedPerFolder() async throws {
        let indexing = FakeIndexing()
        let actions = FakeActions()
        let (services, keep) = try await makeServices(indexing, actions: actions)
        _ = keep
        let message = await SourceAdder.add(
            [URL(fileURLWithPath: "/Users/a/denied-docs"), URL(fileURLWithPath: "/Users/a/Pictures")], services: services)
        #expect(message?.contains("denied-docs") == true)
        #expect(message?.contains("permission") == true)
        #expect(await indexing.added.map(\.lastPathComponent) == ["Pictures"])
    }
}
