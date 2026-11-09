import Foundation
import IOKit.ps

/// Whether reading many files now is all right for the Mac: on power (or on battery if the user allows it), not in
/// Low Power Mode, not hot. New files are read regardless (a few at a time); this governs the long first pass.
public enum Power {
    public static var onAC: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }

    /// What keeps it from being all right, named as luoke-core names its own reasons (`GET /tasks` → `background`):
    /// "battery", "low_power", "thermal". Empty: it is.
    public static func held(onBattery: Bool) -> [String] {
        let process = ProcessInfo.processInfo
        var reasons: [String] = []
        if !onBattery && !onAC { reasons.append("battery") }
        if process.isLowPowerModeEnabled { reasons.append("low_power") }
        if process.thermalState != .nominal && process.thermalState != .fair { reasons.append("thermal") }
        return reasons
    }
}
