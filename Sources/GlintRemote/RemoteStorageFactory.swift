import Foundation
import GlintCore

/// Builds the storage for each remote source and keeps their secrets in a `SecretStore`.
public struct RemoteStorageFactory: RemoteStorageResolving {
    let secrets: any SecretStore
    let http: RemoteHTTP

    public init(secrets: any SecretStore = KeychainSecretStore(), session: URLSession? = nil) {
        self.secrets = secrets
        http = RemoteHTTP(session: session ?? .remoteSources())
    }

    public func storage(for config: RemoteSourceConfig, secret: String?) throws -> any RemoteStorage {
        guard let secret = try secret ?? secrets.read(config.credentialID) else {
            throw RemoteStorageError.unauthorized("The secret key is missing from the Keychain.")
        }
        switch config.service {
        case .s3: return try S3Storage(config: config, secretAccessKey: secret, http: http)
        }
    }

    public func saveSecret(_ secret: String, credentialID: String) throws {
        try secrets.save(secret, id: credentialID)
    }

    public func deleteSecret(credentialID: String) {
        secrets.delete(credentialID)
    }
}
