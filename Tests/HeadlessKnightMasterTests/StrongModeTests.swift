import Foundation
import Testing

@testable import HeadlessKnightMaster
@testable import HKMKit

// MARK: - 强力模式
//
// 需求原话：「勾选后，当用户唤醒后没有及时点击结束，每隔 10 分钟来一个强制深睡，
// 弹个消息，倒计时 10s（后来定成 30s）进入强制睡眠。」
//
// 这一组守四件事：
//   1. 只有「连续醒着」累计满阈值才动手——每次唤醒都清零的话，包里反复唤醒就永远不触发
//   2. 显示器插着 / 有远程登录，一律不许强制睡（那是有人真在用）
//   3. 倒计时要能取消，取消之后重新计时，不是立刻又来
//   4. 关掉开关就什么都不做

@MainActor
private func makeStrongHarness(
    strongMode: Bool = true,
    interval: Double = 120,
    countdown: Int = 2,
    _ configure: (SimulatedServices) -> Void = { _ in }
) -> (SimulatedServices, AppState) {
    let sim = SimulatedServices()
    sim.storedSettings = AppSettings(
        onboardingDone: true,
        launchAtLogin: false,
        sleepDelaySeconds: 1,
        strongMode: strongMode
    )
    sim.powerLog = Simulation.log(startingAt: sim.currentDate, sleeps: true, realWake: false)
    sim.blockers = [
        SleepBlocker(
            pid: 8322,
            processName: "UU远程",
            bundleIdentifier: "com.netease.uuremote",
            assertionTypes: ["PreventUserIdleSleep"],
            durationSeconds: 3600
        )
    ]
    configure(sim)
    let state = AppState(
        deps: .simulated(sim),
        timing: Timing(
            countdownTick: 0.01,
            sleepVerifySeconds: 0,
            unplugPollSeconds: 3600,
            sleepRetrySeconds: 3600,
            strongModeIntervalSeconds: interval,
            strongModeCountdownSeconds: countdown,
            // 后台那一拍不要来捣乱，测试自己拨时钟、自己调 tick。
            strongModeTickSeconds: 3600,
            sleepGapSeconds: 60
        ),
        autoAdvanceDetect: true
    )
    state.bootstrap()
    return (sim, state)
}

@MainActor
private func waitFor(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

/// 出门、拔线、睡成——强力模式从这里开始接手。
@MainActor
private func enterAway(_ sim: SimulatedServices, _ state: AppState) async {
    state.beginAway()
    await waitFor { state.screen == .readyToUnplug && !state.isBusy }
    sim.simulatePhantomDisplayAfterUnplug()
    await waitFor { state.sleepOutcome == .slept }
}

/// 把假时钟往前拨 `seconds`，然后手动走一拍。
@MainActor
private func tick(_ sim: SimulatedServices, _ state: AppState, seconds: Double) {
    sim.advanceClock(by: seconds)
    state.runStrongModeTick()
}

@Suite(.serialized)
@MainActor
struct StrongModeTests {
    @Test("醒着累计满阈值：先弹通知，倒计时结束才真睡")
    func forcesSleepAfterInterval() async {
        let (sim, state) = makeStrongHarness(interval: 120, countdown: 2)
        await enterAway(sim, state)
        #expect(sim.sleepNowCalls == 1)

        // 30 秒一拍，拨到 120 秒。
        for _ in 0..<4 { tick(sim, state, seconds: 30) }
        await waitFor { sim.sleepNowCalls == 2 && state.sleepOutcome == .slept }

        #expect(sim.notifications.contains { $0.hasPrefix("2 秒后强制睡眠") })
        #expect(sim.sleepNowCalls == 2)
        #expect(state.sleepOutcome == .slept)
    }

    @Test("重复唤醒不许把计时清零：每拍只醒 30 秒，四拍之后照样触发")
    func repeatedWakesStillFire() async {
        let (sim, state) = makeStrongHarness(interval: 120, countdown: 2)
        await enterAway(sim, state)

        for _ in 0..<3 { tick(sim, state, seconds: 30) }
        #expect(state.forceSleepCountdown == nil)   // 还没到
        tick(sim, state, seconds: 30)
        await waitFor { sim.sleepNowCalls == 2 }
        #expect(sim.sleepNowCalls == 2)
    }

    @Test("真的睡过去一觉：醒着时长清零，重新计时")
    func sleepingResetsTheClock() async {
        let (sim, state) = makeStrongHarness(interval: 120, countdown: 2)
        await enterAway(sim, state)

        tick(sim, state, seconds: 30)
        tick(sim, state, seconds: 30)
        #expect(state.awakeSeconds > 0)

        // 两拍之间隔了一小时 = 进程被挂起过 = 机器睡了。
        tick(sim, state, seconds: 3600)
        #expect(state.awakeSeconds == 0)
        #expect(state.forceSleepCountdown == nil)
        #expect(sim.sleepNowCalls == 1)
    }

    @Test("显示器插着：说明人就在电脑前，绝不强制睡眠")
    func attachedDisplayBlocksForcedSleep() async {
        let (sim, state) = makeStrongHarness(interval: 120, countdown: 2)
        await enterAway(sim, state)

        sim.simulateDisplayState(active: 1, online: [1], main: 1)
        await waitFor { !state.displaysDetached }

        for _ in 0..<6 { tick(sim, state, seconds: 30) }
        #expect(state.forceSleepCountdown == nil)
        #expect(sim.sleepNowCalls == 1)
    }

    @Test("有远程登录：只提醒一次，不强制睡眠")
    func remoteLoginWinsOverStrongMode() async {
        let (sim, state) = makeStrongHarness(interval: 120, countdown: 2)
        await enterAway(sim, state)

        sim.remoteLoginsValue = ["alice  ttys001  Oct 24 09:20 (10.0.0.5)"]
        for _ in 0..<8 { tick(sim, state, seconds: 30) }

        // 远程登录是后台查的，等它回来。
        await waitFor { sim.notifications.contains { $0.hasPrefix("没有强制睡眠") } }
        #expect(sim.sleepNowCalls == 1)
        let warnings = sim.notifications.filter { $0.hasPrefix("没有强制睡眠") }
        #expect(warnings.count == 1)
    }

    @Test("点「这次不睡」：这一轮放过，重新计时，不是立刻又来")
    func skipOnceRearms() async {
        let (sim, state) = makeStrongHarness(interval: 120, countdown: 3)
        await enterAway(sim, state)

        for _ in 0..<4 { tick(sim, state, seconds: 30) }
        await waitFor { state.forceSleepCountdown != nil }

        state.skipForcedSleepOnce()
        #expect(state.forceSleepCountdown == nil)
        #expect(state.awakeSeconds == 0)

        // 取消之后马上再走一拍：不许立刻重新开始倒计时。
        tick(sim, state, seconds: 5)
        #expect(state.forceSleepCountdown == nil)
        #expect(sim.sleepNowCalls == 1)
    }

    @Test("开关关着：醒多久都不动手")
    func disabledDoesNothing() async {
        let (sim, state) = makeStrongHarness(strongMode: false, interval: 120, countdown: 2)
        await enterAway(sim, state)

        for _ in 0..<10 { tick(sim, state, seconds: 30) }
        #expect(state.forceSleepCountdown == nil)
        #expect(sim.sleepNowCalls == 1)
        #expect(state.awakeSeconds == 0)
    }

    @Test("结束外出模式：强力模式立刻收手")
    func endingAwayStopsTheWatch() async {
        let (sim, state) = makeStrongHarness(interval: 120, countdown: 2)
        await enterAway(sim, state)

        await state.finishAway()
        let callsAfterFinish = sim.sleepNowCalls

        for _ in 0..<10 { tick(sim, state, seconds: 30) }
        #expect(sim.sleepNowCalls == callsAfterFinish)
        #expect(state.forceSleepCountdown == nil)
    }

    @Test("结束外出用预读好的日志，不再让用户对着转圈圈等")
    func reusesWarmedPowerLog() async {
        let (sim, state) = makeStrongHarness()
        await enterAway(sim, state)

        // 机器刚醒：提前读一遍。
        state.warmPowerLog()
        await waitFor { sim.powerLogReads == 1 }

        await state.finishAway()

        // 点「结束外出」时用的就是那一份，没有第二次读。
        #expect(sim.powerLogReads == 1)
        #expect(state.screen == .report)
    }

    @Test("只认带来源地址的登录：本机终端不算远程")
    func parsesOnlyRemoteSessions() {
        let output = """
        alice  console  Oct 24 09:12
        alice  ttys000  Oct 24 09:20
        alice  ttys001  Oct 24 09:25 (10.0.0.5)
        """
        let remote = RemoteSessionProbe.parse(output)
        #expect(remote.count == 1)
        #expect(remote.first?.contains("10.0.0.5") == true)
    }

    @Test("老版本设置文件里没有 strongMode，不能把整份设置弄丢")
    func decodesOldSettings() throws {
        let old = #"{"onboardingDone":true,"launchAtLogin":true,"sleepDelaySeconds":30}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        #expect(decoded.onboardingDone)
        #expect(decoded.launchAtLogin)
        #expect(decoded.sleepDelaySeconds == 30)
        #expect(decoded.strongMode == false)
    }
}
