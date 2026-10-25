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

// MARK: - 什么样的屏算「真显示器」

@Suite("真显示器 vs 虚拟屏")
struct RealDisplayTests {
    private func snap(vendor: UInt32, model: UInt32, serial: UInt32) -> DisplayWatcher.DisplaySnapshot {
        DisplayWatcher.DisplaySnapshot(
            id: 1, builtin: false, active: true, asleep: false,
            vendor: vendor, model: model, serial: serial,
            width: 1920, height: 1200
        )
    }

    /// 用户那块是 DIY 便携屏，EDID 是厂商自己烧的，序列号经常是 0x01010101 甚至 0。
    /// 拿序列号判真假会误伤用户自己那块屏——拔了线也永远不睡。
    @Test("DIY 便携屏：序列号再怪也是真显示器")
    func diyDisplayIsReal() {
        #expect(snap(vendor: 0x4A8B, model: 207, serial: 0x0101_0101).isRealDisplay)
        #expect(snap(vendor: 0x4A8B, model: 207, serial: 0).isRealDisplay)
    }

    /// 真机抓到的 #26：v1970170734/m1986622068/s0。
    @Test("虚拟屏：厂商号/型号是把字符串当整数塞进来的")
    func virtualDisplayIsNotReal() {
        #expect(!snap(vendor: 1_970_170_734, model: 1_986_622_068, serial: 0).isRealDisplay)
    }

    @Test("读不出 EDID：厂商号或型号是 0")
    func unknownEDIDIsNotReal() {
        #expect(!snap(vendor: 0, model: 0, serial: 0).isRealDisplay)
        #expect(!snap(vendor: 0x4A8B, model: 0, serial: 1234).isRealDisplay)
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

    /// 真机 12:29 那次：拔掉 #2 之后，online 列表里冒出一块 `#26 1920x1080`。
    /// 用户提供的事实：「machead、UU 远程似乎都会建立虚拟屏」「便携屏一直是 id 2」。
    ///
    /// 判定结果本来就没变（「基线里那块不在」那条也能覆盖），这条守的是**日志**：
    /// 不标出来的话，日志写「判定已拔线：基线 [2] → 现在 #26 1920x1080」，
    /// 看着像自相矛盾。
    @Test("拔线后只剩一块虚拟屏：判定照旧，但日志要说清它不是实屏")
    @MainActor
    func virtualDisplayOnlyCountsAsDetached() async {
        let (sim, state) = makeState { sim in
            sim.onlineIDs = [2, 1]
            sim.builtinIDs = [1]
            sim.mainID = 2
        }
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug }

        // 便携屏拔了，虚拟屏顶上来了。
        sim.virtualIDs = [26]
        sim.simulateDisplayState(active: 1, online: [26], main: 26)

        await waitUntil { state.displaysDetached }
        #expect(state.displaysDetached)
        #expect(sim.describeDisplays().contains("虚拟"))
    }

    /// 用户那块是 DIY 便携屏，EDID 是厂商自己烧的：序列号 0x01010101。
    /// 判「是不是实屏」绝不能看序列号，否则会把自己那块屏当假的排除掉，
    /// 拔了线也永远不睡。
    @Test("DIY 便携屏序列号是 0x01010101，也必须算实屏")
    @MainActor
    func diyDisplayWithOddSerialIsReal() async {
        let (sim, state) = makeState { sim in
            sim.onlineIDs = [2]
            sim.mainID = 2
        }
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug }
        #expect(state.displaysDetached == false)
        #expect(!sim.describeDisplays().contains("虚拟"))
    }

    /// 双屏只拔一块：按现在的判据仍然算「拔线」（基线里那块没了）。
    /// 这是「拔了就走」这个产品语义的直接取舍——先保证自动睡不会失效。
    @Test("双屏只拔一块，仍然算拔线（已知取舍）")
    @MainActor
    func unpluggingOneOfTwoIsStillDetached() async {
        let (sim, state) = makeState { sim in
            sim.onlineIDs = [2, 3]
            sim.mainID = 2
        }
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug }

        sim.simulateDisplayState(active: 1, online: [3], main: 3)
        await waitUntil { state.displaysDetached }
        #expect(state.displaysDetached)
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
