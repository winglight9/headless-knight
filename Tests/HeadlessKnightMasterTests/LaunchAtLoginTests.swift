import Foundation
import Testing

@testable import HeadlessKnightMaster
@testable import HKMKit

// MARK: - 开机自启
//
// 用户报的现场：点一下「开机自启」，菜单栏冒出两个图标。
//
// 原因是 `enable()` 里除了写 plist 还调了 `launchctl bootstrap`，而 agent 是
// `RunAtLoad` 的——bootstrap 会**当场把它加载起来**，于是第二个实例立刻被拉起。
// 反过来的 `bootout` 一样危险：如果当前进程本来就是登录时被这个 agent 拉起的，
// 关掉自启会把软件自己关掉。
//
// 正确做法：只写/删 `~/Library/LaunchAgents` 里的 plist。launchd 在每次登录时
// 自己会加载它，这就是「开机自启」的定义。

private final class RecordingRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        lock.lock(); recorded.append(executable + " " + arguments.joined(separator: " ")); lock.unlock()
        return CommandResult(status: 0, stdout: "", stderr: "")
    }

    func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        try run(executable, arguments: arguments, timeout: 20)
    }
}

private func makeTempHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("hkm-login-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("开机自启只动文件，不动 launchd")
struct LaunchAtLoginTests {
    @Test("开启自启：写 plist，一次 launchctl 都不调")
    func enableOnlyWritesPlist() throws {
        let home = try makeTempHome()
        let runner = RecordingRunner()
        let login = LaunchAtLogin(home: home, runner: runner)
        let path = "/Applications/Knight.app/Contents/MacOS/Knight"

        try login.enable(executablePath: path)

        #expect(login.isEnabled())
        #expect(runner.calls.isEmpty)
        let text = try String(contentsOf: login.plistURL, encoding: .utf8)
        #expect(text.contains(path))
        #expect(text.contains("RunAtLoad"))
    }

    @Test("关闭自启：删 plist，同样不 bootout（否则会把自己关掉）")
    func disableOnlyRemovesPlist() throws {
        let home = try makeTempHome()
        let runner = RecordingRunner()
        let login = LaunchAtLogin(home: home, runner: runner)

        try login.enable(executablePath: "/Applications/Knight.app/Contents/MacOS/Knight")
        try login.disable()

        #expect(!login.isEnabled())
        #expect(runner.calls.isEmpty)
    }

    @Test("改名之后路径过期：只改文件里的路径，不重载 job")
    func rewritesStalePath() throws {
        let home = try makeTempHome()
        let runner = RecordingRunner()
        let login = LaunchAtLogin(home: home, runner: runner)

        try login.enable(executablePath: "/Applications/HeadlessKnightMaster.app/Contents/MacOS/HeadlessKnightMaster")
        login.rewriteIfNeeded(executablePath: "/Applications/Knight.app/Contents/MacOS/Knight")

        let text = try String(contentsOf: login.plistURL, encoding: .utf8)
        #expect(text.contains("/Applications/Knight.app/Contents/MacOS/Knight"))
        #expect(text.contains("HeadlessKnightMaster") == false)
        #expect(runner.calls.isEmpty)
    }

    @Test("没开自启时，rewrite 什么都不做（不该凭空造出一个自启项）")
    func rewriteDoesNothingWhenDisabled() throws {
        let home = try makeTempHome()
        let login = LaunchAtLogin(home: home, runner: RecordingRunner())

        login.rewriteIfNeeded(executablePath: "/Applications/Knight.app/Contents/MacOS/Knight")

        #expect(!login.isEnabled())
    }
}
