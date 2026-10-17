import Foundation
import GlintCore
import Testing

@testable import GlintRemote

extension RemoteTests {
    @Suite("SigV4")
    struct SigV4Tests {
        /// The examples in the S3 API reference ("Signature Calculations for the Authorization
        /// Header: Transferring Payload in a Single Chunk").
        let signer = SigV4Signer(
            accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1")
        let date = Date(timeIntervalSince1970: 1_369_353_600)  // 2013-05-24T00:00:00Z

        @Test func getObjectExample() throws {
            var request = URLRequest(url: try #require(URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")))
            request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
            signer.sign(&request, date: date)
            #expect(
                request.value(forHTTPHeaderField: "Authorization")
                    == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
                    + "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, "
                    + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
        }

        @Test func listObjectsExample() throws {
            var request = URLRequest(url: try #require(URL(string: "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J")))
            signer.sign(&request, date: date)
            #expect(
                request.value(forHTTPHeaderField: "Authorization")?.hasSuffix(
                    "Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7") == true)
        }

        @Test func queryIsSortedByNameThenValue() {
            #expect(SigV4Signer.canonicalQuery("prefix=J&max-keys=2&a=2&a=1") == "a=1&a=2&max-keys=2&prefix=J")
            #expect(SigV4Signer.canonicalQuery(nil).isEmpty)
        }

        @Test func encodesLikeAWS() {
            #expect(SigV4Signer.encode("photos/my trip/é+1.jpg", keepSlash: true) == "photos/my%20trip/%C3%A9%2B1.jpg")
            #expect(SigV4Signer.encode("a/b") == "a%2Fb")
        }
    }
}

extension RemoteTests {
    @Suite("S3 storage")
    struct S3StorageTests {
        func storage(folder: String = "photos", pathStyle: Bool = false) throws -> S3Storage {
            let config = RemoteSourceConfig(
                service: .s3, endpoint: "https://s3.eu-west-1.amazonaws.com", region: "eu-west-1", bucket: "family", folder: folder,
                accessKeyID: "AKID", pathStyle: pathStyle)
            return try S3Storage(config: config, secretAccessKey: "secret", http: StubURLProtocol.http())
        }

        @Test func buildsVirtualHostedAndPathStyleURLs() throws {
            let virtual = try storage().objectURL(key: "photos/my trip.jpg", query: [])
            #expect(virtual.absoluteString == "https://family.s3.eu-west-1.amazonaws.com/photos/my%20trip.jpg")
            let path = try storage(pathStyle: true).objectURL(key: nil, query: [("list-type", "2"), ("prefix", "a b/")])
            #expect(path.absoluteString == "https://s3.eu-west-1.amazonaws.com/family/?list-type=2&prefix=a%20b%2F")
        }

        @Test func listsEveryPageAndStripsThePrefix() async throws {
            StubURLProtocol.serve { request in
                #expect(request.query["prefix"] == "photos/")
                #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("/eu-west-1/s3/aws4_request") == true)
                if request.query["continuation-token"] == nil {
                    return .text(
                        """
                        <ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>page2</NextContinuationToken>
                        <Contents><Key>photos/</Key><Size>0</Size><LastModified>2026-01-01T00:00:00.000Z</LastModified></Contents>
                        <Contents><Key>photos/beach.jpg</Key><Size>1200</Size><LastModified>2026-03-04T10:20:30.000Z</LastModified></Contents>
                        </ListBucketResult>
                        """)
                }
                #expect(request.query["continuation-token"] == "page2")
                return .text(
                    """
                    <ListBucketResult><IsTruncated>false</IsTruncated>
                    <Contents><Key>photos/2024/notes &amp; plans.txt</Key><Size>42</Size><LastModified>2026-03-05T00:00:00Z</LastModified></Contents>
                    </ListBucketResult>
                    """)
            }
            let objects = try await storage().list()
            #expect(objects.map(\.key) == ["beach.jpg", "2024/notes & plans.txt"])
            #expect(objects[0].size == 1_200)
            #expect(objects[0].modified == ISO8601DateFormatter().date(from: "2026-03-04T10:20:30Z"))
            #expect(StubURLProtocol.requests.count == 2)
        }

        @Test func downloadsUnderThePrefix() async throws {
            StubURLProtocol.serve { request in
                #expect(request.url?.path == "/photos/2024/notes & plans.txt")
                return .text("hello")
            }
            let directory = try temporaryDirectory()
            let file = try await storage().download(key: "2024/notes & plans.txt", to: directory)
            #expect(file.lastPathComponent == "notes & plans.txt")
            #expect(try String(contentsOf: file, encoding: .utf8) == "hello")
        }

        @Test func mapsErrors() async throws {
            StubURLProtocol.serve { _ in .text("<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>", status: 403) }
            await #expect(throws: RemoteStorageError.unauthorized("Access Denied")) { try await storage().list() }

            StubURLProtocol.serve { _ in .text("<Error><Message>The specified key does not exist.</Message></Error>", status: 404) }
            await #expect(throws: RemoteStorageError.notFound("The specified key does not exist.")) {
                try await storage().download(key: "gone.jpg", to: try temporaryDirectory())
            }

            StubURLProtocol.serve { _ in throw URLError(.notConnectedToInternet) }
            await #expect {
                try await storage().list()
            } throws: { ($0 as? RemoteStorageError)?.takesSourceOffline == true }
        }

        @Test func retriesServerErrors() async throws {
            let calls = Counter()
            StubURLProtocol.serve { _ in
                calls.increment() < 2
                    ? .text("busy", status: 503) : .text("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>")
            }
            #expect(try await storage().list().isEmpty)
            #expect(calls.value == 3)
        }

        @Test func rejectsIncompleteSettings() {
            let config = RemoteSourceConfig(service: .s3, endpoint: "not a url", bucket: "b", accessKeyID: "k")
            #expect(throws: RemoteStorageError.self) { try S3Storage(config: config, secretAccessKey: "s", http: StubURLProtocol.http()) }
        }
    }
}

/// A thread-safe counter for stub handlers. `increment` returns the value before incrementing.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            defer { count += 1 }
            return count
        }
    }

    var value: Int { lock.withLock { count } }
}

extension RemoteTests {
    @Suite("Remote storage factory")
    struct RemoteStorageFactoryTests {
        @Test func secretsComeFromTheStoreAndAreDeletedWithTheSource() throws {
            let secrets = InMemorySecretStore()
            let factory = RemoteStorageFactory(secrets: secrets, session: StubURLProtocol.session())
            let config = RemoteSourceConfig(
                service: .s3, endpoint: "https://s3.amazonaws.com", bucket: "b", accessKeyID: "k", credentialID: "cred-1")
            #expect(throws: RemoteStorageError.unauthorized("The secret key is missing from the Keychain.")) {
                try factory.storage(for: config, secret: nil)
            }
            try factory.saveSecret("s3cret", credentialID: "cred-1")
            _ = try factory.storage(for: config, secret: nil)
            factory.deleteSecret(credentialID: "cred-1")
            #expect(secrets.ids.isEmpty)
        }
    }
}
