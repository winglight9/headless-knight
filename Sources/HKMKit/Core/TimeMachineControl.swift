import Foundation

/// Pausing Time Machine while away.
///
/// Time Machine 只是「少醒几次」的优化项，不是「能不能睡」的关键项，所以这里
/// 的每一步都不允许失败到中断流程。另外 `tmutil disable` 需要 Full Disk Access，
/// 那是 root 也绕不过的 TCC 保护，代码申请不到，只能如实记一笔然后继续走。
public struct TimeMachineControl: Sendable {
    private let runner: any CommandRunning
    private let executor: any PrivilegedExecuting

    public init(runner: any CommandRunning = ShellRunner(), executor: any PrivilegedExecuting = PrivilegedExecutorFactory.make()) {
        self.runner = runner
        self.executor = executor
    }

    /// nil when the preference cannot be read.
    public func isEnabled() async -> Bool? {
        await offMain { self.isEnabledSync() }
    }

    /// `defaults` + `tmutil` 都是同步子进程，界面路径走 async 版本。
    public func isEnabledSync() -> Bool? {
        if let explicit = readAutoBackup() {
            return explicit
        }
        return hasDestinations()
    }

    /// `AutoBackup` 只在用户开过备份之后才写进偏好文件；键不存在不代表读不到。
    private func readAutoBackup() -> Bool? {
        guard let result = try? runner.run("/usr/bin/defaults", arguments: [
            "read", "/Library/Preferences/com.apple.TimeMachine", "AutoBackup"
        ]), result.succeeded else {
            return nil
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "1" || value == "true" || value == "yes" { return true }
        if value == "0" || value == "false" || value == "no" { return false }
        return nil
    }

    /// 没有备份目标就等于没有开备份，这是 macOS 15 上唯一可靠的判断依据。
    private func hasDestinations() -> Bool? {
        guard let result = try? runner.run("/usr/bin/tmutil", arguments: ["destinationinfo"], timeout: 10) else {
            return nil
        }
        return TimeMachineControl.parseDestinationInfo(result.stdout + result.stderr)
    }

    public static func parseDestinationInfo(_ text: String) -> Bool? {
        if text.contains("No destinations configured") {
            return false
        }
        if text.contains("Name :") || text.contains("Name:") {
            return true
        }
        return nil
    }

    /// 取消备份的结果。
    ///
    /// `didDisable` 才是恢复时该看的依据：没关过就绝不能反过来把用户的备份打开。
    public struct PauseOutcome: Sendable, Equatable {
        public let didDisable: Bool
        public let failure: FailedItem?

        public init(didDisable: Bool, failure: FailedItem? = nil) {
            self.didDisable = didDisable
            self.failure = failure
        }
    }

    /// 没开备份、或读不出状态，就什么都不做——跳过不是失败。
    public func disable() async -> PauseOutcome {
        guard await isEnabled() == true else {
            return PauseOutcome(didDisable: false)
        }
        do {
            _ = try await executor.perform(.timeMachineDisable)
            return PauseOutcome(didDisable: true)
        } catch {
            HKMLog.error(L("暂停 Time Machine 失败：{0}", error.localizedDescription))
            return PauseOutcome(
                didDisable: false,
                failure: FailedItem(title: "Time Machine", error: error, severity: .optional)
            )
        }
    }

    /// 只有 `disable()` 真的关过才调用，调用方用 snapshot 里的记录判断。
    public func enable() async -> FailedItem? {
        do {
            _ = try await executor.perform(.timeMachineEnable)
            return nil
        } catch {
            HKMLog.error(L("恢复 Time Machine 失败：{0}", error.localizedDescription))
            return FailedItem(title: "恢复 Time Machine", error: error, severity: .optional)
        }
    }
}
