import Foundation

/// One interesting line from `pmset -g log`.
public struct WakeLogEntry: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// 行首 DarkWake + "DarkWake from"
        case darkWakeStart
        /// 行首 Wake + "DarkWake to FullWake" / "Wake from Normal Sleep"
        case fullWake
        /// 行首 Sleep + "Entering Sleep"
        case sleepEnter
        /// 行首 Sleep + "Entering DarkWake state"
        case darkWakeExit
    }

    public let at: Date
    public let kind: Kind
    public let reason: String?
    public let durationSeconds: Int?
    public let raw: String

    public init(at: Date, kind: Kind, reason: String?, durationSeconds: Int?, raw: String) {
        self.at = at
        self.kind = kind
        self.reason = reason
        self.durationSeconds = durationSeconds
        self.raw = raw
    }
}

public struct AuditResult: Sendable, Equatable {
    public var sleptAtAll: Bool
    public var sleepStart: Date?
    public var darkWakeCount: Int
    public var notificationWakeCount: Int
    public var realWakeCount: Int
    public var realWakes: [WakeEvent]
    public var allWakes: [WakeEvent]
    public var excludedWakes: [WakeEvent]
    public var lastWakeAt: Date?

    public init(
        sleptAtAll: Bool = false,
        sleepStart: Date? = nil,
        darkWakeCount: Int = 0,
        notificationWakeCount: Int = 0,
        realWakeCount: Int = 0,
        realWakes: [WakeEvent] = [],
        allWakes: [WakeEvent] = [],
        excludedWakes: [WakeEvent] = [],
        lastWakeAt: Date? = nil
    ) {
        self.sleptAtAll = sleptAtAll
        self.sleepStart = sleepStart
        self.darkWakeCount = darkWakeCount
        self.notificationWakeCount = notificationWakeCount
        self.realWakeCount = realWakeCount
        self.realWakes = realWakes
        self.allWakes = allWakes
        self.excludedWakes = excludedWakes
        self.lastWakeAt = lastWakeAt
    }
}

/// Pure text-in / events-out log auditor. No IO here so it stays testable.
public struct WakeAuditor: Sendable {
    /// A wake this close to the end of the session is the user plugging the
    /// display back in, not a real disturbance.
    public static let tailExclusionWindow: TimeInterval = 120
    /// Anything within ±60s of the display detach is our own plug event.
    public static let detachExclusionWindow: TimeInterval = 60

    public init() {}

    // MARK: - Parsing

    public static func parseTimestamp(_ raw: String) -> Date? {
        PowerLogDateFormatter.date(from: raw)
    }

    public static func parse(_ log: String) -> [WakeLogEntry] {
        var entries: [WakeLogEntry] = []
        for line in log.split(separator: "\n", omittingEmptySubsequences: true) {
            if let entry = parseLine(String(line)) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// A power log line looks like:
    /// `2026-10-22 15:49:39 +0800 Wake                \tDarkWake to FullWake ... 2 secs`
    /// The timestamp is a fixed 26 characters, then the domain, then the message.
    public static func parseLine(_ line: String) -> WakeLogEntry? {
        guard line.count > 27 else { return nil }
        let stamp = String(line.prefix(26))
        guard let date = parseTimestamp(stamp) else { return nil }

        let remainder = line.dropFirst(26)
        let domainAndMessage = remainder.drop { $0 == " " || $0 == "\t" }
        let domain = domainAndMessage.prefix { $0 != " " && $0 != "\t" }
        guard !domain.isEmpty else { return nil }
        let message = domainAndMessage.dropFirst(domain.count).trimmingCharacters(in: .whitespaces)

        let kind: WakeLogEntry.Kind
        switch domain {
        case "DarkWake":
            guard message.hasPrefix("DarkWake from") else { return nil }
            kind = .darkWakeStart
        case "Wake":
            // "Wake Requests" and other domains sharing the prefix are ignored.
            if message.hasPrefix("DarkWake to FullWake") || message.hasPrefix("Wake from Normal Sleep") {
                kind = .fullWake
            } else {
                return nil
            }
        case "Sleep":
            if message.hasPrefix("Entering Sleep state") {
                kind = .sleepEnter
            } else if message.hasPrefix("Entering DarkWake state") {
                kind = .darkWakeExit
            } else {
                return nil
            }
        default:
            return nil
        }

        return WakeLogEntry(
            at: date,
            kind: kind,
            reason: extractReason(from: message),
            durationSeconds: extractDuration(from: message),
            raw: line
        )
    }

    /// `due to (.+?) Using`
    static func extractReason(from message: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "due to (.+?) Using", options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = regex.firstMatch(in: message, options: [], range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: message) else {
            return nil
        }
        return String(message[captured]).trimmingCharacters(in: .whitespaces)
    }

    /// Trailing `(\d+) secs`
    static func extractDuration(from message: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "(\\d+)\\s+secs?\\s*$", options: []) else {
            return nil
        }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = regex.firstMatch(in: message, options: [], range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: message) else {
            return nil
        }
        return Int(message[captured])
    }

    // MARK: - Classification

    public static func classify(reason: String?, durationSeconds: Int?) -> WakeEvent.Kind {
        let lowered = (reason ?? "").lowercased()
        if lowered.contains("useractivity") || lowered.contains("hid")
            || lowered.contains("keyboard") || lowered.contains("trackpad") {
            return .real
        }
        if let durationSeconds, durationSeconds >= 5 {
            return .real
        }
        if lowered.contains("notification") {
            return .notification
        }
        // A full wake without a duration still turned the screen on.
        if durationSeconds == nil {
            return .real
        }
        return .notification
    }

    // MARK: - Audit

    public func audit(
        log: String,
        startedAt: Date,
        endedAt: Date,
        displayDetachedAt: Date?
    ) -> AuditResult {
        let entries = WakeAuditor.parse(log).filter { $0.at >= startedAt.addingTimeInterval(-1) && $0.at <= endedAt }

        // 区间起点：startedAt 之后第一条 Entering Sleep
        guard let sleepStart = entries.first(where: { $0.kind == .sleepEnter })?.at else {
            return AuditResult(sleptAtAll: false)
        }

        let inRange = entries.filter { $0.at >= sleepStart }
        var wakes: [WakeEvent] = []
        for entry in inRange {
            switch entry.kind {
            case .darkWakeStart:
                wakes.append(
                    WakeEvent(
                        at: entry.at,
                        kind: .dark,
                        reason: entry.reason ?? "",
                        durationSeconds: entry.durationSeconds ?? 0
                    )
                )
            case .fullWake:
                wakes.append(
                    WakeEvent(
                        at: entry.at,
                        kind: WakeAuditor.classify(reason: entry.reason, durationSeconds: entry.durationSeconds),
                        reason: entry.reason ?? "",
                        durationSeconds: entry.durationSeconds ?? 0
                    )
                )
            case .sleepEnter, .darkWakeExit:
                continue
            }
        }
        wakes.sort { $0.at < $1.at }

        var excluded: [WakeEvent] = []

        // 规则 1：区间内最后一条唤醒，其后没有 Entering Sleep，且距结束 < 120 秒
        if let last = wakes.last {
            let hasSleepAfter = inRange.contains { $0.kind == .sleepEnter && $0.at > last.at }
            if !hasSleepAfter, endedAt.timeIntervalSince(last.at) < WakeAuditor.tailExclusionWindow {
                excluded.append(last)
                wakes.removeLast()
            }
        }

        // 规则 2：发生在显示器接入时间戳 ± 60 秒内
        if let detached = displayDetachedAt {
            var kept: [WakeEvent] = []
            for wake in wakes {
                if abs(wake.at.timeIntervalSince(detached)) <= WakeAuditor.detachExclusionWindow {
                    excluded.append(wake)
                } else {
                    kept.append(wake)
                }
            }
            wakes = kept
        }

        let realWakes = wakes.filter { $0.kind == .real }
        return AuditResult(
            sleptAtAll: true,
            sleepStart: sleepStart,
            darkWakeCount: wakes.filter { $0.kind == .dark }.count,
            notificationWakeCount: wakes.filter { $0.kind == .notification }.count,
            realWakeCount: realWakes.count,
            realWakes: realWakes,
            allWakes: wakes,
            excludedWakes: excluded.sorted { $0.at < $1.at },
            lastWakeAt: wakes.last?.at
        )
    }
}
