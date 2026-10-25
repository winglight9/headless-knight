import CoreGraphics
import Foundation
import Testing

@testable import HeadlessKnightMaster
@testable import HKMKit

// MARK: - 2026-10-25 上午那次「开机提示没有睡成功」
//
// 用户在电脑前坐着，外接屏好端端插着，软件却：
//   · 11:47:17 判定「已拔线」，因为基线里那块**内建屏**从 online 列表里消失了；
//   · 倒计时到点叫了三次睡眠，全失败，最后报「还没能睡着」；
//   · 12 分钟后的 10:47 那次更冤：机器 10:47:30 就睡了、一直睡到 10:51:57，
//     软件却在醒来那一刻写「系统仍然醒着」。
//
// 两个根因，两条断言组。

@MainActor
private func makeState(
    sleepVerifySeconds: Double = 0,
    _ configure: (SimulatedServices) -> Void = { _ in }
) -> (SimulatedServices, AppState) {
    let sim = SimulatedServices()
    sim.storedSettings = AppSettings(onboardingDone: true, launchAtLogin: false, sleepDelaySeconds: 1)
    sim.powerLog = Simulation.log(startingAt: sim.currentDate, sleeps: true, realWake: false)
    configure(sim)
    let state = AppState(
        deps: .simulated(sim),
        timing: Timing(
            countdownTick: 0.01,
            detectPollSeconds: 0.05,
            sleepVerifySeconds: sleepVerifySeconds,
            unplugPollSeconds: 3600,
            sleepRetrySeconds: 3600
        ),
        autoAdvanceDetect: true
    )
    state.bootstrap()
    return (sim, state)
}

@MainActor
private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

// MARK: - 拔线判定只看外接屏

@Suite("拔线判定：内建屏不算数")
struct ExternalDisplayBaselineTests {
    /// 复现 11:47:17：外接屏 #2 一直在，内建屏 #1 消失了。
    @Test("内建屏从 online 里消失，不算拔线")
    @MainActor
    func builtinDisappearingIsNotUnplug() async {
        let (sim, state) = makeState { sim in
            // 进拔线页时：外接屏 #2 + 内建屏 #1。
            sim.onlineIDs = [2, 1]
            sim.builtinIDs = [1]
            sim.mainID = 2
        }
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug }

        // 内建屏被系统回收（合盖 / clamshell 重配），外接屏还在。
        sim.onlineIDs = [2]
        sim.displayCountValue = 1
        sim.simulateDisplayState(active: 1, online: [2], main: 2)

        await waitUntil(timeout: 1) { state.displaysDetached }
        #expect(state.displaysDetached == false)
        #expect(sim.sleepNowCalls == 0)
        #expect(state.sleepOutcome == .idle)
    }

    /// 真正拔掉外接屏：外接 #2 不在了，只剩内建 #1。
    @Test("外接屏拔掉才判拔线")
    @MainActor
    func unpluggingExternalDetaches() async {
        let (sim, state) = makeState { sim in
            sim.onlineIDs = [2, 1]
            sim.builtinIDs = [1]
            sim.mainID = 2
        }
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug }

        sim.simulateDisplayState(active: 1, online: [1], main: 1)

        await waitUntil { state.displaysDetached }
        #expect(state.displaysDetached)
    }

    /// 基线里没有内建屏，但外接屏在——一切正常。
    @Test("外接屏还在就不算拔线")
    @MainActor
    func externalStillOnlineIsNotDetached() async {
        let (sim, state) = makeState { sim in
            sim.onlineIDs = [2, 1]
            sim.builtinIDs = [1]
            sim.mainID = 2
        }
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug }

        sim.simulateDisplayState(active: 1, online: [2], main: 2)
        await waitUntil(timeout: 1) { state.displaysDetached }
        #expect(state.displaysDetached == false)
    }
}

// MARK: - 睡眠验证要看整段旅程的时钟

@Suite("睡眠验证：读取证据期间被挂起也算睡了")
struct SleepVerificationWindowTests {
    /// 复现 10:47 那次：等待窗口只有 4 秒，机器 5 秒后才睡；判「没睡」之后去读
    /// 电源日志，进程在睡眠里被冻了四分半。醒来必须认账。
    @Test("读证据期间时钟跳了 4 分钟，就算睡了")
    @MainActor
    func suspensionDuringEvidenceCounts() async {
        let (sim, state) = makeState { sim in
            sim.onlineIDs = [2]
            sim.displayCountValue = 1
            sim.powerLog = ""
            // 系统一口咬定「没睡」，日志也读不出来——只有时钟在说实话。
            sim.sleepSucceeds = false
            sim.sleepEvidenceValue = .awake
            sim.advanceClockOnSleepEvidence = 271
        }
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug }
        state.retrySleep()

        await waitUntil { state.sleepOutcome == .slept }
        #expect(state.sleepOutcome == .slept)
        // 睡成了就该切「外出中」，绝不能停在「还没能睡着」。
        #expect(state.screen == .away)
    }

    @Test("只跳了 4 秒、证据说没睡，就老实说没睡")
    @MainActor
    func shortGapStillReportsAwake() async {
        let (sim, state) = makeState { sim in
            sim.onlineIDs = [2]
            sim.displayCountValue = 1
            sim.sleepSucceeds = false
            sim.sleepEvidenceValue = .awake
            sim.advanceClockOnSleepEvidence = 4
        }
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug }
        state.retrySleep()

        await waitUntil { state.sleepOutcome != .requesting && state.sleepOutcome != .idle }
        guard case .failed = state.sleepOutcome else {
            Issue.record("应该报「没睡着」，实际是 \(state.sleepOutcome)")
            return
        }
    }
}

// MARK: - 点了结束，在飞的睡眠验证不许把界面拽回来

@Suite("结束外出：不许被后台重试拽回拔线页")
struct AbortAwayWinsTests {
    /// 复现 11:48：用户连点「结束外出模式」，每次都还原完回到首页，然后被一个
    /// 还在跑的睡眠验证改回 `readyToUnplug`——看着就像按钮没作用。
    @Test("结束之后，过期的验证不再改界面")
    @MainActor
    func staleVerificationDoesNotHijackUI() async {
        let (sim, state) = makeState { sim in
            sim.onlineIDs = [2]
            sim.displayCountValue = 1
            sim.sleepSucceeds = false
            sim.sleepEvidenceValue = .awake
        }
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug }

        // 睡眠验证正卡在读证据里，用户这时点了结束。
        sim.onSleepEvidence = { state.abortAway() }
        state.retrySleep()

        await waitUntil { state.screen == .home }
        // 给过期的验证足够时间「跑完」——它必须已经收手。
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(state.screen == .home)
        #expect(state.sleepOutcome == .idle)
        #expect(state.errorMessage == nil)
    }

    @Test("连点结束只还原一次")
    @MainActor
    func repeatedTapsRestoreOnce() async {
        let (sim, state) = makeState { sim in
            sim.onlineIDs = [2]
            sim.displayCountValue = 1
        }
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug }

        for _ in 0..<5 { state.cancelReadyToUnplug() }
        await waitUntil { state.screen == .home }

        // 蓝牙还原几次，就有几次整份还原。
        let bluetoothRestores = sim.events.filter { $0 == "bluetooth on" }.count
        #expect(bluetoothRestores <= 1)
        #expect(state.isEndingAway == false)
    }
}
