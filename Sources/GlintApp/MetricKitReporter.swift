import Foundation
import GlintCore
import MetricKit

/// Saves MetricKit metric and diagnostic payloads (crashes, hangs, launch time) to a local
/// diagnostics folder. Nothing is sent over the network.
final class MetricKitReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
        super.init()
    }

    func start() {
        MXMetricManager.shared.add(self)
    }

    func stop() {
        MXMetricManager.shared.remove(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads { save(payload.jsonRepresentation(), prefix: "metrics") }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { save(payload.jsonRepresentation(), prefix: "diagnostics") }
    }

    /// Payload files saved so far, newest first.
    func savedPayloads() -> [URL] {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func save(_ data: Data, prefix: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = Int(Date().timeIntervalSince1970 * 1_000)
            let url = directory.appendingPathComponent("\(prefix)-\(stamp)-\(UUID().uuidString.prefix(8)).json")
            try data.write(to: url, options: .atomic)
        } catch {
            Log.app.error("Could not save MetricKit payload")
        }
    }
}
