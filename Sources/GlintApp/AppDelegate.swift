import AppKit
import GlintCore
import GlintLicensing
import GlintTelemetry
import GlintUI
import Observation
import ServiceManagement

/// Owns the app lifecycle: builds the environment, the panel and the hotkey, and keeps
/// settings, license state and services in sync.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    private(set) var environment: AppEnvironment?
    private(set) var actions: AppResultActions?
    private var panel: SearchPanelController?
    private let hotKeys = HotKeyCenter()
    private var timers: [Timer] = []
    private var launchError: (any Error)?

    override init() {
        super.init()
        do {
            environment = try AppEnvironment(settings: settings)
        } catch {
            launchError = error
            Log.app.fault("Glint could not start: \(String(describing: error), privacy: .public)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let environment else {
            presentLaunchFailure()
            return
        }
        let actions = AppResultActions(services: environment.services, savedSearches: environment.savedSearches)
        let panel = SearchPanelController(services: environment.services)
        actions.panel = panel
        environment.services.actions = actions
        self.actions = actions
        self.panel = panel

        registerHotKey()
        wireLicense(environment)
        observeSettings(environment)
        environment.metricKit.start()
        environment.services.status.start()
        scheduleMaintenance(environment)

        Task {
            await environment.telemetry.record(.appLaunched(AppLaunchInfo.current()))
            await environment.start()
        }

        if !settings.hasCompletedOnboarding {
            actions.showOnboarding { [weak self] in self?.panel?.show() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { actions?.showMainWindow() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let environment else { return }
        for url in urls where url.scheme == "glint" {
            Task {
                if await environment.license.handle(url: url) {
                    actions?.showMainWindow()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment?.metricKit.stop()
        hotKeys.unregister()
    }

    /// Opens the search panel (menu bar "Search…").
    func showSearch() {
        panel?.show()
    }

    // MARK: Wiring

    private func registerHotKey() {
        if !hotKeys.register(settings.hotKey, action: { [weak self] in self?.panel?.toggle() }) {
            Log.app.notice("Search shortcut is in use by another app")
        }
    }

    private func wireLicense(_ environment: AppEnvironment) {
        let license = environment.license
        var wasLicensed = license.entitlements.isLicensed
        license.onChange = { entitlements in
            environment.features.update(entitlements.snapshot)
            Task { await environment.indexer.entitlementsDidChange() }
            if entitlements.isLicensed, !wasLicensed {
                Task { await environment.telemetry.record(.licenseActivated) }
            }
            wasLicensed = entitlements.isLicensed
        }
        if license.startTrialIfNeeded() {
            Task { await environment.telemetry.record(.trialStarted) }
        }
        license.refresh()
        environment.features.update(license.entitlements.snapshot)
        Task { await license.revalidateIfNeeded() }
    }

    private func observeSettings(_ environment: AppEnvironment) {
        observe({ self.settings.hotKey }) { [weak self] _ in self?.registerHotKey() }
        observe({ self.settings.analyticsEnabled }) { enabled in
            Task { await environment.telemetry.setEnabled(enabled) }
        }
        observe({ self.settings.launchAtLogin }) { enabled in
            do {
                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.app.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        observe({ [self.settings.groupResultsByKind.description, self.settings.defaultKinds.map(\.rawValue).sorted().description] }) { [weak self] _ in
            guard let self else { return }
            self.panel?.applySettings(self.settings)
        }
        observe({ [self.settings.transcribeAudio, self.settings.videoOnlyOnPower] }) { _ in
            Task { await environment.applyIndexingSettings() }
        }
    }

    /// Calls `onChange` whenever `value` changes, re-arming Observation tracking each time.
    private func observe<Value: Equatable>(_ value: @escaping @MainActor () -> Value, onChange: @escaping @MainActor (Value) -> Void) {
        withObservationTracking {
            _ = value()
        } onChange: {
            Task { @MainActor [weak self] in
                onChange(value())
                self?.observe(value, onChange: onChange)
            }
        }
    }

    private func scheduleMaintenance(_ environment: AppEnvironment) {
        // Hourly: send the telemetry batch if a day has passed (no-op when opted out).
        timers.append(Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { _ in
            Task { await environment.telemetrySender.flushIfDue() }
        })
        // Daily: license re-validation (itself limited to weekly) and the index progress event.
        timers.append(Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { _ in
            Task { @MainActor in
                await environment.license.revalidateIfNeeded()
                let status = await environment.indexer.currentStatus()
                await environment.telemetry.record(.indexProgress(itemsPerKind: status.indexed, pending: status.pending))
            }
        })
    }

    private func presentLaunchFailure() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Glint couldn’t start")
        alert.informativeText = launchError.map(ErrorPresenter.message(for:))
            ?? String(localized: "Something went wrong. Please try again.")
        alert.alertStyle = .critical
        alert.addButton(withTitle: String(localized: "Quit"))
        NSApp.activate()
        alert.runModal()
        NSApp.terminate(nil)
    }
}
