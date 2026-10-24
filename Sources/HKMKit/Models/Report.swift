import Foundation

public struct Suggestion: Codable, Sendable, Equatable {
    public let text: String
    /// False for facts we cannot act on (a key press, a hardware wake).
    public let isActionable: Bool

    public init(text: String, isActionable: Bool) {
        self.text = text
        self.isActionable = isActionable
    }
}

/// The report produced when away mode ends. Field names mirror design doc 7.3.
public struct Report: Codable, Sendable, Equatable {
    public var startedAt: Date
    public var endedAt: Date
    public var durationSeconds: Int
    public var batteryStart: Int?
    public var batteryEnd: Int?
    public var sleptAtAll: Bool
    public var darkWakeCount: Int
    public var notificationWakeCount: Int
    public var realWakeCount: Int
    public var realWakes: [WakeEvent]
    public var rebooted: Bool
    public var failedItems: [String]

    public init(
        startedAt: Date,
        endedAt: Date,
        durationSeconds: Int,
        batteryStart: Int? = nil,
        batteryEnd: Int? = nil,
        sleptAtAll: Bool,
        darkWakeCount: Int,
        notificationWakeCount: Int,
        realWakeCount: Int,
        realWakes: [WakeEvent] = [],
        rebooted: Bool = false,
        failedItems: [String] = []
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.batteryStart = batteryStart
        self.batteryEnd = batteryEnd
        self.sleptAtAll = sleptAtAll
        self.darkWakeCount = darkWakeCount
        self.notificationWakeCount = notificationWakeCount
        self.realWakeCount = realWakeCount
        self.realWakes = realWakes
        self.rebooted = rebooted
        self.failedItems = failedItems
    }

    public var backgroundWakeCount: Int { darkWakeCount + notificationWakeCount }

    public var batteryDelta: Int? {
        guard let start = batteryStart, let end = batteryEnd else { return nil }
        return start - end
    }

    public var hasAnomaly: Bool { !sleptAtAll || realWakeCount > 0 }

    /// First line of the report — a conclusion, never a status list.
    public var headline: String {
        if !sleptAtAll {
            return "这次没睡成"
        }
        if realWakeCount > 0 {
            return "被唤醒 \(realWakeCount) 次"
        }
        return "这次很干净"
    }

    public var durationText: String { DurationFormatter.humanized(seconds: durationSeconds) }

    /// "电量 74% · 下降 4%"
    public var batteryText: String {
        guard let end = batteryEnd else {
            return "外出期间电量耗尽"
        }
        guard let delta = batteryDelta else {
            return "电量 \(end)%"
        }
        if delta <= 0 {
            return "电量 \(end)% · 没有下降"
        }
        return "电量 \(end)% · 下降 \(delta)%"
    }

    /// Compact variant used under the headline on the anomaly screen.
    public var secondaryBatteryText: String {
        guard let delta = batteryDelta, delta > 0 else {
            return "共 \(durationText)"
        }
        return "共 \(durationText) · 下降 \(delta)%"
    }

    public var firstRealWakeText: String? {
        realWakes.first?.headlineText
    }

    /// Design doc 5.1: only suggest things software can still change.
    public var suggestion: Suggestion? {
        if !sleptAtAll {
            return Suggestion(text: "这次没睡成，有程序一直在阻止睡眠", isActionable: true)
        }
        guard let wake = realWakes.first else { return nil }
        let reason = wake.reason.lowercased()

        if reason.contains("usb-c_plug") || reason.contains("usb") || reason.contains("dock") || reason.contains("smc.") {
            return Suggestion(text: "扩展坞供电波动唤醒了机器，走之前拔掉坞", isActionable: true)
        }
        if reason.contains("network") || reason.contains("en0") || reason.contains("magicwake") {
            return Suggestion(text: "已关闭网络唤醒，仍被局域网设备叫醒", isActionable: true)
        }
        if reason.contains("maintenance") || reason.contains("rtc") || reason.contains("sleepservice") {
            return Suggestion(text: "系统维护唤醒，可在设置里彻底关闭", isActionable: true)
        }
        if reason.contains("keyboard") || reason.contains("hid") || reason.contains("trackpad") {
            return Suggestion(text: "\(wake.timeText) 键盘被按下", isActionable: false)
        }
        if reason.contains("useractivity") {
            return Suggestion(text: "\(wake.timeText) 有人动了机器", isActionable: false)
        }
        if reason.contains("notification") {
            return Suggestion(text: "\(wake.timeText) 来了通知，屏幕亮了一下", isActionable: false)
        }
        return Suggestion(text: "\(wake.timeText) 被 \(wake.reason) 唤醒", isActionable: false)
    }
}
