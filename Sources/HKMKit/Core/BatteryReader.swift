import Foundation
import IOKit.ps

public struct BatteryStatus: Sendable, Equatable {
    public let percentage: Int
    public let isCharging: Bool
    public let isOnAC: Bool

    public init(percentage: Int, isCharging: Bool, isOnAC: Bool) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.isOnAC = isOnAC
    }
}

public struct BatteryReader: Sendable {
    public init() {}

    public func current() -> BatteryStatus? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            guard let capacity = description[kIOPSCurrentCapacityKey as String] as? Int else { continue }
            let maxCapacity = description[kIOPSMaxCapacityKey as String] as? Int ?? 100
            let percentage = maxCapacity > 0 ? Int((Double(capacity) / Double(maxCapacity) * 100).rounded()) : capacity
            let charging = description[kIOPSIsChargingKey as String] as? Bool ?? false
            let state = description[kIOPSPowerSourceStateKey as String] as? String ?? ""
            return BatteryStatus(
                percentage: percentage,
                isCharging: charging,
                isOnAC: state == (kIOPSACPowerValue as String)
            )
        }
        return nil
    }

    public func percentage() -> Int? {
        current()?.percentage
    }
}
