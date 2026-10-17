import Foundation

/// A storage service Glint can index without mounting it: files are listed over the network and
/// downloaded one at a time to be indexed, then deleted. Everything derived stays on this Mac.
public enum RemoteService: String, Sendable, Codable, CaseIterable, Hashable, Identifiable {
    /// AWS S3 and S3-compatible storage (Cloudflare R2, Backblaze B2, MinIO).
    case s3

    public var displayName: String {
        switch self {
        case .s3: String(localized: "S3 Bucket", comment: "Remote source kind")
        }
    }

    public var id: String { rawValue }
}

/// Where a remote source lives. Stored in the index; secrets never are (see `credentialID`).
public struct RemoteSourceConfig: Sendable, Codable, Hashable {
    public var service: RemoteService
    /// The endpoint, such as `https://s3.us-east-1.amazonaws.com` or an R2 account endpoint.
    public var endpoint: String?
    /// The signing region (`auto` for R2).
    public var region: String?
    public var bucket: String?
    /// The key prefix, `""` for the whole bucket.
    public var folder: String
    /// The access key id. Its secret key is in the Keychain.
    public var accessKeyID: String?
    /// Path-style addressing (`endpoint/bucket/key`), which MinIO and some others need.
    public var pathStyle: Bool
    /// The Keychain item holding the secret access key.
    public var credentialID: String

    public init(
        service: RemoteService, endpoint: String? = nil, region: String? = nil, bucket: String? = nil, folder: String = "",
        accessKeyID: String? = nil, pathStyle: Bool = false, credentialID: String = UUID().uuidString
    ) {
        self.service = service
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.folder = folder
        self.accessKeyID = accessKeyID
        self.pathStyle = pathStyle
        self.credentialID = credentialID
    }

    /// The source's path in the index; every file of the source is `rootPath + "/" + key`.
    public var rootPath: String {
        switch service {
        case .s3:
            let host = endpoint.flatMap { URL(string: $0)?.host() } ?? "s3"
            return RemotePath.join("s3://\(host)/\(bucket ?? "")", RemotePath.trimmed(folder))
        }
    }

    /// Name shown for the source: the folder's last component, or the bucket or service.
    public var displayName: String {
        let folderName = RemotePath.trimmed(folder).split(separator: "/").last.map(String.init)
        switch service {
        case .s3: return folderName ?? bucket ?? service.displayName
        }
    }

    /// Where the source is, for a subtitle: "S3 Bucket · media/2024 · s3.eu-west-1.amazonaws.com".
    public var locationDescription: String {
        switch service {
        case .s3:
            let place = RemotePath.join(bucket ?? "", RemotePath.trimmed(folder))
            let host = endpoint.flatMap { URL(string: $0)?.host() }
            return [service.displayName, place, host].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

/// Index paths of remote files: `<scheme>://<root>/<key>`.
public enum RemotePath {
    /// Whether `path` is a remote source or a file in one.
    public static func isRemote(_ path: String) -> Bool { service(of: path) != nil }

    public static func service(of path: String) -> RemoteService? {
        guard let separator = path.range(of: "://") else { return nil }
        return RemoteService(rawValue: String(path[..<separator.lowerBound]))
    }

    /// The key of `path` inside the source at `root`, or `nil` when it is not inside it.
    public static func key(of path: String, inRoot root: String) -> String? {
        guard path.hasPrefix(root + "/") else { return nil }
        let key = String(path.dropFirst(root.count + 1))
        return key.isEmpty ? nil : key
    }

    /// The folder a remote file is in, relative to the service: "photos/2024".
    public static func folder(of path: String) -> String {
        guard let separator = path.range(of: "://") else { return path }
        let rest = path[separator.upperBound...]
        var components = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        components.removeLast()
        return components.dropFirst().joined(separator: "/")
    }

    static func trimmed(_ folder: String) -> String {
        folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    static func join(_ base: String, _ component: String) -> String {
        component.isEmpty ? base : base + "/" + component
    }
}

/// A file in a remote source, as listed.
public struct RemoteObject: Sendable, Hashable {
    /// Unique within the source; the index path is `rootPath + "/" + key`.
    public var key: String
    public var size: Int64
    public var modified: Date

    public init(key: String, size: Int64, modified: Date) {
        self.key = key
        self.size = size
        self.modified = modified
    }

    public var name: String { key.split(separator: "/").last.map(String.init) ?? key }
}

/// Why a remote call failed. `unreachable` and `unauthorized` take the source offline instead of
/// failing or deleting its files.
public enum RemoteStorageError: GlintError, Equatable {
    /// No network, a timeout, or the service is down.
    case unreachable(String)
    /// The key was rejected, or its access to the bucket was revoked.
    case unauthorized(String)
    /// The bucket or object does not exist.
    case notFound(String)
    /// Settings are missing or invalid (no secret in the Keychain, a malformed endpoint).
    case misconfigured(String)
    /// Any other error the service reported.
    case service(status: Int, message: String)

    public var category: ErrorCategory {
        switch self {
        case .unreachable: .network
        case .unauthorized: .permissionDenied
        case .notFound: .notFound
        case .misconfigured, .service: .internal
        }
    }

    /// The source cannot be used right now, but its files are probably still there.
    public var takesSourceOffline: Bool {
        switch self {
        case .unreachable, .unauthorized: true
        case .notFound, .misconfigured, .service: false
        }
    }

    public var description: String {
        switch self {
        case .unreachable(let message): "Can’t reach the service: \(message)"
        case .unauthorized(let message): "Access was denied: \(message)"
        case .notFound(let message): "Not found: \(message)"
        case .misconfigured(let message): message
        case .service(let status, let message): "The service returned \(status): \(message)"
        }
    }
}

/// One remote source's files.
public protocol RemoteStorage: Sendable {
    /// Checks access and returns the config to store.
    func connect() async throws -> RemoteSourceConfig
    /// Every file under the source. Folders are not listed.
    func list() async throws -> [RemoteObject]
    /// Downloads one file into `directory` and returns its local URL.
    func download(key: String, to directory: URL) async throws -> URL
}

/// Makes `RemoteStorage` for a source and keeps its secrets. Lives in the app (`GlintRemote`);
/// the indexer only sees this protocol.
public protocol RemoteStorageResolving: Sendable {
    /// Storage for `config`. When `secret` is given it is used instead of the Keychain item, so
    /// a source can be tested before it is saved.
    func storage(for config: RemoteSourceConfig, secret: String?) throws -> any RemoteStorage
    /// Stores the secret access key for `credentialID`.
    func saveSecret(_ secret: String, credentialID: String) throws
    func deleteSecret(credentialID: String)
}

/// Downloads remote result files so they can be opened, previewed or copied.
public protocol RemoteFileFetching: Sendable {
    /// A local copy of the remote file at `path`, downloaded into `directory`.
    func downloadRemoteFile(path: String, to directory: URL) async throws -> URL
}
