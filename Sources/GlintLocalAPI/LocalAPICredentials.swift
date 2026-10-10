import Foundation
import Security

/// What a running server publishes for local clients such as `glint-mcp`.
public struct LocalAPIDiscovery: Codable, Sendable, Hashable {
    public var version: Int
    public var port: UInt16
    public var token: String
    public var pid: Int32

    public init(port: UInt16, token: String, pid: Int32 = ProcessInfo.processInfo.processIdentifier, version: Int = 1) {
        self.version = version
        self.port = port
        self.token = token
        self.pid = pid
    }
}

/// The bearer token and the discovery file, both owner-only (0600).
public enum LocalAPICredentials {
    /// Returns the persistent token at `url`, creating a random 256-bit one on first use.
    public static func loadOrCreateToken(at url: URL) throws -> String {
        if let data = try? Data(contentsOf: url),
            let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), token.count >= 32
        {
            return token
        }
        let token = try makeToken()
        try writePrivate(Data(token.utf8), to: url)
        return token
    }

    /// Replaces the token (for example from a "Reset access" button); clients must re-read discovery.
    public static func rotateToken(at url: URL) throws -> String {
        let token = try makeToken()
        try writePrivate(Data(token.utf8), to: url)
        return token
    }

    public static func writeDiscovery(_ discovery: LocalAPIDiscovery, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try writePrivate(try encoder.encode(discovery), to: url)
    }

    public static func removeDiscovery(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Creates the file with 0600 before writing contents, so the secret is never world-readable.
    static func writePrivate(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.write(contentsOf: data)
        try handle.close()
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
