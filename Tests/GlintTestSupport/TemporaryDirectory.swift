import Foundation

/// A unique directory under the system temporary directory, removed when the value is released.
public final class TemporaryDirectory: @unchecked Sendable {
    public let url: URL

    public init(prefix: String = "glint-tests") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// URL of `name` inside the directory (not created).
    public func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    /// Creates and returns a subdirectory.
    public func subdirectory(_ name: String) throws -> URL {
        let directory = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
