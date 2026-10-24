import Foundation

/// The six pmset keys the app snapshots and restores.
public struct PmsetSnapshot: Codable, Sendable, Equatable {
    public static let trackedKeys = ["disablesleep", "sleep", "womp", "powernap", "tcpkeepalive", "standby"]

    public var values: [String: Int]

    public init(values: [String: Int] = [:]) {
        self.values = values
    }

    public subscript(key: String) -> Int? {
        get { values[key] }
        set { values[key] = newValue }
    }

    public var isComplete: Bool {
        PmsetSnapshot.trackedKeys.allSatisfy { values[$0] != nil }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        values = try container.decode([String: Int].self)
    }
}

/// Everything captured before entering away mode so it can be put back later.
public struct Snapshot: Codable, Sendable, Equatable {
    public var bluetoothPower: Int?
    public var pmset: PmsetSnapshot
    public var timeMachineEnabled: Bool?
    public var sharing: [String]
    public var terminatedApps: [String]
    public var scheduledWake: [String]
    public var failedItems: [String]

    public init(
        bluetoothPower: Int? = nil,
        pmset: PmsetSnapshot = PmsetSnapshot(),
        timeMachineEnabled: Bool? = nil,
        sharing: [String] = [],
        terminatedApps: [String] = [],
        scheduledWake: [String] = [],
        failedItems: [String] = []
    ) {
        self.bluetoothPower = bluetoothPower
        self.pmset = pmset
        self.timeMachineEnabled = timeMachineEnabled
        self.sharing = sharing
        self.terminatedApps = terminatedApps
        self.scheduledWake = scheduledWake
        self.failedItems = failedItems
    }

    /// Used when the state file is missing or corrupt: bring services back on,
    /// which is the safe direction for a machine that has to be reachable.
    ///
    /// `timeMachineEnabled` 例外，留 nil：这一项记的是「我们关过没有」，状态丢了
    /// 就无从得知，贸然调 `tmutil enable` 会把用户本来关着的备份打开。
    public static var safeDefaults: Snapshot {
        Snapshot(
            bluetoothPower: 1,
            pmset: PmsetSnapshot(),
            timeMachineEnabled: nil,
            sharing: [],
            terminatedApps: [],
            scheduledWake: [],
            failedItems: []
        )
    }
}

/// One item that could not be completed.
///
/// `severity` decides whether the failure is allowed to stop the user from
/// leaving: only items that change *whether the machine can sleep* may block.
/// Everything else only changes *how often it wakes up*, and blocking on those
/// would make the user think the trip is doomed when it is not.
public struct FailedItem: Codable, Sendable, Equatable, Identifiable {
    public enum Severity: String, Codable, Sendable {
        /// 决定「能不能睡」：退出占睡进程、关闭蓝牙、pmset 各项。
        case critical
        /// 只决定「少醒几次」：Time Machine、共享服务、定时唤醒任务。
        case optional
    }

    public var id: String { "\(title)|\(detail)" }
    public let title: String
    /// 已经人话化，可以直接显示给用户。
    public let detail: String
    public let severity: Severity

    public init(title: String, detail: String, severity: Severity = .critical) {
        self.title = title
        self.detail = detail
        self.severity = severity
    }

    /// 从底层错误构造，自动把 shell 原文翻译成人话。
    public init(title: String, error: Error, severity: Severity = .critical) {
        self.init(
            title: title,
            detail: FailureText.humanize(error.localizedDescription, severity: severity),
            severity: severity
        )
    }

    public var isCritical: Bool { severity == .critical }

    public var summary: String { "\(title)：\(detail)" }

    /// 「可以拔掉显示器了」那一页用的小字，交代不影响睡眠的遗漏。
    public var optionalNote: String { "\(title) 未完成（不影响睡眠）" }

    private enum CodingKeys: String, CodingKey {
        case title, detail, severity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decode(String.self, forKey: .detail)
        // 老的状态文件没有这个字段，按最保守的 critical 处理。
        severity = try container.decodeIfPresent(Severity.self, forKey: .severity) ?? .critical
    }
}
