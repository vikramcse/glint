import Foundation

/// Turns raw numbers into coarse buckets. Every telemetry property value comes from one of
/// these closed sets, so no event can carry free text, paths or exact counts.
public enum TelemetryBuckets {
    // MARK: Latency

    public static let latencyValues = ["<30ms", "30-60ms", "60-100ms", "100-150ms", "150-300ms", "300-1000ms", ">1000ms"]

    public static func latency(milliseconds: Double) -> String {
        switch milliseconds {
        case ..<30: latencyValues[0]
        case ..<60: latencyValues[1]
        case ..<100: latencyValues[2]
        case ..<150: latencyValues[3]
        case ..<300: latencyValues[4]
        case ..<1_000: latencyValues[5]
        default: latencyValues[6]
        }
    }

    // MARK: Counts

    public static let countValues = ["0", "1", "2-5", "6-10", "11-50", "51-100", "101-1k", "1k-10k", "10k-100k", ">100k"]

    public static func count(_ value: Int) -> String {
        switch value {
        case ..<1: countValues[0]
        case 1: countValues[1]
        case 2...5: countValues[2]
        case 6...10: countValues[3]
        case 11...50: countValues[4]
        case 51...100: countValues[5]
        case 101...1_000: countValues[6]
        case 1_001...10_000: countValues[7]
        case 10_001...100_000: countValues[8]
        default: countValues[9]
        }
    }

    // MARK: Time since install

    public static let sinceInstallValues = ["<3m", "3-10m", "10-60m", "1-24h", "1-7d", ">7d"]

    public static func sinceInstall(minutes: Double) -> String {
        switch minutes {
        case ..<3: sinceInstallValues[0]
        case ..<10: sinceInstallValues[1]
        case ..<60: sinceInstallValues[2]
        case ..<(24 * 60): sinceInstallValues[3]
        case ..<(7 * 24 * 60): sinceInstallValues[4]
        default: sinceInstallValues[5]
        }
    }

    // MARK: Durations

    public static let durationValues = ["<30s", "30-60s", "1-3m", "3-10m", ">10m"]

    public static func duration(seconds: TimeInterval) -> String {
        switch seconds {
        case ..<30: durationValues[0]
        case ..<60: durationValues[1]
        case ..<180: durationValues[2]
        case ..<600: durationValues[3]
        default: durationValues[4]
        }
    }

    // MARK: Memory

    public static let ramValues = ["≤8GB", "16GB", "24GB", "32GB", "48GB", "64GB", "96GB", "≥128GB"]

    /// Buckets physical memory to the nearest common Mac configuration at or above it.
    public static func ram(bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        let steps: [Double] = [8, 16, 24, 32, 48, 64, 96]
        for (index, step) in steps.enumerated() where gigabytes <= step + 0.5 {
            return ramValues[index]
        }
        return ramValues[7]
    }

    // MARK: Rank

    public static let rankValues = ["1", "2", "3", "4-5", "6-10", ">10"]

    /// Buckets a one-based result rank.
    public static func rank(_ value: Int) -> String {
        switch value {
        case ..<2: rankValues[0]
        case 2: rankValues[1]
        case 3: rankValues[2]
        case 4...5: rankValues[3]
        case 6...10: rankValues[4]
        default: rankValues[5]
        }
    }
}
