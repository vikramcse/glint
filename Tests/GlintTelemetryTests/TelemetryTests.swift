import Foundation
import GlintCore
import Testing

@testable import GlintTelemetry

final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(hours: Double) { lock.withLock { current = current.addingTimeInterval(hours * 3_600) } }
    var provider: @Sendable () -> Date { { [self] in now } }
}

final class RecordingTransport: TelemetryTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _bodies: [Data] = []
    private var _fail = false
    var bodies: [Data] { lock.withLock { _bodies } }
    var fail: Bool {
        get { lock.withLock { _fail } }
        set { lock.withLock { _fail = newValue } }
    }

    func send(_ body: Data) async throws {
        if fail { throw URLError(.notConnectedToInternet) }
        lock.withLock { _bodies.append(body) }
    }
}

func temporaryQueueURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("glint-telemetry-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("queue.json")
}

/// One sample of every event, with values chosen to exercise edge buckets.
let everyEvent: [TelemetryEvent] = [
    .appLaunched(AppLaunchInfo(appVersion: "1.0.2", macOSVersion: "26.6", chipFamily: "M1", ramBucket: "≤8GB")),
    .appLaunched(AppLaunchInfo(appVersion: "/Users/secret/path", macOSVersion: "26.6", chipFamily: "Mx", ramBucket: "lots")),
    .onboardingCompleted(sourceCount: 4, duration: 47),
    .firstSearch(minutesSinceInstall: 2.5),
    .indexProgress(itemsPerKind: [.image: 12_000, .video: 3], pending: 0),
    .searchPerformed(latencyMilliseconds: 92, resultCount: 37, kinds: [.video, .image]),
    .searchPerformed(latencyMilliseconds: 5, resultCount: 0, kinds: []),
    .resultOpened(rank: 7, kind: .pdf),
    .paywallViewed(.lockedResult),
    .trialStarted,
    .licenseActivated,
]

@Suite("Buckets")
struct BucketTests {
    @Test(arguments: [(0.0, "<30ms"), (29.9, "<30ms"), (30, "30-60ms"), (149, "100-150ms"), (150, "150-300ms"), (5_000, ">1000ms")])
    func latency(ms: Double, bucket: String) { #expect(TelemetryBuckets.latency(milliseconds: ms) == bucket) }

    @Test(arguments: [(0, "0"), (1, "1"), (5, "2-5"), (10, "6-10"), (101, "101-1k"), (10_000, "1k-10k"), (250_000, ">100k")])
    func count(value: Int, bucket: String) { #expect(TelemetryBuckets.count(value) == bucket) }

    @Test(arguments: [(1.0, "<3m"), (3, "3-10m"), (59, "10-60m"), (120, "1-24h"), (2_000, "1-7d"), (20_000, ">7d")])
    func sinceInstall(minutes: Double, bucket: String) { #expect(TelemetryBuckets.sinceInstall(minutes: minutes) == bucket) }

    @Test(arguments: [(UInt64(8) << 30, "≤8GB"), (UInt64(16) << 30, "16GB"), (UInt64(36) << 30, "48GB"), (UInt64(192) << 30, "≥128GB")])
    func ram(bytes: UInt64, bucket: String) { #expect(TelemetryBuckets.ram(bytes: bytes) == bucket) }

    @Test(arguments: [(1, "1"), (3, "3"), (5, "4-5"), (10, "6-10"), (11, ">10")])
    func rank(value: Int, bucket: String) { #expect(TelemetryBuckets.rank(value) == bucket) }

    @Test(arguments: [
        ("Apple M1", "M1"), ("Apple M1 Pro", "M1"), ("Apple M5 Max", "M5"),
        ("Intel(R) Core(TM) i9", "Intel"), ("Apple Silicon", "Apple"), ("", "other"),
    ])
    func chipFamily(brand: String, family: String) { #expect(AppLaunchInfo.chipFamily(fromBrand: brand) == family) }

    @Test func currentLaunchInfoIsBucketed() {
        let info = AppLaunchInfo.current()
        #expect(AppLaunchInfo.chipFamilies.contains(info.chipFamily))
        #expect(TelemetryBuckets.ramValues.contains(info.ramBucket))
    }
}

@Suite("Redaction")
struct RedactionTests {
    @Test func everyEventStaysInsideSchema() {
        for event in everyEvent {
            #expect(TelemetrySchema.isAllowed(name: event.name, payload: event.payload), "\(event.name) \(event.payload)")
        }
    }

    @Test func freeTextIsNeverEmitted() {
        let launch = TelemetryEvent.appLaunched(
            AppLaunchInfo(appVersion: "/Users/secret/path", macOSVersion: "beach.jpg", chipFamily: "Mx", ramBucket: "lots")
        )
        #expect(launch.payload["app_version"] == "unknown")
        #expect(launch.payload["macos_version"] == "unknown")
        #expect(launch.payload["chip_family"] == "other")
        let values = everyEvent.flatMap { $0.payload.values }
        #expect(!values.contains { $0.contains("/") || $0.contains("secret") })
    }

    @Test func schemaRejectsUnknownKeysAndValues() {
        #expect(!TelemetrySchema.isAllowed(name: "search_performed", payload: ["query": "crowd cheering"]))
        #expect(!TelemetrySchema.isAllowed(name: "result_opened", payload: ["rank": "7"]))
        #expect(!TelemetrySchema.isAllowed(name: "made_up", payload: ["x": "1"]))
    }

    @Test func eventNamesMatchPRD() {
        let names = Set(everyEvent.map(\.name))
        #expect(names == [
            "app_launched", "onboarding_completed", "first_search", "index_progress", "search_performed",
            "result_opened", "paywall_viewed", "trial_started", "license_activated",
        ])
    }
}

@Suite("Queued client")
struct QueuedClientTests {
    let clock = MutableClock()
    let transport = RecordingTransport()
    let store = InMemoryKeyValueStore()
    let queueURL = temporaryQueueURL()

    func client(random: @escaping @Sendable () -> Double = { 0 }) -> QueuedTelemetryClient {
        QueuedTelemetryClient(
            queueURL: queueURL, transport: transport, keyValueStore: store, now: clock.provider, random: random
        )
    }

    @Test func searchIsSampledAtTenPercent() async {
        let sampledOut = client(random: { 0.1 })
        await sampledOut.record(.searchPerformed(latencyMilliseconds: 10, resultCount: 1, kinds: [.image]))
        await sampledOut.record(.trialStarted)
        #expect(await sampledOut.pendingEvents().map(\.name) == ["trial_started"])

        let sampledIn = client(random: { 0.05 })
        await sampledIn.record(.searchPerformed(latencyMilliseconds: 10, resultCount: 1, kinds: [.image]))
        #expect(await sampledIn.pendingEvents().map(\.name).last == "search_performed")
    }

    @Test func flushesAtMostOnceADay() async throws {
        let client = client()
        await client.record(.trialStarted)
        #expect(transport.bodies.isEmpty)
        clock.advance(hours: 23)
        await client.record(.licenseActivated)
        #expect(transport.bodies.isEmpty)
        clock.advance(hours: 2)
        await client.record(.paywallViewed(.menu))
        #expect(transport.bodies.count == 1)
        #expect(await client.pendingEvents().isEmpty)

        let batch = try JSONDecoder().decode(TelemetryBatch.self, from: try #require(transport.bodies.first))
        #expect(batch.events.map(\.name) == ["trial_started", "license_activated", "paywall_viewed"])
        #expect(batch.events.allSatisfy { $0.day.count == 10 })

        clock.advance(hours: 1)
        await client.record(.trialStarted)
        #expect(transport.bodies.count == 1)
    }

    @Test func failedFlushKeepsQueueUntilNextDay() async {
        let client = client()
        await client.record(.trialStarted)
        transport.fail = true
        clock.advance(hours: 25)
        await client.record(.licenseActivated)
        #expect(await client.pendingEvents().count == 2)
        transport.fail = false
        clock.advance(hours: 1)
        await client.flushIfDue()
        #expect(transport.bodies.isEmpty)
        clock.advance(hours: 24)
        await client.flushIfDue()
        #expect(transport.bodies.count == 1)
    }

    @Test func queueSurvivesRelaunch() async {
        await client().record(.trialStarted)
        let relaunched = client()
        #expect(await relaunched.pendingEvents().map(\.name) == ["trial_started"])
        await relaunched.discardAll()
        #expect(await client().pendingEvents().isEmpty)
    }

    @Test func previewShowsExactPayload() async {
        let client = client()
        await client.record(.resultOpened(rank: 2, kind: .video))
        let preview = await client.pendingPayloadPreview()
        #expect(preview.contains("\"anonymous_id\""))
        #expect(preview.contains("result_opened"))
        #expect(preview.contains("\"rank\" : \"2\""))
    }

    @Test func optInClientDropsEventsWhenDisabled() async {
        let sender = client()
        let optIn = OptInTelemetryClient(sender: sender, isEnabled: false)
        await optIn.record(.trialStarted)
        #expect(await sender.pendingEvents().isEmpty)
        await optIn.setEnabled(true)
        await optIn.record(.trialStarted)
        #expect(await sender.pendingEvents().count == 1)
        await optIn.setEnabled(false)
        #expect(await sender.pendingEvents().isEmpty)
    }
}

@Suite("Anonymous id")
struct AnonymousIDTests {
    @Test func rotatesEveryNinetyDays() {
        let store = InMemoryKeyValueStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = AnonymousID.current(in: store, now: start)
        #expect(AnonymousID.current(in: store, now: start.addingTimeInterval(89 * 86_400)) == first)
        let rotated = AnonymousID.current(in: store, now: start.addingTimeInterval(90 * 86_400))
        #expect(rotated != first)
        #expect(AnonymousID.current(in: store, now: start.addingTimeInterval(91 * 86_400)) == rotated)
    }

    @Test func clockBeforeCreationRotates() {
        let store = InMemoryKeyValueStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = AnonymousID.current(in: store, now: start)
        #expect(AnonymousID.current(in: store, now: start.addingTimeInterval(-86_400)) != first)
    }
}

@Suite("MetricKit reporter")
struct MetricKitReporterTests {
    @Test func savesPayloadsLocally() throws {
        let directory = temporaryQueueURL().deletingLastPathComponent()
        let reporter = MetricKitReporter(directory: directory)
        reporter.save(Data("{}".utf8), prefix: "metrics")
        #expect(reporter.savedPayloads().count == 1)
        try? FileManager.default.removeItem(at: directory)
    }
}
