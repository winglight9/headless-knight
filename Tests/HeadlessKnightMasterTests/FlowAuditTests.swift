import Foundation
import Testing

@testable import HeadlessKnightMaster
@testable import HKMKit

// MARK: - 流程审计项
//
// 这一组对应「用户报告流程走不通」时逐条排查出来的可疑点：
// 后台服务半路断开会不会卡住、图标连点会不会写两份报告、
// 旧状态文件能不能读、模拟器场景有没有烂掉。

/// 只记录、不执行的 root 操作替身，可以指定「第几次开始失败」。
final class FailingExecutor: PrivilegedExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HelperOperation] = []
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    var calls: [HelperOperation] { lock.withLock { recorded } }

    func perform(_ operation: HelperOperation, arguments: [String: String]) async throws -> HelperResponse {
        lock.withLock { recorded.append(operation) }
        throw error
    }
}

@Suite("后台服务半路断开")
struct HelperOutageTests {
    @Test("pmset 写入遇到后台服务断开：立刻短路，不把五个键各试一遍")
    func powerSettingsShortCircuits() async {
        let executor = FailingExecutor(error: HelperError.notInstalled)
        let power = PowerSettings(runner: ScriptedRunner(), executor: executor)

        let failures = await power.applyAwaySettings(current: nil, cancelScheduledWakes: false)

        #expect(failures.count == 1)
        #expect(failures.first?.title == "睡眠设置")
        #expect(failures.first?.severity == .critical)
        #expect(executor.calls.count == 1)
    }

    @Test("单项权限不足不该短路：剩下的键还要继续试")
    func singleKeyFailureKeepsGoing() async {
        let executor = FailingExecutor(error: HKMError.permissionDenied("denied"))
        let power = PowerSettings(runner: ScriptedRunner(), executor: executor)

        let failures = await power.applyAwaySettings(current: nil, cancelScheduledWakes: false)

        #expect(failures.count == PowerSettings.awayTargets.count)
        #expect(executor.calls.count == PowerSettings.awayTargets.count)
    }

    @Test("共享服务遇到后台服务断开：只报一条，不对三个 label 各等一次超时")
    func sharingShortCircuits() async {
        let executor = FailingExecutor(error: HelperError.connectionFailed("broken pipe"))
        let runner = ScriptedRunner(results: [
            "/usr/sbin/netstat": CommandResult(
                status: 0,
                stdout: """
                tcp46      0      0  *.445                  *.*                    LISTEN
                tcp46      0      0  *.5900                 *.*                    LISTEN
                tcp46      0      0  *.548                  *.*                    LISTEN
                """,
                stderr: ""
            )
        ])
        let sharing = SharingControl(runner: runner, executor: executor)

        let failures = await sharing.disableAll()

        #expect(failures.count == 1)
        #expect(failures.first?.severity == .optional)
        #expect(executor.calls.count == 1)
    }

    @Test("判断哪些错误算「整条链路断了」")
    func helperUnavailableClassification() {
        #expect(PowerSettings.isHelperUnavailable(HelperError.notInstalled))
        #expect(PowerSettings.isHelperUnavailable(HelperError.timeout))
        #expect(PowerSettings.isHelperUnavailable(HelperError.connectionFailed("x")))
        #expect(PowerSettings.isHelperUnavailable(HelperError.remote("pmset 报错")) == false)
        #expect(PowerSettings.isHelperUnavailable(HelperError.protocolViolation("x")) == false)
        #expect(PowerSettings.isHelperUnavailable(HKMError.permissionDenied("x")) == false)
    }

    @Test("交互路径的超时必须比后台任务短")
    func interactiveTimeoutIsShorter() {
        #expect(PrivilegedExecutorFactory.interactiveTimeout < HelperClient().timeout)
    }
}

@Suite(.serialized)
@MainActor
struct IconTapTests {
    @Test("外出中连点两下图标：只生成一份报告")
    func doubleTapWritesOneReport() async {
        let harness = AwayHarness { sim in
            sim.blockers = [hkmBlocker("Chrome", pid: 66273, bundle: "com.google.Chrome")]
        }
        await harness.enterAway()
        await harness.unplug()
        harness.sim.advanceClock(by: 3600)

        harness.state.handleIconTap()
        harness.state.handleIconTap()

        await AwayHarness.waitUntil { harness.state.screen == .report }

        #expect(harness.state.screen == .report)
        #expect(harness.sim.storedReports.count == 1)
        #expect(harness.state.report != nil)
    }

    @Test("还没出门时点图标不该做任何事")
    func tapWhenHomeDoesNothing() async {
        let harness = AwayHarness { sim in
            sim.blockers = []
        }
        harness.state.handleIconTap()

        #expect(harness.state.screen == .home)
        #expect(harness.state.report == nil)
        #expect(harness.sim.storedReports.isEmpty)
    }
}

@Suite("状态文件兼容性")
struct SessionStateCompatTests {
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = ISO8601OffsetFormatter.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "坏日期 \(raw)")
        }
        return decoder
    }

    @Test("旧状态文件没有 sleepRequestedAt 也能读出来")
    func decodesLegacyStateFile() throws {
        let json = """
        {
          "phase": "away",
          "startedAt": "2026-10-23T21:00:00+08:00",
          "timeZoneOffsetMinutes": 480,
          "logAnchor": "2026-10-23 21:00:00 +0800",
          "bootTimeAtStart": 1000,
          "snapshot": {
            "bluetoothPower": 1,
            "pmset": {"disablesleep": 1, "sleep": 0},
            "sharing": [],
            "terminatedApps": [],
            "scheduledWake": [],
            "failedItems": []
          }
        }
        """
        let state = try decoder().decode(SessionState.self, from: Data(json.utf8))

        #expect(state.phase == .away)
        #expect(state.sleepRequestedAt == nil)
        #expect(state.snapshot.pmset["disablesleep"] == 1)
    }

    @Test("新状态文件里的 sleepRequestedAt 能存能读")
    func roundTripsSleepRequestedAt() throws {
        let requested = Date(timeIntervalSince1970: 1_760_000_500)
        let state = SessionState(
            phase: .away,
            startedAt: Date(timeIntervalSince1970: 1_760_000_000),
            timeZoneOffsetMinutes: 480,
            logAnchor: "anchor",
            sleepRequestedAt: requested
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601OffsetFormatter.string(from: date))
        }
        let data = try encoder.encode(state)
        let decoded = try decoder().decode(SessionState.self, from: data)

        #expect(decoded.sleepRequestedAt == requested)
    }
}

@Suite("模拟器的假电源日志")
struct SimulationLogTests {
    @Test("暗唤醒的 domain 必须是 DarkWake，否则报告会说一次都没醒")
    func darkWakeDomainIsCorrect() {
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let log = Simulation.log(startingAt: start, sleeps: true, realWake: false)
        let kinds = WakeAuditor.parse(log).map(\.kind)

        #expect(kinds == [.sleepEnter, .darkWakeStart, .darkWakeStart])
    }

    @Test("带真实唤醒的日志里既有暗唤醒也有完整唤醒")
    func realWakeLogHasBothKinds() {
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let log = Simulation.log(startingAt: start, sleeps: true, realWake: true)
        let kinds = WakeAuditor.parse(log).map(\.kind)

        #expect(kinds.contains(.darkWakeStart))
        #expect(kinds.contains(.fullWake))
    }

    @Test("没睡的日志里一条睡眠记录都没有")
    func noSleepLogIsEmpty() {
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let log = Simulation.log(startingAt: start, sleeps: false, realWake: false)

        #expect(WakeAuditor.parse(log).isEmpty)
    }

    @Test("模拟器列出的每个场景都能找到、都能构造出依赖")
    @MainActor
    func everyScenarioIsBuildable() {
        let expected = [
            "success", "no-blockers", "blocker-fails", "blocker-respawns",
            "bluetooth-fails", "pmset-fails", "tm-fails", "sharing-fails",
            "helper-missing", "no-sleep", "anomaly-report", "restore-fails"
        ]
        #expect(Simulation.all.map(\.name) == expected)
        for name in expected {
            let scenario = Simulation.scenario(named: name)
            #expect(scenario != nil, "场景 \(name) 不存在")
            let sim = scenario?.build()
            #expect(sim != nil, "场景 \(name) 构造失败")
        }
    }

    @Test("未知场景返回非零退出码，而不是静默跑默认场景")
    @MainActor
    func unknownScenarioFails() async {
        let status = await Simulation.run("没有这个场景")
        #expect(status == 2)
    }
}
