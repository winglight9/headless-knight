import Foundation
import Testing

@testable import HeadlessKnightMaster
@testable import HKMKit

// MARK: - 补齐设计文档第 8 章里没有任何测试的路径
//
// 这一组只补缺口，不改既有断言。每条都对应异常处理矩阵或用户流程里
// 明确写了、但原来的 135 个测试一条都没覆盖的分支：
//   · 外出中 App 被杀 → 重启后读状态文件（第 8 章）
//   · 统计完但没点「知道了」就被杀 → 重启后还能看到报告
//   · 忘记结束外出模式 → 插回显示器弹一次提醒（第 8 章）
//   · 状态文件损坏 → 安全默认值（第 8 章）
//   · 扫描本身失败 → 不许当成「0 个程序」（AppState 里专门处理过）
//   · 「仍然继续」之后 → 报告里必须留痕（第 8 章第 1 条）
//   · 连点「知道了」→ 只恢复一次

@MainActor
private func gapHarness(
    sleepDelaySeconds: Int = 1,
    scanner: (any ProcessScanning)? = nil,
    store: (any StateStoring)? = nil,
    _ configure: (SimulatedServices) -> Void = { _ in }
) -> (sim: SimulatedServices, state: AppState) {
    let sim = SimulatedServices()
    sim.storedSettings = AppSettings(
        onboardingDone: true,
        launchAtLogin: false,
        sleepDelaySeconds: sleepDelaySeconds
    )
    sim.powerLog = Simulation.log(startingAt: sim.currentDate, sleeps: true, realWake: false)
    configure(sim)

    let base = AppDependencies.simulated(sim)
    let deps = AppDependencies(
        scanner: scanner ?? sim,
        killer: base.killer,
        power: base.power,
        bluetooth: base.bluetooth,
        battery: base.battery,
        sharing: base.sharing,
        timeMachine: base.timeMachine,
        displays: base.displays,
        store: store ?? base.store,
        notifier: base.notifier,
        loginItem: base.loginItem,
        powerLog: base.powerLog,
        helper: base.helper,
        remote: base.remote,
        clock: base.clock,
        auditor: base.auditor
    )
    let state = AppState(deps: deps, timing: Timing(detectCountdownSeconds: 1, countdownTick: 0.01, sleepVerifySeconds: 0, unplugPollSeconds: 3600, sleepRetrySeconds: 3600))
    return (sim, state)
}

private struct ScanFailure: LocalizedError {
    var errorDescription: String? { "读取断言失败" }
}

@MainActor
private struct ThrowingScanner: ProcessScanning {
    func scan() throws -> BlockerScanResult { throw ScanFailure() }
}

private func gapBlocker(_ name: String, pid: pid_t, bundle: String?) -> SleepBlocker {
    SleepBlocker(
        pid: pid,
        processName: name,
        bundleIdentifier: bundle,
        assertionTypes: ["PreventUserIdleSystemSleep"],
        durationSeconds: 3600
    )
}

@MainActor
private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

// MARK: - 1. 外出中 App 被杀

@Suite(.serialized)
@MainActor
struct RestartRecoveryTests {
    /// 设计文档第 8 章：「外出中 App 被杀 → 状态文件在磁盘，重启后读取」。
    @Test("外出中重启：读回状态文件，仍然停在外出中，时长接着算")
    func resumesAwaySessionAfterRestart() {
        let (sim, state) = gapHarness { sim in
            var snapshot = Snapshot()
            snapshot.pmset = PmsetSnapshot(values: ["disablesleep": 0, "sleep": 1, "womp": 0])
            snapshot.bluetoothPower = 1
            sim.storedState = SessionState(
                phase: .away,
                startedAt: sim.currentDate.addingTimeInterval(-3600),
                timeZoneOffsetMinutes: 480,
                logAnchor: PowerLogDateFormatter.string(from: sim.currentDate.addingTimeInterval(-3600)),
                batteryStart: 90,
                bootTimeAtStart: sim.bootTimeValue,
                snapshot: snapshot
            )
        }

        state.bootstrap()

        #expect(state.screen == .away)
        #expect(state.iconState == .away)
        #expect(state.session?.phase == .away)
        #expect(state.awayDurationSeconds == 3600)
        // 快照必须原样带回来，否则「知道了」会把机器留在睡不着的状态里。
        #expect(state.session?.snapshot.pmset["disablesleep"] == 0)
        #expect(state.session?.snapshot.pmset["sleep"] == 1)
    }

    @Test("统计完但没点「知道了」就被杀：重启后直接看到那份报告，图标仍是红的")
    func resumesAuditedReportAfterRestart() {
        let report = Report(
            startedAt: Date(timeIntervalSince1970: 1_760_000_000),
            endedAt: Date(timeIntervalSince1970: 1_760_001_000),
            durationSeconds: 1000,
            batteryStart: 90,
            batteryEnd: 88,
            sleptAtAll: true,
            darkWakeCount: 1,
            notificationWakeCount: 0,
            realWakeCount: 1
        )
        let (_, state) = gapHarness { sim in
            sim.storedState = SessionState(
                phase: .audited,
                startedAt: Date(timeIntervalSince1970: 1_760_000_000),
                timeZoneOffsetMinutes: 480,
                logAnchor: "anchor",
                snapshot: Snapshot(),
                lastReport: report
            )
        }

        state.bootstrap()

        #expect(state.screen == .report)
        #expect(state.report?.headline == "被唤醒 1 次")
        #expect(state.iconState == .alert)
    }

    @Test("重启后插回显示器：弹一次「欢迎回来」，且只弹一次")
    func postsWelcomeBackOnce() {
        let (sim, state) = gapHarness { sim in
            sim.storedState = SessionState(
                phase: .away,
                startedAt: sim.currentDate.addingTimeInterval(-600),
                timeZoneOffsetMinutes: 480,
                logAnchor: "anchor",
                snapshot: Snapshot(bluetoothPower: 1)
            )
        }
        state.bootstrap()
        #expect(state.screen == .away)

        sim.simulateDisplayCount(1)
        sim.simulateDisplayCount(0)
        sim.simulateDisplayCount(1)

        let welcome = sim.notifications.filter { $0.contains("欢迎回来") }
        #expect(welcome.count == 1)
    }
}

// MARK: - 2. 状态文件损坏

@Suite(.serialized)
@MainActor
struct CorruptStateFileTests {
    @Test("状态文件是垃圾内容：启动不崩，回到首页，当作没有这次外出")
    func corruptStateFileFallsBackHome() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hkm-gap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        // 设置文件是好的（引导已完成），只有状态文件坏了——这才是真实场景。
        try store.saveSettings(AppSettings(onboardingDone: true, launchAtLogin: false, sleepDelaySeconds: 5))
        try "{\"phase\": \"away\", 这是被截断的".write(to: store.stateURL, atomically: true, encoding: .utf8)

        let (_, state) = gapHarness(store: store)
        state.bootstrap()

        #expect(state.screen == .home)
        #expect(state.iconState == .home)
        #expect(state.session == nil)
    }

    @Test("状态文件损坏后点「知道了」：用安全默认值恢复，并把原因说出来")
    func corruptStateRestoreUsesSafeDefaults() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hkm-gap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        try store.saveSettings(AppSettings(onboardingDone: true, launchAtLogin: false, sleepDelaySeconds: 5))
        try "not json".write(to: store.stateURL, atomically: true, encoding: .utf8)

        let (sim, state) = gapHarness(store: store)
        state.bootstrap()
        #expect(state.session == nil)

        await state.acknowledgeReportNow()

        // 安全方向：蓝牙必须回到开，机器要保持可达。
        #expect(sim.bluetoothState == 1)
        #expect(state.failedItems.contains { $0.title == "状态文件" })
        #expect(state.screen == .home)
    }
}

// MARK: - 3. 扫描失败不能当成「0 个程序」

@Suite(.serialized)
@MainActor
struct ScanFailureTests {
    @Test("扫描抛错：不假装没有程序，流程照走但报告里要留一条「扫描」")
    func scanFailureIsRecordedInReport() async {
        let (sim, state) = gapHarness(scanner: ThrowingScanner())
        state.narrator = { _ in }

        state.beginAway()
        #expect(state.errorMessage == "读取断言失败")
        await state.waitForFlow()

        #expect(state.screen == .readyToUnplug)
        #expect(state.optionalFailures.count == 1)
        #expect(state.optionalFailures.first?.title == "扫描")
        // 扫描失败不能变成阻塞项：用户还是能出门，只是这次没检查过。
        #expect(state.criticalFailures.isEmpty)

        sim.simulateDisplayCount(0)
        await waitUntil { sim.sleepNowCalls > 0 }
        sim.advanceClock(by: 3600)
        await state.finishAway()

        #expect(state.report?.failedItems.contains { $0.contains("扫描") } == true)
    }
}

// MARK: - 4. 「仍然继续」必须在报告里留痕

@Suite(.serialized)
@MainActor
struct ContinueAnywayLeavesTraceTests {
    @Test("程序关不掉但点了「仍然继续」：报告里必须写着这一项")
    func continueAnywayIsRecordedInReport() async {
        let (sim, state) = gapHarness { sim in
            sim.blockers = [gapBlocker("Chrome", pid: 66273, bundle: "com.google.Chrome")]
            sim.killOutcomes["Chrome"] = .failed("无法自动退出，它还在阻止睡眠。请手动退出这个程序。")
        }
        state.narrator = { _ in }

        state.beginAway()
        await waitUntil { state.screen == .blocked && !state.isBusy }
        await state.waitForFlow()
        #expect(state.screen == .blocked)

        state.continueAnyway()
        #expect(state.screen == .readyToUnplug)

        sim.simulateDisplayCount(0)
        await waitUntil { sim.sleepNowCalls > 0 }
        sim.advanceClock(by: 3600)
        await state.finishAway()

        #expect(state.report?.failedItems.contains { $0.contains("Chrome") } == true)
    }
}

// MARK: - 5. 连点「知道了」

@Suite(.serialized)
@MainActor
struct DoubleAcknowledgeTests {
    @Test("连点两下「知道了」：只恢复一次，不该冒出第二条「状态文件丢了」")
    func doubleAcknowledgeRestoresOnce() async {
        let (sim, state) = gapHarness { sim in
            sim.blockers = [gapBlocker("Chrome", pid: 66273, bundle: "com.google.Chrome")]
        }
        state.narrator = { _ in }

        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug && !state.isBusy }
        await state.waitForFlow()
        sim.simulateDisplayCount(0)
        await waitUntil { sim.sleepNowCalls > 0 }
        sim.advanceClock(by: 3600)
        await state.finishAway()
        #expect(state.screen == .report)

        state.acknowledgeReport()
        state.acknowledgeReport()
        await waitUntil { state.screen == .home }

        #expect(sim.clearedStateCount == 1)
        #expect(state.failedItems.isEmpty)
        #expect(state.errorMessage == nil)
    }
}
