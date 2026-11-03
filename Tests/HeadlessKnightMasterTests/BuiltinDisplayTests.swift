import Foundation
import Testing

@testable import HeadlessKnightMaster
@testable import HKMKit

// MARK: - 内建屏断开 / 防止空闲睡眠
//
// v1.9 起，「没有内建屏」不再只是一句声明：勾上会真的用 SkyLight 的
// `CGSConfigureDisplayEnabled` 把内建屏从显示拓扑里摘掉。这一组守四件事：
//
//   1. 勾上就断，取消就接回，设置和实际状态一起变；
//   2. 断不了就**说断不了**，绝不因为开关勾着就假装成功；
//   3. 系统把内屏装回来了（唤醒/插拔），要再摘一次；
//   4. 「防止空闲睡眠」出门时放开、回来接上，而且它自己不会被当成
//      「挡睡眠的程序」列到检测页上。

@MainActor
private func makeBuiltinHarness(
    noBuiltinDisplay: Bool = false,
    preventIdleSleep: Bool = true,
    _ configure: (SimulatedServices) -> Void = { _ in }
) -> (SimulatedServices, AppState) {
    let sim = SimulatedServices()
    sim.storedSettings = AppSettings(
        onboardingDone: true,
        launchAtLogin: false,
        sleepDelaySeconds: 1,
        strongMode: false,
        noBuiltinDisplay: noBuiltinDisplay,
        preventIdleSleep: preventIdleSleep
    )
    sim.builtinIsOnline = true
    configure(sim)
    let state = AppState(
        deps: .simulated(sim),
        timing: Timing(
            countdownTick: 0.01,
            sleepVerifySeconds: 0,
            unplugPollSeconds: 3600,
            sleepRetrySeconds: 3600
        ),
        autoAdvanceDetect: true
    )
    state.bootstrap()
    return (sim, state)
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 3,
    _ condition: @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

@Suite(.serialized)
@MainActor
struct BuiltinDisplayTests {
    @Test("勾上就断：设置和实际状态一起变")
    func cutOnToggle() async {
        let (sim, state) = makeBuiltinHarness()

        state.toggleNoBuiltinDisplay()
        await waitUntil { state.builtinCutState == .disconnected }

        #expect(state.settings.noBuiltinDisplay)
        #expect(state.builtinCutState == .disconnected)
        #expect(sim.displayCutCalls == 1)
        // 真机上断开之后内建屏会从 online 列表消失，模拟器跟着改。
        #expect(!sim.builtinIsOnline)
    }

    @Test("取消勾选就接回")
    func reconnectOnUntick() async {
        let (sim, state) = makeBuiltinHarness()

        state.toggleNoBuiltinDisplay()
        await waitUntil { state.builtinCutState == .disconnected }

        state.toggleNoBuiltinDisplay()
        await waitUntil { state.builtinCutState == .connected }

        #expect(!state.settings.noBuiltinDisplay)
        #expect(sim.displayCutCalls == 2)
        #expect(sim.builtinIsOnline)
    }

    @Test("断开失败：开关勾着，但必须说没断开")
    func failureIsReported() async {
        let (sim, state) = makeBuiltinHarness()
        sim.displayCutFailure = "提交失败"

        state.toggleNoBuiltinDisplay()
        await waitUntil {
            if case .failed = state.builtinCutState { return true }
            return false
        }

        // 用户的意图留着（他确实说了没有内建屏），失败要摆到脸上。
        #expect(state.settings.noBuiltinDisplay)
        guard case let .failed(reason) = state.builtinCutState else {
            Issue.record("状态没变成失败：\(state.builtinCutState)")
            return
        }
        #expect(reason == "提交失败")
    }

    @Test("系统上没有这个接口：显示成做不到，不是假装成功")
    func unsupportedSystem() async {
        let (sim, state) = makeBuiltinHarness()
        sim.displayCutAvailable = false

        #expect(!state.isBuiltinCutAvailable)

        state.toggleNoBuiltinDisplay()
        await waitUntil { state.builtinCutState == .unsupported }

        #expect(state.builtinCutState == .unsupported)
        #expect(sim.displayCutCalls == 0)
    }

    @Test("开机按设置断屏（走的是 startupSystemTasks，不在 bootstrap 里）")
    func startupCutsWhenTicked() async {
        let (sim, state) = makeBuiltinHarness(noBuiltinDisplay: true)
        // bootstrap 里不能断：那是同步函数，异步断屏会和外出基线抢时序。
        #expect(sim.displayCutCalls == 0)

        state.startupSystemTasks()
        await waitUntil { state.builtinCutState == .disconnected }
        #expect(sim.displayCutCalls == 1)
    }

    @Test("内建屏又被系统装回来了：自己再摘一次")
    func maintainCutAfterWake() async {
        let (sim, state) = makeBuiltinHarness(noBuiltinDisplay: true)
        state.startupSystemTasks()
        await waitUntil { state.builtinCutState == .disconnected }
        #expect(sim.displayCutCalls == 1)

        // 唤醒之后系统把内屏装回来，显示器回调会来。
        sim.builtinIsOnline = true
        sim.simulateDisplayCount(2)

        await waitUntil(timeout: 3) { sim.displayCutCalls >= 2 }
        #expect(sim.displayCutCalls >= 2)
    }

    @Test("出门流程里 ⌘H 不响应：别在重排显示器的时候插一脚")
    func hotKeyIgnoredDuringAwayFlow() async {
        let (sim, state) = makeBuiltinHarness()
        sim.blockers = []
        sim.onlineIDs = [3]
        sim.builtinIDs = [1]

        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug }
        await state.waitForFlow()

        state.toggleBuiltinByHotKey()
        #expect(!state.settings.noBuiltinDisplay)
        #expect(sim.displayCutCalls == 0)
    }

    @Test("首页按 ⌘H：等同点开关，设置跟着变")
    func hotKeyTogglesOnHome() async {
        let (sim, state) = makeBuiltinHarness()

        state.toggleBuiltinByHotKey()
        await waitUntil { state.builtinCutState == .disconnected }
        #expect(state.settings.noBuiltinDisplay)

        state.toggleBuiltinByHotKey()
        await waitUntil { state.builtinCutState == .connected }
        #expect(!state.settings.noBuiltinDisplay)
        #expect(sim.displayCutCalls == 2)
    }
}

@Suite(.serialized)
@MainActor
struct IdleSleepAssertionTests {
    @Test("默认开：启动就拿到断言")
    func holdsOnLaunch() {
        let (sim, state) = makeBuiltinHarness()
        #expect(state.settings.preventIdleSleep)
        #expect(state.idleSleepHeld)
        #expect(sim.idleSleepHolding)
    }

    @Test("关掉就放掉")
    func toggleReleases() {
        let (sim, state) = makeBuiltinHarness()
        state.togglePreventIdleSleep()

        #expect(!state.settings.preventIdleSleep)
        #expect(!state.idleSleepHeld)
        #expect(!sim.idleSleepHolding)
    }

    @Test("系统不给断言：勾着也要说没生效")
    func refusedIsVisible() {
        let (sim, state) = makeBuiltinHarness()
        sim.idleSleepGranted = false
        state.togglePreventIdleSleep()  // 关
        state.togglePreventIdleSleep()  // 再开，系统这次拒绝

        #expect(state.settings.preventIdleSleep)
        #expect(!state.idleSleepHeld)
    }

    @Test("出门就放开：不然机器永远不睡")
    func releasedWhenAway() async {
        let (sim, state) = makeBuiltinHarness()
        sim.blockers = []
        sim.onlineIDs = [3]
        sim.builtinIDs = [1]
        #expect(sim.idleSleepHolding)

        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug }
        await state.waitForFlow()

        #expect(!sim.idleSleepHolding)
        #expect(sim.idleSleepRequests.contains(false))
    }

    @Test("回来就接上")
    func restoredOnReturn() async {
        let (sim, state) = makeBuiltinHarness()
        sim.blockers = []
        sim.onlineIDs = [3]
        sim.builtinIDs = [1]

        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug }
        await state.waitForFlow()
        #expect(!sim.idleSleepHolding)

        // 用户拔线 → 睡 → 回来点结束。这里直接走还原那条路。
        await state.restoreAndReturnHome()
        #expect(sim.idleSleepHolding)
    }

    @Test("它自己不会被列成「挡睡眠的程序」")
    func ownAssertionIsNotABlocker() {
        let entries = [
            AssertionEntry(
                pid: getpid(),
                ownerName: "Knight",
                assertionType: "PreventUserIdleSystemSleep",
                assertionName: "无头骑士大师：机器正被当作服务器使用",
                durationSeconds: 3600
            )
        ]
        let result = AssertionScanner().blockers(from: AssertionScan(entries: entries))
        #expect(result.blockers.isEmpty)
    }
}
