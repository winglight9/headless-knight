import Foundation

/// One thing that is currently preventing the machine from sleeping.
///
/// `pid` always points at the process the user has to quit: when coreaudiod
/// holds an assertion on behalf of Chrome, `pid` is Chrome's and
/// `proxyOwnerPID` is coreaudiod's.
public struct SleepBlocker: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Keeps the system awake.
        case blocking
        /// Keeps only the display awake.
        case displayOnly
    }

    public var id: pid_t { pid }

    public let pid: pid_t
    public let processName: String
    public let bundleIdentifier: String?
    public let assertionTypes: [String]
    public let assertionNames: [String]
    public let durationSeconds: Int
    public let proxyOwnerPID: pid_t?
    public let proxyOwnerName: String?
    public let isSystemProcess: Bool
    public let kind: Kind
    /// Every process that has to go. Chrome shows up once per process in
    /// `pmset -g assertions`; the user should still see one row called Chrome.
    public let groupedPIDs: [pid_t]

    public init(
        pid: pid_t,
        processName: String,
        bundleIdentifier: String? = nil,
        assertionTypes: [String] = [],
        assertionNames: [String] = [],
        durationSeconds: Int = 0,
        proxyOwnerPID: pid_t? = nil,
        proxyOwnerName: String? = nil,
        isSystemProcess: Bool = false,
        kind: Kind = .blocking,
        groupedPIDs: [pid_t]? = nil
    ) {
        self.pid = pid
        self.processName = processName
        self.bundleIdentifier = bundleIdentifier
        self.assertionTypes = assertionTypes
        self.assertionNames = assertionNames
        self.durationSeconds = durationSeconds
        self.proxyOwnerPID = proxyOwnerPID
        self.proxyOwnerName = proxyOwnerName
        self.isSystemProcess = isSystemProcess
        self.kind = kind
        self.groupedPIDs = groupedPIDs ?? [pid]
    }

    public var allPIDs: [pid_t] {
        groupedPIDs.isEmpty ? [pid] : groupedPIDs
    }

    /// True when the assertion was created by an audio client, which is the
    /// only case the UI describes by reason instead of by duration.
    public var isAudioAssertion: Bool {
        assertionNames.contains { $0.lowercased().contains("audio") }
            || assertionNames.contains { $0.lowercased().contains("playing") }
    }

    /// 「已持续多久 / 正在放音频」。报告和 `--diagnose` 用它；
    /// 检测页改用 `explanation`，因为用户更想知道「它挡了什么、怎么关」。
    public var detailText: String {
        if isAudioAssertion {
            return "正在放音频"
        }
        return DurationFormatter.compact(seconds: durationSeconds)
    }

    /// 检测页那两句话。
    public var explanation: BlockerExplanation {
        BlockerExplainer.explain(self)
    }

    /// Technical one-liner shown behind 「查看详情」.
    public var technicalDescription: String {
        var parts: [String] = ["pid \(pid)"]
        if let bundleIdentifier {
            parts.append(bundleIdentifier)
        }
        if let proxyOwnerName, let proxyOwnerPID {
            parts.append("断言由 \(proxyOwnerName)(\(proxyOwnerPID)) 代持")
        }
        if !assertionTypes.isEmpty {
            parts.append(assertionTypes.joined(separator: " / "))
        }
        parts.append("已持续 \(DurationFormatter.humanized(seconds: durationSeconds))")
        return parts.joined(separator: " · ")
    }
}

/// A wake event the user should know about, produced by `WakeAuditor`.
public struct WakeEvent: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case dark
        case notification
        case real
    }

    public var id: String { "\(at.timeIntervalSince1970)-\(kind.rawValue)" }

    public let at: Date
    public let kind: Kind
    public let reason: String
    public let durationSeconds: Int

    public init(at: Date, kind: Kind, reason: String, durationSeconds: Int) {
        self.at = at
        self.kind = kind
        self.reason = reason
        self.durationSeconds = durationSeconds
    }

    public var timeText: String { ClockFormatter.timeOfDay(at) }

    public var durationText: String { DurationFormatter.wakeDuration(seconds: durationSeconds) }

    /// "14:32 · 屏幕亮了 2 分钟"
    public var headlineText: String {
        if durationSeconds > 0 {
            return "\(timeText) · 屏幕亮了 \(durationText)"
        }
        return "\(timeText) · \(reason)"
    }
}
