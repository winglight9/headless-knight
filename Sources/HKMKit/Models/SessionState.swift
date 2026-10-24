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
    /// 强力模式：外出期间机器一直醒着（累计满 10 分钟）就强制它再睡一次。
    /// 默认关——它会在用户其实在电脑前的时候打断工作，必须自己勾。
    public var strongMode: Bool

    public init(
        onboardingDone: Bool = false,
        launchAtLogin: Bool = false,
        sleepDelaySeconds: Int = 5,
        strongMode: Bool = false
    ) {
        self.onboardingDone = onboardingDone
        self.launchAtLogin = launchAtLogin
        self.sleepDelaySeconds = sleepDelaySeconds
        self.strongMode = strongMode
    }

    private enum CodingKeys: String, CodingKey {
        case onboardingDone, launchAtLogin, sleepDelaySeconds, strongMode
    }

    /// 老版本写下的 settings.json 里没有 `strongMode`。合成解码遇到缺字段会直接
    /// 抛错，整份设置（包括开机自启、拔线等待）都会被退回默认值——所以这里逐个
    /// `decodeIfPresent`，新增字段永远读成默认值而不是把旧设置弄丢。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        onboardingDone = try container.decodeIfPresent(Bool.self, forKey: .onboardingDone) ?? false
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        sleepDelaySeconds = try container.decodeIfPresent(Int.self, forKey: .sleepDelaySeconds) ?? 5
        strongMode = try container.decodeIfPresent(Bool.self, forKey: .strongMode) ?? false
    }

    public static let `default` = AppSettings()
}
