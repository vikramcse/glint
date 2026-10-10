import Foundation

/// External endpoints, read from Info.plist so a release can point at its store, license
/// server and telemetry endpoint without code changes.
///
/// | Key | Effect when empty or missing |
/// | --- | --- |
/// | `GlintPurchaseURL` | Falls back to the default store page |
/// | `GlintLicenseServerURL` | No server: a validly signed key activates offline (development) |
/// | `GlintTelemetryURL` | Falls back to the default endpoint (still opt-in) |
struct AppConfiguration: Sendable {
    let purchasePage: URL?
    let licenseServer: URL?
    let telemetryEndpoint: URL

    static let defaultPurchasePage = URL(string: "https://glint.app/buy")
    static let defaultTelemetryEndpoint = URL(string: "https://telemetry.glint.app/v1/events") ?? URL(fileURLWithPath: "/dev/null")
    static let fullDiskAccessSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")

    init(info: [String: Any]) {
        purchasePage = Self.url(info["GlintPurchaseURL"]) ?? Self.defaultPurchasePage
        licenseServer = Self.url(info["GlintLicenseServerURL"])
        telemetryEndpoint = Self.url(info["GlintTelemetryURL"]) ?? Self.defaultTelemetryEndpoint
    }

    /// The configuration of the running app bundle.
    static let current = AppConfiguration(info: Bundle.main.infoDictionary ?? [:])

    /// Only absolute https URLs count; anything else (empty, placeholder, http) is ignored.
    private static func url(_ value: Any?) -> URL? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty,
            let url = URL(string: string), url.scheme == "https", url.host() != nil
        else { return nil }
        return url
    }
}
