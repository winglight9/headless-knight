import Foundation

/// Global switch for destructive operations. `HKM_DRY_RUN=1` turns every write
/// into a log line so the whole flow can be exercised on a live machine.
public enum DryRun {
    public static let environmentKey = "HKM_DRY_RUN"

    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
    }

    public static func log(_ message: String) {
        HKMLog.info("[dry-run] \(message)")
    }
}

public enum HKMLog {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let lock = NSLock()

    /// 从 Finder / LaunchAgent 启动时 stderr 不会落到任何地方，无头机出了事就
    /// 一点线索都没有。日志必须落盘。
    public static var logFileURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("HeadlessKnightMaster", isDirectory: true)
            .appendingPathComponent("app.log")
    }

    /// 超过这个大小就滚动一次，避免无限增长。
    private static let maxBytes = 2 * 1024 * 1024

    public static func info(_ message: String) {
        write("INFO", message)
    }

    public static func error(_ message: String) {
        write("ERROR", message)
    }

    private static func write(_ level: String, _ message: String) {
        let line = "[hkm][\(level)] \(formatter.string(from: Date())) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
        // 跑测试的时候不许写进用户真实的 app.log。
        //
        // 测试里的 AppState 会照常调 HKMLog，一次 `swift test` 就能往日志里灌进
        // 几十行「请求系统睡眠」「锁定设置 ✓」——全是假的。真机出问题去翻日志时，
        // 这些假记录会把人带偏（已经带偏过一次）。
        guard !isRunningTests else { return }
        appendToFile(line)
    }

    /// 当前进程是不是测试运行器。
    ///
    /// `swift test` 用的是 SwiftPM 的 `swiftpm-testing-helper`，`Bundle.main` 指到
    /// `/Library/Developer/CommandLineTools/usr/libexec/swift/pm`——既不是 `.xctest`
    /// 包，进程名也不带 PackageTests。Xcode 里跑则是 `xctest`。两种都认。
    private static var isRunningTests: Bool {
        let process = ProcessInfo.processInfo.processName
        if process == "swiftpm-testing-helper" || process == "xctest" { return true }
        if Bundle.main.bundlePath.contains(".xctest") { return true }
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static func appendToFile(_ line: String) {
        let url = logFileURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } else if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            let rotated = url.deletingLastPathComponent().appendingPathComponent("app.log.1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: url, to: rotated)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
