import AppKit
import GlintCore
import SwiftUI
import Testing

@testable import GlintUI

private func source(items: Int, indexed: Int = 0, pending: Int = 0, failed: Int = 0, accessible: Bool = true) -> SourceInfo {
    SourceInfo(
        id: SourceID(1), path: "/Users/demo/Footage", isExternalVolume: false, isAccessible: accessible, itemCount: items,
        indexed: indexed, pending: pending, failed: failed
    )
}

@MainActor
@Suite("Folder indexing state")
struct SourceIndexStateTests {
    @Test func mapsCountsAndPhaseToState() {
        #expect(SourceIndexState(source: source(items: 0), phase: .scanning) == .scanning)
        #expect(SourceIndexState(source: source(items: 0), phase: .idle) == .empty)
        #expect(SourceIndexState(source: source(items: 10, indexed: 4, pending: 6), phase: .indexing) == .indexing(done: 4, total: 10))
        #expect(
            SourceIndexState(source: source(items: 10, indexed: 4, pending: 6), phase: .paused(.lowBattery))
                == .paused(.lowBattery, done: 4, total: 10))
        #expect(SourceIndexState(source: source(items: 10, indexed: 10), phase: .indexing) == .complete(indexed: 10))
        #expect(SourceIndexState(source: source(items: 10, indexed: 4, pending: 6, accessible: false), phase: .idle) == .unreadable)
    }

    @Test func disconnectedShareIsNotAnError() {
        let share = SourceInfo(
            id: SourceID(2), path: "/Volumes/Team", isExternalVolume: true, isNetworkVolume: true, isAccessible: false,
            itemCount: 40, indexed: 40)
        let state = SourceIndexState(source: share, phase: .idle)
        #expect(state == .disconnected)
        #expect(state.title == "Share not connected")
        #expect(SourceStatusView.footnote(for: share) == "Indexed files stay searchable")
        #expect(share.symbolName == "server.rack")
    }

    @Test func failedFilesDoNotBlockCompletion() {
        let source = source(items: 12, indexed: 10, failed: 2)
        #expect(SourceIndexState(source: source, phase: .idle) == .complete(indexed: 10))
        #expect(SourceStatusView.footnote(for: source) == "2 couldn’t be read")
    }

    @Test func titlesAndProgress() {
        let state = SourceIndexState.indexing(done: 1_204, total: 5_310)
        #expect(state.title == "Indexing 1,204 of 5,310")
        #expect(abs((state.fraction ?? 0) - 1_204.0 / 5_310.0) < 1e-9)
        #expect(SourceIndexState.complete(indexed: 42).title == "Indexed · 42 items")
        #expect(SourceIndexState.complete(indexed: 42).fraction == nil)
    }
}

@MainActor
@Suite("Folder status snapshots")
struct SourceStatusSnapshotTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func rendersEveryState(scheme: ColorScheme) throws {
        let rows: [(String, SourceInfo, IndexStatus.Phase)] = [
            ("Footage", source(items: 5_310, indexed: 1_204, pending: 4_106), .indexing),
            ("Documents", source(items: 812, indexed: 800, failed: 3), .idle),
            ("Downloads", source(items: 300, indexed: 120, pending: 180), .paused(.user)),
            ("Desktop", source(items: 0), .scanning),
            ("Backup Drive", source(items: 40, accessible: false), .idle),
        ]
        let view = VStack(alignment: .leading, spacing: 12) {
            ForEach(rows, id: \.0) { row in
                HStack {
                    Label(row.0, systemImage: "folder")
                    Spacer()
                    SourceStatusView(source: row.1, phase: row.2)
                }
            }
        }
        .padding()
        .frame(width: 520)
        .environment(\.colorScheme, scheme)
        .background(scheme == .dark ? Color(white: 0.12) : Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.height > 100)
        guard let directory = ProcessInfo.processInfo.environment["GLINT_SNAPSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("folder-status-\(scheme == .dark ? "dark" : "light").png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
    }
}
