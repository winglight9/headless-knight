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
    /// 外出期间的最低电量。用户回来之后常常先插上电源再点「结束」，
    /// 那时候 `batteryEnd` 已经充回去了，只看首尾会把「掉电」算成 0。
    public var batteryLow: Int?
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
        batteryLow: Int? = nil,
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
        self.batteryLow = batteryLow
        self.sleptAtAll = sleptAtAll
        self.darkWakeCount = darkWakeCount
        self.notificationWakeCount = notificationWakeCount
        self.realWakeCount = realWakeCount
        self.realWakes = realWakes
        self.rebooted = rebooted
        self.failedItems = failedItems
    }

    public var backgroundWakeCount: Int { darkWakeCount + notificationWakeCount }

    /// 这一段掉了多少电。
    ///
    /// 用「见过的最低电量」而不是「结束时的电量」：用户回来第一件事常常是插电源，
    /// 等到他点「结束外出模式」，电池早就充回去了。2026-10-25 那趟睡了一夜
    /// 98% → 96%（掉 2%），结束时已经充回 98%，只看首尾就写成了「没有下降」。
    public var batteryDelta: Int? {
        guard let start = batteryStart else { return nil }
        let lowest = [batteryEnd, batteryLow].compactMap { $0 }.min()
        guard let lowest else { return nil }
        return start - lowest
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

    /// "掉电 2%"
    ///
    /// 只说掉了多少。以前写「电量 74% · 下降 4%」，那个 74% 是结束那一刻的电量，
    /// 而用户回来常常已经插上电源了，这个数字跟他半夜关心的「一夜掉了多少」无关。
    public var batteryText: String {
        guard let delta = batteryDelta else {
            return batteryEnd == nil ? "外出期间电量耗尽" : "电量未知"
        }
        if delta <= 0 {
            return "没有掉电"
        }
        return "掉电 \(delta)%"
    }

    /// Compact variant used under the headline on the anomaly screen.
    public var secondaryBatteryText: String {
        guard let delta = batteryDelta, delta > 0 else {
            return "共 \(durationText)"
        }
        return "共 \(durationText) · 掉电 \(delta)%"
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
