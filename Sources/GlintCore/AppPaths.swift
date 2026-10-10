import Foundation

/// Where Glint keeps everything it derives. "Delete index" removes `root` entirely.
public struct AppPaths: Sendable, Hashable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// `~/Library/Application Support/Glint`.
    public static func standard() throws -> AppPaths {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return AppPaths(root: support.appendingPathComponent("Glint", isDirectory: true))
    }

    public var database: URL { root.appendingPathComponent("index.sqlite") }
    public var thumbnails: URL { root.appendingPathComponent("Thumbnails", isDirectory: true) }
    public var models: URL { root.appendingPathComponent("Models", isDirectory: true) }
    public var telemetryQueue: URL { root.appendingPathComponent("telemetry-queue.json") }
    public var diagnostics: URL { root.appendingPathComponent("Diagnostics", isDirectory: true) }
    /// Port and bearer token of the local API while it runs (owner-only permissions).
    /// `glint-mcp` and other local clients read this to find the app.
    public var apiDiscovery: URL { root.appendingPathComponent("api.json") }
    /// The local API's persistent bearer token (owner-only permissions).
    public var apiToken: URL { root.appendingPathComponent("api-token") }

    public func createDirectories() throws {
        for directory in [root, thumbnails, models, diagnostics] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
