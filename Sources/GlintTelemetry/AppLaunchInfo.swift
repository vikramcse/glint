import Foundation

/// Hardware and version facts for `app_launched`, already reduced to coarse values.
public struct AppLaunchInfo: Sendable, Hashable {
    public static let chipFamilies = ["M1", "M2", "M3", "M4", "M5", "M6", "Apple", "Intel", "other"]

    /// `major.minor[.patch]`, or `unknown`.
    public var appVersion: String
    /// `major.minor`, for example `26.6`.
    public var macOSVersion: String
    /// One of `chipFamilies`.
    public var chipFamily: String
    /// One of `TelemetryBuckets.ramValues`.
    public var ramBucket: String

    public init(appVersion: String, macOSVersion: String, chipFamily: String, ramBucket: String) {
        self.appVersion = Self.sanitizedVersion(appVersion)
        self.macOSVersion = Self.sanitizedVersion(macOSVersion)
        self.chipFamily = Self.chipFamilies.contains(chipFamily) ? chipFamily : "other"
        self.ramBucket = TelemetryBuckets.ramValues.contains(ramBucket) ? ramBucket : TelemetryBuckets.ramValues[0]
    }

    /// Facts about this Mac and build.
    public static func current(bundle: Bundle = .main) -> AppLaunchInfo {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return AppLaunchInfo(
            appVersion: version,
            macOSVersion: "\(os.majorVersion).\(os.minorVersion)",
            chipFamily: chipFamily(fromBrand: cpuBrand()),
            ramBucket: TelemetryBuckets.ram(bytes: ProcessInfo.processInfo.physicalMemory)
        )
    }

    /// Reduces a CPU brand string ("Apple M1 Pro", "Apple M5") to its family ("M1", "M5").
    public static func chipFamily(fromBrand brand: String) -> String {
        if brand.contains("Intel") { return "Intel" }
        guard brand.hasPrefix("Apple") else { return "other" }
        let words = brand.split(separator: " ")
        for word in words where word.hasPrefix("M") && word.count >= 2 {
            let family = String(word.prefix(while: { $0 == "M" || $0.isNumber }))
            if chipFamilies.contains(family) { return family }
        }
        return "Apple"
    }

    /// Keeps only `digits(.digits){0,2}`; anything else becomes `unknown`.
    static func sanitizedVersion(_ version: String) -> String {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
            parts.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
        else { return "unknown" }
        return version
    }

    private static func cpuBrand() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "" }
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
