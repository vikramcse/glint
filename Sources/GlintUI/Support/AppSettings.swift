import Foundation
import GlintCore
import Observation

/// User preferences, persisted in `UserDefaults`.
@MainActor
@Observable
public final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    public var hotKey: KeyCombo { didSet { save(hotKey, for: .hotKey) } }
    public var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin.rawValue) } }
    public var hideMenuBarItemWhenIdle: Bool { didSet { defaults.set(hideMenuBarItemWhenIdle, forKey: Key.hideMenuBarItem.rawValue) } }
    public var groupResultsByKind: Bool { didSet { defaults.set(groupResultsByKind, forKey: Key.groupResults.rawValue) } }
    public var defaultKinds: Set<MediaKind> { didSet { save(defaultKinds, for: .defaultKinds) } }
    public var transcribeAudio: Bool { didSet { defaults.set(transcribeAudio, forKey: Key.transcribe.rawValue) } }
    /// Matryoshka output size of the search model: 768, 512 (default) or 256.
    public var modelDimensions: Int { didSet { defaults.set(modelDimensions, forKey: Key.modelDimensions.rawValue) } }
    public var videoOnlyOnPower: Bool { didSet { defaults.set(videoOnlyOnPower, forKey: Key.videoOnPower.rawValue) } }
    /// Allow apps and agents on this Mac to search Glint through the local API. Off by default.
    public var localAPIEnabled: Bool { didSet { defaults.set(localAPIEnabled, forKey: Key.localAPI.rawValue) } }
    public var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboarded.rawValue) } }
    public var hasSearched: Bool { didSet { defaults.set(hasSearched, forKey: Key.searched.rawValue) } }
    public var mainWindowLayout: ResultsLayout {
        didSet { defaults.set(mainWindowLayout.rawValue, forKey: Key.layout.rawValue) }
    }
    public let installDate: Date

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotKey = Self.load(KeyCombo.self, from: defaults, key: .hotKey) ?? .defaultSearch
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin.rawValue)
        hideMenuBarItemWhenIdle = defaults.bool(forKey: Key.hideMenuBarItem.rawValue)
        groupResultsByKind = defaults.object(forKey: Key.groupResults.rawValue) as? Bool ?? true
        defaultKinds = Self.load(Set<MediaKind>.self, from: defaults, key: .defaultKinds) ?? []
        transcribeAudio = defaults.bool(forKey: Key.transcribe.rawValue)
        let storedDimensions = defaults.integer(forKey: Key.modelDimensions.rawValue)
        modelDimensions = [768, 512, 256].contains(storedDimensions) ? storedDimensions : 512
        videoOnlyOnPower = defaults.bool(forKey: Key.videoOnPower.rawValue)
        localAPIEnabled = defaults.bool(forKey: Key.localAPI.rawValue)
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboarded.rawValue)
        hasSearched = defaults.bool(forKey: Key.searched.rawValue)
        mainWindowLayout = ResultsLayout(rawValue: defaults.string(forKey: Key.layout.rawValue) ?? "") ?? .grid
        if let stored = defaults.object(forKey: Key.installDate.rawValue) as? Date {
            installDate = stored
        } else {
            installDate = Date()
            defaults.set(installDate, forKey: Key.installDate.rawValue)
        }
    }

    private enum Key: String {
        case hotKey = "glint.hotKey"
        case launchAtLogin = "glint.launchAtLogin"
        case hideMenuBarItem = "glint.hideMenuBarItemWhenIdle"
        case groupResults = "glint.groupResultsByKind"
        case defaultKinds = "glint.defaultKinds"
        case transcribe = "glint.transcribeAudio"
        case modelDimensions = "glint.modelDimensions"
        case videoOnPower = "glint.videoOnlyOnPower"
        case localAPI = "glint.localAPIEnabled"
        case onboarded = "glint.hasCompletedOnboarding"
        case searched = "glint.hasSearched"
        case layout = "glint.mainWindowLayout"
        case installDate = "glint.installDate"
    }

    private func save<T: Encodable>(_ value: T, for key: Key) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key.rawValue)
    }

    private static func load<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: Key) -> T? {
        defaults.data(forKey: key.rawValue).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

/// How the main window lays out results.
public enum ResultsLayout: String, Sendable, CaseIterable {
    case grid, list
}

/// A global keyboard shortcut (Carbon virtual key code plus modifiers).
public struct KeyCombo: Codable, Sendable, Hashable {
    public var keyCode: UInt32
    public var command: Bool
    public var option: Bool
    public var control: Bool
    public var shift: Bool

    public init(keyCode: UInt32, command: Bool = false, option: Bool = false, control: Bool = false, shift: Bool = false) {
        self.keyCode = keyCode
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }

    /// ⌥Space.
    public static let defaultSearch = KeyCombo(keyCode: 49, option: true)

    public var hasModifier: Bool { command || option || control }

    /// Display string such as "⌥Space".
    public var displayString: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [
            49: "Space", 36: "Return", 48: "Tab", 53: "Esc", 51: "Delete",
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L",
            46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
            16: "Y", 6: "Z", 29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            44: "/", 47: ".", 43: ",", 41: ";", 39: "'", 42: "\\", 27: "-", 24: "=", 33: "[", 30: "]", 50: "`",
        ]
        return names[code] ?? "Key \(code)"
    }
}
