import Foundation
import IOKit.ps

/// Батарея (§9 Фаза 5): IOPSCopyPowerSourcesInfo → List → Description.
enum PowerSource {

    /// nil — батареи нет (десктоп/БП без данных); иначе (на батарее?, процент).
    static func batteryStatus() -> (onBattery: Bool, percent: Int)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        var result: (Bool, Int)?
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(info, ps)?
                .takeUnretainedValue() as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int,
                  max > 0
            else { continue }
            let state = desc[kIOPSPowerSourceStateKey] as? String
            let onBattery = state == kIOPSBatteryPowerValue
            let percent = Int((Double(current) / Double(max)) * 100)
            result = (onBattery, percent)
        }
        return result
    }
}
