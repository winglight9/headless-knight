import Foundation

public enum SystemInfo {
    /// `kern.boottime` as a unix timestamp.
    public static func bootTime() -> TimeInterval {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var timeValue = timeval()
        var size = MemoryLayout<timeval>.size
        let result = sysctl(&mib, u_int(mib.count), &timeValue, &size, nil, 0)
        guard result == 0 else { return 0 }
        return TimeInterval(timeValue.tv_sec) + TimeInterval(timeValue.tv_usec) / 1_000_000
    }

    public static func displayCount() -> Int {
        DisplayWatcher.activeDisplayCount()
    }

    public static func currentTimeZoneOffsetMinutes() -> Int {
        TimeZone.current.secondsFromGMT() / 60
    }

    public static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("HeadlessKnightMaster", isDirectory: true)
    }
}
