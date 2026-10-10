import Foundation
import GlintCore
import IOKit.ps

/// Reads battery, Low Power Mode and thermal state from the system.
/// Pauses on battery below 20%, in Low Power Mode, or at serious thermal state.
public struct SystemPowerMonitor: PowerMonitoring {
    public var minimumBatteryPercent: Int

    public init(minimumBatteryPercent: Int = 20) {
        self.minimumBatteryPercent = minimumBatteryPercent
    }

    public func pauseReason() -> PauseReason? {
        let info = ProcessInfo.processInfo
        if info.thermalState == .serious || info.thermalState == .critical { return .thermal }
        if info.isLowPowerModeEnabled { return .lowPowerMode }
        if let battery = batteryState(), !battery.onAC, battery.percent < minimumBatteryPercent { return .lowBattery }
        return nil
    }

    public var isOnBattery: Bool { batteryState().map { !$0.onAC } ?? false }

    private func batteryState() -> (percent: Int, onAC: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let current = description[kIOPSCurrentCapacityKey] as? Int,
                let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return (current * 100 / maximum, onAC)
        }
        return nil  // Desktop Macs have no battery.
    }
}

/// A fixed answer, for tests.
public struct FixedPowerMonitor: PowerMonitoring {
    public var reason: PauseReason?
    public var isOnBattery: Bool

    public init(reason: PauseReason? = nil, isOnBattery: Bool = false) {
        self.reason = reason
        self.isOnBattery = isOnBattery
    }

    public func pauseReason() -> PauseReason? { reason }
}
