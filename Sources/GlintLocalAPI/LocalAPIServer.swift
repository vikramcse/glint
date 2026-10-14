import Foundation
import GlintCore
import Network

/// Errors starting the local API.
public enum LocalAPIError: GlintError, Equatable {
    case listenerFailed(String)

    public var category: ErrorCategory { .internal }

    public var description: String {
        switch self {
        case .listenerFailed(let reason): "The local API couldn’t start: \(reason)"
        }
    }
}

/// A loopback-only HTTP/1.1 server for the local API. One request per connection,
/// bounded request sizes, a per-connection deadline and a connection cap.
public final class LocalAPIServer: @unchecked Sendable {
    public let router: LocalAPIRouter
    public let maxConnections: Int
    public let requestTimeout: TimeInterval

    private let queue = DispatchQueue(label: "app.glint.local-api")
    // Guarded by `queue`.
    private var listener: NWListener?
    private var connections = 0
    private var boundPort: UInt16 = 0

    public init(router: LocalAPIRouter, maxConnections: Int = 32, requestTimeout: TimeInterval = 10) {
        self.router = router
        self.maxConnections = maxConnections
        self.requestTimeout = requestTimeout
    }

    /// Starts listening on 127.0.0.1. Pass 0 for an ephemeral port. Returns the bound port.
    public func start(port: UInt16 = 0) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let requested = NWEndpoint.Port(rawValue: port) else { throw LocalAPIError.listenerFailed("invalid port") }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: requested)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw LocalAPIError.listenerFailed(error.localizedDescription)
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

        let bound: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumed.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    resumed.run { continuation.resume(throwing: LocalAPIError.listenerFailed(error.localizedDescription)) }
                case .cancelled:
                    resumed.run { continuation.resume(throwing: LocalAPIError.listenerFailed("cancelled")) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        queue.sync {
            self.listener = listener
            self.boundPort = bound
        }
        Log.app.info("Local API listening on loopback port \(bound, privacy: .public)")
        return bound
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            boundPort = 0
        }
    }

    public var port: UInt16? {
        queue.sync { listener == nil ? nil : boundPort }
    }

    // MARK: Connections (on `queue`)

    private func accept(_ connection: NWConnection) {
        guard connections < maxConnections else {
            connection.cancel()
            return
        }
        connections += 1
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.connections -= 1
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + requestTimeout) { [weak connection] in connection?.cancel() }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequestParser.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            case .failure(let status):
                self.send(LocalAPIRouter.error(status, "bad_request", "The request couldn’t be read."), on: connection)
            case .complete(let request):
                let router = self.router
                let port = self.boundPort
                Task {
                    let response = await router.handle(request, port: port)
                    self.queue.async { self.send(response, on: connection) }
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Ensures a continuation is resumed exactly once from a state handler that fires repeatedly.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
