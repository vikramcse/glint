import Foundation
import GlintCore

/// URLSession calls for the remote services: retries throttling and server errors with backoff,
/// and maps failures to `RemoteStorageError` so the indexer can tell "offline" from "gone".
struct RemoteHTTP: Sendable {
    let session: URLSession
    var attempts = 3
    var baseDelay: Duration = .milliseconds(500)

    /// Sends `request` (built fresh for each attempt, so signatures stay current)
    /// and returns the body of a 2xx response.
    func data(_ makeRequest: @Sendable () async throws -> URLRequest) async throws -> Data {
        try await withRetries {
            let request = try await makeRequest()
            let (data, response) = try await mapTransportErrors { try await session.data(for: request) }
            try Self.check(response, body: data)
            return data
        }
    }

    /// Downloads the body of `request` into `destination`, replacing anything there.
    func download(_ makeRequest: @Sendable () async throws -> URLRequest, to destination: URL) async throws {
        try await withRetries {
            let request = try await makeRequest()
            let (file, response) = try await mapTransportErrors { try await session.download(for: request) }
            defer { try? FileManager.default.removeItem(at: file) }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try Self.check(response, body: (try? Data(contentsOf: file)) ?? Data())
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: file, to: destination)
        }
    }

    private func withRetries<T>(_ body: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await body()
            } catch let error as RetryableError {
                guard attempt < attempts else { throw error.underlying }
                try await Task.sleep(for: error.retryAfter ?? baseDelay * (1 << (attempt - 1)))
            }
        }
    }

    private func mapTransportErrors<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            let failure = RemoteStorageError.unreachable(error.localizedDescription)
            switch error.code {
            case .timedOut, .networkConnectionLost: throw RetryableError(underlying: failure, retryAfter: nil)
            default: throw failure
            }
        }
    }

    /// Throws for anything but a 2xx response.
    static func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw RemoteStorageError.service(status: 0, message: "No HTTP response") }
        let status = http.statusCode
        guard !(200..<300).contains(status) else { return }
        let message = Self.message(from: body) ?? HTTPURLResponse.localizedString(forStatusCode: status)
        switch status {
        case 401, 403: throw RemoteStorageError.unauthorized(message)
        case 404: throw RemoteStorageError.notFound(message)
        case 429, 500...599:
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init).map { Duration.seconds(min($0, 30)) }
            // Throttled or failing after every retry: offline for now, not an error in the file.
            throw RetryableError(underlying: .unreachable("\(status) \(message)"), retryAfter: retryAfter)
        default: throw RemoteStorageError.service(status: status, message: message)
        }
    }

    /// A short message from an S3 XML error body, or the body itself.
    static func message(from body: Data) -> String? {
        guard !body.isEmpty, let text = String(data: body.prefix(2_048), encoding: .utf8) else { return nil }
        if let start = text.range(of: "<Message>"), let end = text.range(of: "</Message>", range: start.upperBound..<text.endIndex) {
            return String(text[start.upperBound..<end.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A failure worth another attempt; `underlying` is thrown once attempts run out.
private struct RetryableError: Error {
    var underlying: RemoteStorageError
    var retryAfter: Duration?
}

extension URLSession {
    /// A session for remote sources: no cookies or cache, generous timeouts for large downloads.
    static func remoteSources() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": "Glint"]
        return URLSession(configuration: configuration)
    }
}

/// Picks the local file name for a download: the remote name, made safe for the file system.
func localFileURL(for name: String, in directory: URL) -> URL {
    let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    return directory.appendingPathComponent(safe.isEmpty ? "file" : safe)
}
