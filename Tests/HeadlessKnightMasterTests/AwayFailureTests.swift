import Foundation
import Testing

@testable import HKMKit

// MARK: - 测试替身

/// 按可执行文件路径返回预设输出，用来伪造 `defaults` / `tmutil` / `launchctl`。
struct ScriptedRunner: CommandRunning {
    var results: [String: CommandResult] = [:]
    var fallback = CommandResult(status: 1, stdout: "", stderr: "unavailable")

    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        results[executable] ?? fallback
    }

    func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        try run(executable, arguments: arguments, timeout: 20)
    }
}

/// 记录每一次 root 操作的调用，用来断言「不该执行的一次都没执行」。
final class RecordingExecutor: PrivilegedExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HelperOperation] = []
    private let failure: Error?

    init(failure: Error? = nil) {
        self.failure = failure
    }

    var calls: [HelperOperation] {
        lock.withLock { recorded }
    }

    var callCount: Int { calls.count }

    func perform(_ operation: HelperOperation, arguments: [String: String]) async throws -> HelperResponse {
        lock.withLock { recorded.append(operation) }
        if let failure { throw failure }
        return HelperResponse.success(id: "1", output: "", intValue: nil)
    }
}

struct FakeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private let tmutilPath = "/usr/bin/tmutil"
private let defaultsPath = "/usr/bin/defaults"
private let launchctlPath = "/bin/launchctl"

/// 这台机器的真实现场：没有配置任何备份目标。
private var noDestinationRunner: ScriptedRunner {
    ScriptedRunner(results: [
        defaultsPath: CommandResult(status: 1, stdout: "", stderr: "The domain/default pair does not exist"),
        tmutilPath: CommandResult(status: 0, stdout: "tmutil: No destinations configured.\n", stderr: "")
    ])
}

/// 有备份目标、备份也开着。
private var backupEnabledRunner: ScriptedRunner {
    ScriptedRunner(results: [
        defaultsPath: CommandResult(status: 0, stdout: "1\n", stderr: ""),
        tmutilPath: CommandResult(status: 0, stdout: "Name : Time Capsule\n", stderr: "")
    ])
}

// MARK: - 这次的 bug

@Suite("Time Machine 只在真的开过备份时才动手")
struct TimeMachinePreconditionTests {
    @Test("没有备份目标：一次 root 操作都不做，也不算失败")
    func skipsWhenNotConfigured() async {
        let executor = RecordingExecutor()
        let control = TimeMachineControl(runner: noDestinationRunner, executor: executor)

        #expect(control.isEnabled() == false)

        let outcome = await control.disable()

        #expect(outcome.didDisable == false)
        #expect(outcome.failure == nil)
        #expect(executor.callCount == 0)
    }

    @Test("没有备份目标：恢复阶段也不会反过来把备份打开")
    func doesNotEnableWhatItNeverDisabled() async {
        let executor = RecordingExecutor()
        let control = TimeMachineControl(runner: noDestinationRunner, executor: executor)

        let outcome = await control.disable()
        // 调用方的判断依据就是这个字段，必须是 false。
        #expect(outcome.didDisable == false)
        #expect(executor.callCount == 0)
    }

    @Test("备份开着：真的执行一次 disable")
    func disablesWhenConfigured() async {
        let executor = RecordingExecutor()
        let control = TimeMachineControl(runner: backupEnabledRunner, executor: executor)

        #expect(control.isEnabled() == true)

        let outcome = await control.disable()

        #expect(outcome.didDisable == true)
        #expect(outcome.failure == nil)
        #expect(executor.calls == [.timeMachineDisable])
    }

    @Test("Full Disk Access 挡住时：记一条不影响睡眠的失败，流程照常走")
    func fullDiskAccessIsOptional() async {
        let executor = RecordingExecutor(failure: FakeError(message: """
        tmutil: disable requires Full Disk Access privileges.
        To allow this operation, select Full Disk Access in the Privacy tab of the
        Security & Privacy preference pane, and add Terminal to the list of
        applications which are allowed Full Disk Access.
        """))
        let control = TimeMachineControl(runner: backupEnabledRunner, executor: executor)

        let outcome = await control.disable()

        #expect(outcome.didDisable == false)
        #expect(outcome.failure?.severity == .optional)
        #expect(outcome.failure?.detail == "需要额外权限，这一项不影响睡眠")
        #expect(executor.calls == [.timeMachineDisable])
    }
}

// MARK: - 失败分级

@Suite("失败分级决定要不要打断用户")
struct AwayDecisionTests {
    @Test("没有失败就正常继续")
    func proceedsWithoutFailures() {
        let decision = AwayDecision.decide([])
        #expect(decision == .proceed)
        #expect(decision.canProceed)
    }

    @Test("只有优化项失败：照常出门，带一行小字")
    func optionalFailuresDoNotBlock() {
        let items = [
            FailedItem(title: "Time Machine", detail: "需要额外权限，这一项不影响睡眠", severity: .optional),
            FailedItem(title: "共享服务", detail: "操作失败，不影响睡眠", severity: .optional)
        ]
        let decision = AwayDecision.decide(items)
        #expect(decision.canProceed)
        guard case let .proceedWithNotes(notes) = decision else {
            Issue.record("优化项失败不应该进入阻塞页")
            return
        }
        #expect(notes.count == 2)
    }

    @Test("关键项失败：进阻塞页，且只列关键项")
    func criticalFailureBlocks() {
        let items = [
            FailedItem(title: "睡眠设置 womp", detail: "操作失败", severity: .critical),
            FailedItem(title: "Time Machine", detail: "需要额外权限，这一项不影响睡眠", severity: .optional)
        ]
        let decision = AwayDecision.decide(items)
        #expect(!decision.canProceed)
        guard case let .blocked(blocking) = decision else {
            Issue.record("关键项失败必须进入阻塞页")
            return
        }
        #expect(blocking.count == 1)
        #expect(blocking.first?.title == "睡眠设置 womp")
    }

    @Test("默认构造出来的失败项按关键项处理")
    func defaultsToCritical() {
        #expect(FailedItem(title: "蓝牙", detail: "权限不足").isCritical)
    }

    @Test("这次现场的完整失败集合：不阻断")
    func reportedSituationDoesNotBlock() async {
        let executor = RecordingExecutor(failure: FakeError(message: "tmutil: disable requires Full Disk Access privileges."))
        let control = TimeMachineControl(runner: backupEnabledRunner, executor: executor)
        let outcome = await control.disable()

        let failures = [outcome.failure].compactMap { $0 }
        #expect(AwayDecision.decide(failures).canProceed)
    }
}

// MARK: - 错误文案

@Suite("错误文案人话化")
struct FailureTextTests {
    @Test("Full Disk Access 的原文不出现")
    func fullDiskAccess() {
        let raw = "tmutil: disable requires Full Disk Access privileges."
        let optional = FailureText.humanize(raw, severity: .optional)
        #expect(optional == "需要额外权限，这一项不影响睡眠")
        #expect(!optional.lowercased().contains("full disk access"))

        let critical = FailureText.humanize(raw, severity: .critical)
        #expect(critical == "需要额外权限才能完成")
    }

    @Test("权限类错误")
    func permissionErrors() {
        #expect(FailureText.humanize("Operation not permitted", severity: .critical) == "权限不足")
        #expect(FailureText.humanize("Permission denied", severity: .optional) == "权限不足，这一项不影响睡眠")
        #expect(FailureText.humanize("must be run as root", severity: .critical) == "权限不足")
    }

    @Test("未知错误按级别兜底")
    func unknownErrors() {
        #expect(FailureText.humanize("something exploded", severity: .critical) == "操作失败")
        #expect(FailureText.humanize("something exploded", severity: .optional) == "操作失败，不影响睡眠")
    }

    @Test("已经是中文的信息原样保留")
    func keepsHumanMessages() {
        #expect(FailureText.humanize("蓝牙状态没有变化", severity: .critical) == "蓝牙状态没有变化")
    }

    @Test("任何情况下都不把英文原文漏给用户")
    func neverLeaksRawShellText() {
        let raws = [
            "tmutil: disable requires Full Disk Access privileges.",
            "launchctl: Bootout failed: 3: No such process",
            "The domain/default pair of (/Library/Preferences/com.apple.TimeMachine, AutoBackup) does not exist"
        ]
        for raw in raws {
            let text = FailureText.humanize(raw, severity: .optional)
            #expect(!text.contains("tmutil"))
            #expect(!text.contains("launchctl"))
            #expect(!text.contains("domain/default"))
        }
    }
}

// MARK: - 共享服务

@Suite("共享服务只动真的在监听的那些")
struct SharingPreconditionTests {
    @Test("三个服务都没在监听时，一次 root 操作都不做")
    func skipsWhenNothingEnabled() async {
        let netstat = """
        tcp4       0      0  127.0.0.1.631          *.*                    LISTEN
        tcp6       0      0  ::1.631                *.*                    LISTEN
        tcp4       0      0  192.168.1.5.50000      1.1.1.1.443            ESTABLISHED
        """
        let runner = ScriptedRunner(results: [
            "/usr/sbin/netstat": CommandResult(status: 0, stdout: netstat, stderr: "")
        ])
        let executor = RecordingExecutor()
        let control = SharingControl(runner: runner, executor: executor)

        #expect(control.listeningLabels().isEmpty)

        let failures = await control.disableAll()

        #expect(failures.isEmpty)
        #expect(executor.callCount == 0)
    }

    @Test("只有屏幕共享在监听：只关它一个")
    func onlyTouchesListeningOnes() async {
        let netstat = """
        tcp46      0      0  *.5900                 *.*                    LISTEN
        tcp4       0      0  127.0.0.1.631          *.*                    LISTEN
        """
        let runner = ScriptedRunner(results: [
            "/usr/sbin/netstat": CommandResult(status: 0, stdout: netstat, stderr: "")
        ])
        let executor = RecordingExecutor()
        let control = SharingControl(runner: runner, executor: executor)

        #expect(control.listeningLabels() == ["com.apple.screensharing"])

        _ = await control.disableAll()
        #expect(executor.calls.count == 2)   // disable + bootout，只针对一个 label
    }

    @Test("关不掉的共享服务按优化项处理")
    func failureIsOptional() async {
        let netstat = """
        tcp46      0      0  *.5900                 *.*                    LISTEN
        """
        let runner = ScriptedRunner(results: [
            "/usr/sbin/netstat": CommandResult(status: 0, stdout: netstat, stderr: "")
        ])
        let executor = RecordingExecutor(failure: FakeError(message: "Operation not permitted"))
        let control = SharingControl(runner: runner, executor: executor)

        let failures = await control.disableAll()

        #expect(failures.count == 1)
        #expect(failures.first?.severity == .optional)
        #expect(AwayDecision.decide(failures).canProceed)
    }
}

@Suite("状态文件丢失时不去动备份设置")
struct SafeDefaultsTests {
    @Test("安全默认值不会把 Time Machine 打开")
    func doesNotTurnOnBackups() {
        #expect(Snapshot.safeDefaults.timeMachineEnabled == nil)
    }

    @Test("蓝牙仍然按安全方向恢复成开")
    func restoresBluetooth() {
        #expect(Snapshot.safeDefaults.bluetoothPower == 1)
    }
}

@Suite("历史报告里的英文原文会被清洗")
struct LegacyReportSanitizeTests {
    @Test("升级前写进历史的 tmutil 原文，读出来变成人话")
    func sanitizesLegacySummary() {
        let legacy = "Time Machine：后台服务执行失败：tmutil: disable requires Full Disk Access privileges.\nTo allow this operation, select Full Disk Access in the Privacy\ntab of the Security & Privacy preference pane, and add Terminal\nto the list of applications which are allowed Full Disk Access.\n"
        let cleaned = FailureText.sanitizeLegacySummary(legacy)
        #expect(cleaned == "Time Machine：需要额外权限，这一项不影响睡眠")
        #expect(!cleaned.contains("tmutil"))
        #expect(!cleaned.contains("Full Disk Access"))
    }

    @Test("已经是人话的记录原样保留")
    func keepsHumanSummary() {
        let human = "蓝牙：蓝牙状态没有变化"
        #expect(FailureText.sanitizeLegacySummary(human) == human)
    }

    @Test("清洗整份报告")
    func sanitizesReport() {
        let report = Report(
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 60),
            durationSeconds: 60,
            sleptAtAll: false,
            darkWakeCount: 0,
            notificationWakeCount: 0,
            realWakeCount: 0,
            failedItems: ["Time Machine：tmutil: disable requires Full Disk Access privileges."]
        )
        let cleaned = SessionStore.sanitized(report)
        #expect(cleaned.failedItems == ["Time Machine：需要额外权限，这一项不影响睡眠"])
    }
}
