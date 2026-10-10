import Foundation
import GlintCore

/// Records analytics events. The app uses `NoopTelemetryClient` until the user opts in.
public protocol TelemetryClient: Sendable {
    func record(_ event: TelemetryEvent) async
}

/// Discards every event. The default.
public struct NoopTelemetryClient: TelemetryClient {
    public init() {}
    public func record(_ event: TelemetryEvent) async {}
}

/// Delivers a batch of events to the analytics endpoint.
public protocol TelemetryTransport: Sendable {
    func send(_ body: Data) async throws
}

/// Posts JSON batches to an HTTPS endpoint.
public struct HTTPTelemetryTransport: TelemetryTransport {
    public let endpoint: URL
    private let session: URLSession

    public init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    public func send(_ body: Data) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}

/// One queued event: name, bucketed properties and the day it happened (no time of day).
public struct QueuedTelemetryEvent: Codable, Sendable, Hashable {
    public var name: String
    public var properties: [String: String]
    public var day: String
}

/// The exact body sent to the endpoint, also shown in Settings > Privacy.
public struct TelemetryBatch: Codable, Sendable, Hashable {
    public var anonymousID: String
    public var events: [QueuedTelemetryEvent]

    enum CodingKeys: String, CodingKey {
        case anonymousID = "anonymous_id"
        case events
    }
}

/// Queues events on disk and sends them in one batch at most once a day.
public actor QueuedTelemetryClient: TelemetryClient {
    public static let flushInterval: TimeInterval = 24 * 60 * 60
    static let lastFlushKey = "telemetry.lastFlush"

    private let queueURL: URL
    private let transport: any TelemetryTransport
    private let keyValueStore: any KeyValueStore
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    private let maxQueuedEvents: Int
    private var queue: [QueuedTelemetryEvent]

    /// - Parameters:
    ///   - random: Returns a value in `0..<1`; injected so sampling is testable.
    public init(
        queueURL: URL,
        transport: any TelemetryTransport,
        keyValueStore: any KeyValueStore,
        now: @escaping @Sendable () -> Date = { Date() },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        maxQueuedEvents: Int = 500
    ) {
        self.queueURL = queueURL
        self.transport = transport
        self.keyValueStore = keyValueStore
        self.now = now
        self.random = random
        self.maxQueuedEvents = maxQueuedEvents
        queue = Self.load(from: queueURL)
    }

    public func record(_ event: TelemetryEvent) async {
        guard random() < event.sampleRate else { return }
        let payload = event.payload
        guard TelemetrySchema.isAllowed(name: event.name, payload: payload) else {
            Log.telemetry.fault("Dropped event outside schema: \(event.name, privacy: .public)")
            return
        }
        queue.append(QueuedTelemetryEvent(name: event.name, properties: payload, day: Self.day(of: now())))
        if queue.count > maxQueuedEvents { queue.removeFirst(queue.count - maxQueuedEvents) }
        persist()
        await flushIfDue()
    }

    /// Sends the queue if a day has passed since the last attempt. The first event only
    /// starts the window, so nothing is sent in the first 24 hours after opting in.
    public func flushIfDue() async {
        let current = now()
        guard let lastFlush = keyValueStore.date(forKey: Self.lastFlushKey) else {
            keyValueStore.setDate(current, forKey: Self.lastFlushKey)
            return
        }
        guard current.timeIntervalSince(lastFlush) >= Self.flushInterval || current < lastFlush,
            !queue.isEmpty
        else { return }
        keyValueStore.setDate(current, forKey: Self.lastFlushKey)
        let sent = queue
        do {
            try await transport.send(try encodedBatch(sent, pretty: false))
            queue.removeFirst(min(sent.count, queue.count))
            persist()
        } catch {
            Log.telemetry.info("Telemetry flush failed; will retry tomorrow")
        }
    }

    /// The pending batch exactly as it would be sent, pretty-printed for Settings > Privacy.
    public func pendingPayloadPreview() -> String {
        guard let data = try? encodedBatch(queue, pretty: true) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public func pendingEvents() -> [QueuedTelemetryEvent] { queue }

    /// Deletes every queued event (used when the user opts out).
    public func discardAll() {
        queue.removeAll()
        try? FileManager.default.removeItem(at: queueURL)
    }

    // MARK: - Private

    private func encodedBatch(_ events: [QueuedTelemetryEvent], pretty: Bool) throws -> Data {
        let batch = TelemetryBatch(anonymousID: AnonymousID.current(in: keyValueStore, now: now()), events: events)
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(batch)
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(queue).write(to: queueURL, options: .atomic)
        } catch {
            Log.telemetry.error("Could not persist telemetry queue")
        }
    }

    private static func load(from url: URL) -> [QueuedTelemetryEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([QueuedTelemetryEvent].self, from: data)) ?? []
    }

    static func day(of date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Forwards events only while the user has opted in; opting out discards the queue.
public actor OptInTelemetryClient: TelemetryClient {
    private let sender: QueuedTelemetryClient
    public private(set) var isEnabled: Bool

    public init(sender: QueuedTelemetryClient, isEnabled: Bool) {
        self.sender = sender
        self.isEnabled = isEnabled
    }

    public func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        if !enabled { await sender.discardAll() }
    }

    public func record(_ event: TelemetryEvent) async {
        guard isEnabled else { return }
        await sender.record(event)
    }

    public func pendingPayloadPreview() async -> String {
        await sender.pendingPayloadPreview()
    }
}
