import Foundation
import GlintCore
import GlintLocalAPI
import GlintSearch
import GlintUI

/// Runs the loopback API (and so `glint-mcp`) while the user allows it.
@MainActor
final class LocalAPIController {
    let control: LocalAPIControl
    private let paths: AppPaths
    private let engine: SearchEngine
    private let indexing: any IndexingService
    private let settings: AppSettings
    private var server: LocalAPIServer?

    init(paths: AppPaths, engine: SearchEngine, indexing: any IndexingService, settings: AppSettings) {
        self.paths = paths
        self.engine = engine
        self.indexing = indexing
        self.settings = settings
        let tool = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/glint-mcp").path
        control = LocalAPIControl(mcpCommand: "claude mcp add glint -- \"\(tool)\"")
        control.resetAccess = { [weak self] in await self?.resetAccess() }
    }

    /// Starts or stops the server to match the setting.
    func apply() async {
        let wanted = settings.localAPIEnabled
        if wanted, server == nil {
            await start()
        } else if !wanted {
            // Also clears a discovery file left by a previous run that didn't shut down cleanly.
            stop()
        }
    }

    func stop() {
        server?.stop()
        server = nil
        LocalAPICredentials.removeDiscovery(at: paths.apiDiscovery)
        control.status = .off
    }

    private func start() async {
        control.status = .starting
        do {
            let token = try LocalAPICredentials.loadOrCreateToken(at: paths.apiToken)
            let server = LocalAPIServer(router: LocalAPIRouter(engine: engine, indexing: indexing, token: token))
            let port = try await server.start()
            try LocalAPICredentials.writeDiscovery(LocalAPIDiscovery(port: port, token: token), to: paths.apiDiscovery)
            self.server = server
            control.status = .running(port: port)
        } catch {
            server = nil
            control.status = .failed(ErrorPresenter.message(for: error))
        }
    }

    /// New token: every connected app or agent must re-read the discovery file.
    private func resetAccess() async {
        _ = try? LocalAPICredentials.rotateToken(at: paths.apiToken)
        if server != nil {
            stop()
            await start()
        }
    }
}
