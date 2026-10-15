import Foundation
import GlintCore
import Observation

/// People found in photos and videos; implemented by the app on top of the index store.
public protocol PeopleProviding: Sendable {
    func people() async -> [PersonSummary]
    /// Names a person; naming them like someone else merges the two. Returns who holds the faces now.
    func rename(_ person: PersonID, to name: String?) async throws -> PersonID
    /// Whether photos and videos indexed before Glint looked for faces still need a rescan.
    func needsRescan() async -> Bool
    func rescan() async throws
}

/// State of the People view.
@MainActor
@Observable
public final class PeopleModel {
    public private(set) var people: [PersonSummary] = []
    public private(set) var needsRescan = false
    public private(set) var hasLoaded = false
    @ObservationIgnored private let provider: any PeopleProviding

    public init(provider: any PeopleProviding) {
        self.provider = provider
    }

    public func load() async {
        let people = await provider.people()
        let needsRescan = await provider.needsRescan()
        self.people = people
        self.needsRescan = needsRescan
        hasLoaded = true
    }

    public func person(_ id: PersonID) -> PersonSummary? {
        people.first { $0.id == id }
    }

    /// Renames and reloads; returns the person to show (another one after a merge).
    public func rename(_ id: PersonID, to name: String) async throws -> PersonID {
        let result = try await provider.rename(id, to: name)
        await load()
        return result
    }

    public func rescan() async throws {
        try await provider.rescan()
        needsRescan = false
    }
}
