import AppKit
import GlintCore
import GlintLicensing
import GlintSearch
import SwiftUI
import Testing

@testable import GlintUI

/// Renders key views in light and dark appearance.
/// Every render must succeed; set `GLINT_SNAPSHOT_DIR` to write PNGs for review (CI uploads
/// them as artifacts and diffs them against the last `main` build).
@MainActor
@Suite("Snapshots")
struct SnapshotTests {
    static let waveform: [Float] = (0..<120).map { index in
        Float(0.25 + 0.7 * abs(sin(Double(index) / 6)) * (index % 9 == 0 ? 0.4 : 1))
    }

    static var rows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ResultRow(
                result: .fixture(name: "Festival.mov", kind: .video, locator: .time(start: 724, end: 729), waveform: waveform),
                isSelected: true)
            ResultRow(
                result: .fixture(name: "Standup 14 Sep.m4a", kind: .audio, locator: .time(start: 198, end: 208), waveform: waveform),
                isSelected: false)
            ResultRow(
                result: .fixture(
                    name: "Acme pitch.pdf", kind: .pdf, locator: .page(1),
                    snippet: "Pricing: Starter $19, Team $49, Enterprise custom pricing for the Acme pitch"), isSelected: false)
            ResultRow(
                result: .fixture(name: "standup.txt", kind: .document, snippet: "The client mentioned the deadline is Friday the 19th"),
                isSelected: false)
            ResultRow(
                result: {
                    var locked = SearchResult.fixture(name: "Interview.mov", kind: .video, locator: .time(start: 61, end: 66));
                    locked.isLocked = true; return locked
                }(), isSelected: false)
        }
        .padding()
        .frame(width: 640)
    }

    static var licenseStates: some View {
        VStack(alignment: .leading, spacing: 12) {
            LicenseStatusRow(state: .trial(daysLeft: 9, endsAt: Date(timeIntervalSince1970: 1_800_000_000)))
            LicenseStatusRow(state: .trialExpired)
            LicenseStatusRow(state: .revoked)
            LicenseStatusRow(state: .seatLimitReached)
        }
        .padding()
        .frame(width: 520)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func rendersResultRows(scheme: ColorScheme) throws {
        try render(Self.rows, name: "result-rows", scheme: scheme)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func rendersLicenseStates(scheme: ColorScheme) throws {
        try render(Self.licenseStates, name: "license-states", scheme: scheme)
    }

    @Test func rendersWaveformWithHighlight() throws {
        try render(
            WaveformView(peaks: Self.waveform, highlight: 0.4...0.5, playhead: 0.45).frame(width: 300, height: 40).padding(),
            name: "waveform", scheme: .light)
    }

    private func render(_ view: some View, name: String, scheme: ColorScheme) throws {
        let content =
            view
            .environment(\.colorScheme, scheme)
            .background(scheme == .dark ? Color(white: 0.12) : Color.white)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.cgImage, "Could not render \(name)")
        #expect(image.width > 100 && image.height > 20)
        guard let directory = ProcessInfo.processInfo.environment["GLINT_SNAPSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
