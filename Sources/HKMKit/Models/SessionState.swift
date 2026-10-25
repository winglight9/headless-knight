import Foundation

public enum SessionPhase: String, Codable, Sendable {
    /// Not away.
    case home
    /// Away mode is active and the log has not been audited yet.
    case away
    /// Away mode was audited but the report has not been acknowledged, so the
    /// snapshot still needs to be restored. Added on top of design doc 7.1 so a
    /// restart between "统计" and "知道了" does not lose the restore step.
    case audited
    /// 恢复原样失败，快照还欠着。这个状态下**不能**开始新的外出——否则新快照
    /// 会把已经被改过的 pmset 当成用户的原始设置，从此再也恢复不回来。
    case needsRestore
}

/// Contents of `~/Library/Application Support/HeadlessKnightMaster/state.json`.
public struct SessionState: Codable, Sendable, Equatable {
    public var phase: SessionPhase
    public var startedAt: Date
    public var timeZoneOffsetMinutes: Int
    public var logAnchor: String
    public var batteryStart: Int?
    /// 外出期间见过的最低电量。
    ///
    /// 只记「开始」和「结束」是不够的：用户回来第一件事往往是插上电源，
    /// 等他把「结束外出模式」点下去，电池可能已经充回去了。2026-10-25 那趟
    /// 睡了一夜掉 2%（98%→96%），报告里却因为结束时又充到 98% 写成「没有下降」。
    public var batteryLow: Int?
    public var bootTimeAtStart: TimeInterval
    public var displayDetachedAt: Date?
    public var snapshot: Snapshot
    public var lastReport: Report?
    /// 我们最后一次「命令系统睡觉」的时刻。用来回答「叫它睡它到底睡没睡」。
    public var sleepRequestedAt: Date?

    public init(
        phase: SessionPhase,
        startedAt: Date,
        timeZoneOffsetMinutes: Int,
        logAnchor: String,
        batteryStart: Int? = nil,
        batteryLow: Int? = nil,
        bootTimeAtStart: TimeInterval = 0,
        displayDetachedAt: Date? = nil,
        snapshot: Snapshot = Snapshot(),
        lastReport: Report? = nil,
        sleepRequestedAt: Date? = nil
    ) {
        self.phase = phase
        self.startedAt = startedAt
        self.timeZoneOffsetMinutes = timeZoneOffsetMinutes
        self.logAnchor = logAnchor
        self.batteryStart = batteryStart
        self.batteryLow = batteryLow ?? batteryStart
        self.bootTimeAtStart = bootTimeAtStart
        self.displayDetachedAt = displayDetachedAt
        self.snapshot = snapshot
        self.lastReport = lastReport
        self.sleepRequestedAt = sleepRequestedAt
    }

    public var startedAtUTC: Date { startedAt }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public var onboardingDone: Bool
    public var launchAtLogin: Bool
    public var sleepDelaySeconds: Int
    /// 增强模式：外出期间机器连续醒着满 5 分钟，就强制它再睡一次。
    ///
    /// **默认开。** 它兜的是「没人管、也没人通知你、但有东西一直挡着不让睡」——
    /// 用户不需要先看懂这句话才敢开，那本身就是设计失败。
    /// 老版本 settings.json 里显式存着 `false` 的，照旧是关，不替用户改主意。
    public var strongMode: Bool
    /// 这台机器物理上没有内建屏（拆掉了）。
    ///
    /// macOS 不知道屏幕被拆了，照样报一块「内建屏」上线，EDID 尺寸型号全是正常的
    /// （真机抓到的假内建屏：1512x982 / v1552 / m41038 / s4251086178，和真的没区别）。
    /// 程序没法从参数上分辨真假，只能问用户。
    ///
    /// 勾上之后，「内建屏在线」不再被当成「人在电脑前」，拔线就走。
    public var noBuiltinDisplay: Bool

    public init(
        onboardingDone: Bool = false,
        launchAtLogin: Bool = false,
        sleepDelaySeconds: Int = 5,
        strongMode: Bool = true,
        noBuiltinDisplay: Bool = false
    ) {
        self.onboardingDone = onboardingDone
        self.launchAtLogin = launchAtLogin
        self.sleepDelaySeconds = sleepDelaySeconds
        self.strongMode = strongMode
        self.noBuiltinDisplay = noBuiltinDisplay
    }

    private enum CodingKeys: String, CodingKey {
        case onboardingDone, launchAtLogin, sleepDelaySeconds, strongMode, noBuiltinDisplay
    }

    /// 老版本写下的 settings.json 里没有 `strongMode`。合成解码遇到缺字段会直接
    /// 抛错，整份设置（包括开机自启、拔线等待）都会被退回默认值——所以这里逐个
    /// `decodeIfPresent`，新增字段永远读成默认值而不是把旧设置弄丢。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        onboardingDone = try container.decodeIfPresent(Bool.self, forKey: .onboardingDone) ?? false
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        sleepDelaySeconds = try container.decodeIfPresent(Int.self, forKey: .sleepDelaySeconds) ?? 5
        strongMode = try container.decodeIfPresent(Bool.self, forKey: .strongMode) ?? true
        noBuiltinDisplay = try container.decodeIfPresent(Bool.self, forKey: .noBuiltinDisplay) ?? false
    }

    public static let `default` = AppSettings()
}
