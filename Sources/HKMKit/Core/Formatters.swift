import Foundation

public enum DurationFormatter {
    /// "5 小时 22 分" / "48 分钟" / "37 秒"
    public static func humanized(seconds: Int) -> String {
        let total = max(0, seconds)
        if total < 60 {
            return L("{0} 秒", total)
        }
        let minutes = total / 60
        if minutes < 60 {
            return L("{0} 分钟", minutes)
        }
        let hours = minutes / 60
        let remainder = minutes % 60
        if remainder == 0 {
            return L("{0} 小时", hours)
        }
        return L("{0} 小时 {1} 分", hours, remainder)
    }

    /// Compact form used inside lists: "49 小时" / "2 分钟" / "刚刚"
    public static func compact(seconds: Int) -> String {
        let total = max(0, seconds)
        if total < 60 {
            return L("刚刚")
        }
        let minutes = total / 60
        if minutes < 60 {
            return L("{0} 分钟", minutes)
        }
        return L("{0} 小时", minutes / 60)
    }

    /// "2 分钟" style used for wake durations ("屏幕亮了 2 分钟").
    public static func wakeDuration(seconds: Int) -> String {
        let total = max(0, seconds)
        if total < 60 {
            return L("{0} 秒", total)
        }
        return L("{0} 分钟", total / 60)
    }
}

public enum ClockFormatter {
    /// "14:32"
    public static func timeOfDay(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

public enum PowerLogDateFormatter {
    /// "2026-10-22 13:33:12 +0800" — the exact format `pmset -g log` emits.
    public static func make() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }

    public static func string(from date: Date) -> String {
        make().string(from: date)
    }

    public static func date(from string: String) -> Date? {
        make().date(from: string.trimmingCharacters(in: .whitespaces))
    }
}

public enum ISO8601OffsetFormatter {
    /// "2026-10-23T21:00:00+08:00" — used by the state file.
    public static func make() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return formatter
    }

    public static func string(from date: Date) -> String {
        make().string(from: date)
    }

    public static func date(from string: String) -> Date? {
        make().date(from: string)
    }
}
