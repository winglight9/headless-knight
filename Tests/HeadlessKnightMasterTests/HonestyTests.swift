import Foundation
import Testing

@testable import HeadlessKnightMaster
@testable import HKMKit

// MARK: - 「不许骗人」回归测试
//
// 这一组全是 2026-10-24 早上那次真实失败暴露出来的：
//   · 界面写「✓ 关闭了蓝牙」，`system_profiler` 却说 State: On
//   · 界面写「系统已进入睡眠」，`pmset -g log` 里根本没有 Entering Sleep
//   · 恢复失败还删掉状态文件，下次外出把改过的值当成原值，永远恢复不回来
//   · 一次都没成功的那两次崩溃：Notifier 的 MainActor 闭包、IOBluetooth 的 TCC
//
// 每一条都对应一个「软件说了假话」的具体路径。

@MainActor
private func makeHarness(
    sleepDelaySeconds: Int = 1,
    sleepRetrySeconds: Double = 3600,
    _ configure: (SimulatedServices) -> Void = { _ in }
) -> (SimulatedServices, AppState) {
    let sim = SimulatedServices()
    sim.storedSettings = AppSettings(
        onboardingDone: true,
        launchAtLogin: false,
        sleepDelaySeconds: sleepDelaySeconds
    )
    sim.powerLog = Simulation.log(startingAt: sim.currentDate, sleeps: true, realWake: false)
    configure(sim)
    let state = AppState(
        deps: .simulated(sim),
        timing: Timing(
            countdownTick: 0.01,
            sleepVerifySeconds: 0,
            unplugPollSeconds: 3600,
            sleepRetrySeconds: sleepRetrySeconds
        ),
        // 检测页不再自动倒计时，测试里替用户点「一键关闭」。
        autoAdvanceDetect: true
    )
    state.bootstrap()
    return (sim, state)
}

@MainActor
private func seedBlockers(_ sim: SimulatedServices) {
    sim.blockers = [
        SleepBlocker(
            pid: 8322,
            processName: "UU远程",
            bundleIdentifier: "com.netease.uuremote",
            assertionTypes: ["PreventUserIdleSystemSleep"],
            durationSeconds: 49 * 3600
        )
    ]
}

@MainActor
private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

@Suite(.serialized)
@MainActor
struct RestoreNeverEatsSnapshotTests {
    @Test("恢复失败时不许删状态文件：快照只有这一份")
    func failedRestoreKeepsSnapshot() async {
        let (sim, state) = makeHarness { seedBlockers($0) }
        sim.failingRestoreKeys = ["disablesleep"]

        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug && !state.isBusy }

        // 用户在拔线页上按「取消」
        state.cancelReadyToUnplug()
        await waitUntil { !state.isBusy && state.pendingRestore }

        #expect(state.pendingRestore)
        #expect(sim.storedState != nil, "状态文件被删掉的话，原始快照就永久丢了")
        #expect(sim.clearedStateCount == 0)
        #expect(sim.storedState?.phase == .needsRestore)
        #expect(state.screen == .home)
    }

    @Test("恢复成功后清干净，不留半截状态")
    func successfulRestoreClearsState() async {
        let (sim, state) = makeHarness { seedBlockers($0) }
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug && !state.isBusy }

        state.cancelReadyToUnplug()
        await waitUntil { !state.isBusy && state.session == nil }

        #expect(state.pendingRestore == false)
        #expect(sim.storedState == nil)
        #expect(sim.clearedStateCount == 1)
    }

    @Test("带着 needsRestore 启动：首页要提示，不能装作没事")
    func bootstrapSurfacesPendingRestore() async {
        let (sim, state) = makeHarness { sim in
            sim.storedState = SessionState(
                phase: .needsRestore,
                startedAt: sim.currentDate,
                timeZoneOffsetMinutes: 480,
                logAnchor: "2026-10-24 08:54:47 +0800",
                snapshot: Snapshot.safeDefaults
            )
        }
        state.bootstrap()

        #expect(state.screen == .home)
        #expect(state.pendingRestore)
        #expect(state.iconState == .alert)
        #expect(sim.storedState != nil)
    }

    @Test("还没恢复完就想再出门：先补恢复，再开始新的一趟")
    func beginAwayRestoresFirst() async {
        let (sim, state) = makeHarness { sim in
            seedBlockers(sim)
            sim.storedState = SessionState(
                phase: .needsRestore,
                startedAt: sim.currentDate,
                timeZoneOffsetMinutes: 480,
                logAnchor: "2026-10-24 08:54:47 +0800",
                snapshot: Snapshot.safeDefaults
            )
        }
        state.bootstrap()
        #expect(state.pendingRestore)

        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug && !state.isBusy }

        #expect(state.pendingRestore == false)
        #expect(state.screen == .readyToUnplug)
    }
}

@Suite(.serialized)
@MainActor
struct BluetoothHonestyTests {
    @Test("蓝牙关不掉 → 阻塞；用户手动关掉后点「我处理好了」应该放行")
    func manualBluetoothOffUnblocks() async {
        let (sim, state) = makeHarness { sim in
            seedBlockers(sim)
            sim.bluetoothState = 1
            sim.bluetoothSetFailure = "系统没给蓝牙权限，没法自动关闭蓝牙"
        }
        state.beginAway()
        await waitUntil { state.screen == .blocked && !state.isBusy }

        #expect(state.screen == .blocked)
        #expect(state.bluetoothFailure != nil)

        // 用户在控制中心手动关掉了蓝牙
        sim.bluetoothState = 0
        state.retryAfterManualFix()
        await waitUntil { state.screen == .readyToUnplug && !state.isBusy }

        #expect(state.screen == .readyToUnplug)
        #expect(state.bluetoothFailure == nil)
        #expect(state.completedActions.contains("关闭了蓝牙"))
    }

    @Test("蓝牙状态只认 system_profiler，不认我们自己写进去的偏好文件")
    func parsesControllerStateFromProfiler() {
        let on = """
        Bluetooth:

              Bluetooth Controller:
                  Address: C8:89:F3:B6:84:7B
                  State: On
                  Chipset: BCM_4387
        """
        let off = """
        Bluetooth:

              Bluetooth Controller:
                  State: Off
        """
        #expect(BluetoothControl.parsePowerState(fromProfiler: on) == 1)
        #expect(BluetoothControl.parsePowerState(fromProfiler: off) == 0)
        #expect(BluetoothControl.parsePowerState(fromProfiler: "没有蓝牙") == nil)
    }
}

@Suite(.serialized)
@MainActor
struct SleepHonestyTests {
    @Test("叫它睡但它没睡：不重试到死，也不自己循环重试")
    func failedSleepDoesNotLoop() async {
        let (sim, state) = makeHarness { sim in
            seedBlockers(sim)
            sim.sleepSucceeds = false
        }
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug && !state.isBusy }

        sim.simulateDisplayCount(0)
        await waitUntil { state.sleepOutcome != .idle && state.sleepOutcome != .requesting }

        let callsAfterFailure = sim.sleepNowCalls
        #expect(callsAfterFailure == 3)

        // 再等一会：后台重试的间隔被调到 1 小时，这里不该有任何新的调用
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(sim.sleepNowCalls == callsAfterFailure)
        #expect(state.screen == .readyToUnplug)
    }

    @Test("睡眠失败后后台会继续重试，而不是只试一次就放弃")
    func watchdogKeepsRetrying() async {
        let (sim, state) = makeHarness(sleepRetrySeconds: 0.05) { sim in
            seedBlockers(sim)
            sim.sleepSucceeds = false
        }
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug && !state.isBusy }

        sim.simulateDisplayCount(0)
        await waitUntil { state.sleepOutcome != .idle && state.sleepOutcome != .requesting }
        let afterFirstRound = sim.sleepNowCalls

        await waitUntil(timeout: 5) { sim.sleepNowCalls > afterFirstRound }
        #expect(sim.sleepNowCalls > afterFirstRound, "看门狗没有继续重试")
        #expect(state.screen == .readyToUnplug)
    }

    @Test("显示器插回来之后看门狗必须停手，不能把人正在用的机器弄睡")
    func watchdogStopsWhenDisplayReturns() async {
        let (sim, state) = makeHarness(sleepRetrySeconds: 0.05) { sim in
            seedBlockers(sim)
            sim.sleepSucceeds = false
        }
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug && !state.isBusy }

        sim.simulateDisplayCount(0)
        await waitUntil { state.sleepOutcome != .idle && state.sleepOutcome != .requesting }

        sim.simulateDisplayCount(1)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let callsAfterReturn = sim.sleepNowCalls
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(sim.sleepNowCalls == callsAfterReturn)
    }

    @Test("在「还没睡着」的页面点开设置再关掉，不能跳到「外出中」")
    func settingsReturnsToTheSameScreen() async {
        let (sim, state) = makeHarness { sim in
            seedBlockers(sim)
            sim.sleepSucceeds = false
        }
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug && !state.isBusy }

        sim.simulateDisplayCount(0)
        await waitUntil { state.sleepOutcome != .idle && state.sleepOutcome != .requesting }
        #expect(state.screen == .readyToUnplug)

        state.showSettings()
        #expect(state.screen == .settings)
        state.dismissSettings()

        #expect(state.screen == .readyToUnplug, "phase 还是 away，但机器根本没睡，不能显示「外出中」")
    }

    @Test("睡成了才切到「外出中」")
    func verifiedSleepEntersAway() async {
        let (sim, state) = makeHarness { seedBlockers($0) }
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug && !state.isBusy }

        sim.simulateDisplayCount(0)
        await waitUntil { state.sleepOutcome == .slept }

        #expect(state.screen == .away)
        #expect(state.iconState == .away)
    }

    @Test("解析挡住 pmset sleepnow 的进程")
    func parsesPreventSystemSleepHolders() {
        let text = """
        Assertion status system-wide:
           PreventUserIdleSystemSleep     1
           PreventSystemSleep             0
        Listed by owning process:
           pid 5817(Electron): [0x000351ed00019543] 00:03:34 NoIdleSleepAssertion named: "Electron"
           pid 162(WindowServer): [0x0002087300098e3d] 00:00:00 PreventSystemSleep named: "com.apple.WindowServer.PUIDS"
           pid 105(powerd): [0x0002087300018e3e] 23:29:20 PreventUserIdleSystemSleep named: "Powerd"
        """
        let names = PowerSettings.parseSystemSleepBlockers(text)
        #expect(names == ["WindowServer"])
    }
}

@Suite(.serialized)
@MainActor
struct QuitTests {
    @Test("在家退出：直接退，不碰任何设置")
    func quitAtHome() async {
        let (sim, state) = makeHarness()
        var didTerminate = false
        state.terminateApplication = { didTerminate = true }

        state.quitApp()
        await waitUntil { didTerminate }

        #expect(didTerminate)
        #expect(sim.pmsetWrites.isEmpty)
    }

    @Test("外出中退出：先把机器恢复原样再退")
    func quitWhileAwayRestoresFirst() async {
        let (sim, state) = makeHarness { seedBlockers($0) }
        var didTerminate = false
        state.terminateApplication = { didTerminate = true }

        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug && !state.isBusy }

        state.quitApp()
        await waitUntil { didTerminate }

        #expect(didTerminate)
        #expect(state.session == nil)
        #expect(sim.storedState == nil)
        #expect(sim.pmsetValues["disablesleep"] == 1, "退出前必须把 disablesleep 恢复回去")
        #expect(sim.clearedStateCount == 1)
    }

    @Test("设置页那个「退出」：恢复失败同样不许退")
    func quitBlockedWhenRestoreFails() async {
        let (sim, state) = makeHarness { seedBlockers($0) }
        sim.failingRestoreKeys = ["disablesleep"]
        var didTerminate = false
        state.terminateApplication = { didTerminate = true }

        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug && !state.isBusy }

        state.quitApp()
        await waitUntil { !state.isBusy && state.pendingRestore }

        #expect(didTerminate == false)
        #expect(state.pendingRestore)
        #expect(sim.storedState != nil)
        #expect(state.errorMessage != nil)
    }

    @Test("⌘Q / 注销 / 关机那条路：外出中必须先恢复才允许退")
    func prepareForQuitRestoresFirst() async {
        let (sim, state) = makeHarness { seedBlockers($0) }
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug && !state.isBusy }
        #expect(state.needsRestoreBeforeQuit)

        var canQuit: Bool?
        state.prepareForQuit { canQuit = $0 }
        await waitUntil { canQuit != nil }

        #expect(canQuit == true)
        #expect(state.session == nil)
        #expect(sim.pmsetValues["disablesleep"] == 1)
    }

    @Test("恢复不掉就拦住退出，别让用户以为软件已经关了")
    func prepareForQuitBlocksOnRestoreFailure() async {
        let (sim, state) = makeHarness { seedBlockers($0) }
        sim.failingRestoreKeys = ["disablesleep"]
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug && !state.isBusy }

        var canQuit: Bool?
        state.prepareForQuit { canQuit = $0 }
        await waitUntil { canQuit != nil }

        #expect(canQuit == false)
        #expect(state.pendingRestore)
        #expect(sim.storedState != nil)
    }
}

@Suite(.serialized)
@MainActor
struct DisplayDetachTests {
    @Test("拔线后系统留了一块影子屏（数量仍是 1）也必须能睡")
    func phantomDisplayStillCountsAsDetached() async {
        let (sim, state) = makeHarness { seedBlockers($0) }
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug && !state.isBusy }

        // 2026-10-24 09:41 的真实现场：线拔了，active 还是 1。
        sim.simulatePhantomDisplayAfterUnplug()
        await waitUntil { state.sleepOutcome == .slept }

        #expect(state.displaysDetached)
        #expect(state.sleepOutcome == .slept)
        #expect(sim.sleepNowCalls == 1)
    }

    @Test("影子屏沿用了同一个 ID，只有厂商型号变 0，也算拔线")
    func phantomWithSameIDStillCountsAsDetached() async {
        let (sim, state) = makeHarness { seedBlockers($0) }
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug && !state.isBusy }

        // 比 09:41 那次更阴：连 ID 都没换，只是 EDID 认不出来了。
        sim.simulatePhantomWithSameID()
        await waitUntil { state.sleepOutcome == .slept }

        #expect(state.displaysDetached)
        #expect(sim.sleepNowCalls == 1)
    }

    @Test("MacBook + 外接屏：拔掉外接屏，内建屏还在，也算拔线")
    func unpluggingExternalOnLaptopCounts() async {
        let (sim, state) = makeHarness { sim in
            seedBlockers(sim)
            sim.displayCountValue = 2
            sim.onlineIDs = [1, 2]   // 1 = 外接（主），2 = 内建
            sim.mainID = 1
        }
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug && !state.isBusy }

        // 拔掉外接屏：内建屏还在，总数从 2 变 1，不是 0。
        sim.simulateDisplayState(active: 1, online: [2], main: 2)
        await waitUntil { state.sleepOutcome == .slept }

        #expect(state.displaysDetached)
        #expect(sim.sleepNowCalls == 1)
    }

    @Test("Mac mini：唯一外接屏拔掉，集合变空")
    func singleDisplayMachineCounts() async {
        let (sim, state) = makeHarness { seedBlockers($0) }
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug && !state.isBusy }

        sim.simulateDisplayCount(0)
        await waitUntil { state.sleepOutcome == .slept }

        #expect(state.displaysDetached)
        #expect(sim.sleepNowCalls == 1)
    }

    @Test("显示器只是休眠：active 变 0 但还连着，绝不算拔线")
    func displaySleepIsNotDetach() async {
        let (sim, state) = makeHarness { seedBlockers($0) }
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug && !state.isBusy }

        // DPMS：屏幕灭了，但线还插着，online 里还有它。
        sim.simulateDisplayState(active: 0, online: [1], main: 1)
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(state.displaysDetached == false)
        #expect(state.unplugCountdown == nil)
        #expect(sim.sleepNowCalls == 0)
        #expect(state.screen == .readyToUnplug)
    }

    @Test("插回来之后基线重新对得上，倒计时取消")
    func replugCancelsCountdown() async {
        let (sim, state) = makeHarness(sleepDelaySeconds: 30) { seedBlockers($0) }
        state.beginAway()
        await waitUntil { state.screen == .readyToUnplug && !state.isBusy }

        sim.simulateDisplayCount(0)
        await waitUntil { state.unplugCountdown != nil }

        sim.simulateDisplayCount(1)
        await waitUntil { state.unplugCountdown == nil }

        #expect(state.unplugCountdown == nil)
        #expect(state.displaysDetached == false)
        #expect(sim.sleepNowCalls == 0)
    }
}

@Suite(.serialized)
@MainActor
struct OnboardingSafetyTests {    @Test("引导走完不崩，并且落到首页")
    func finishOnboardingLandsOnHome() async {
        let (sim, state) = makeHarness { $0.storedSettings = AppSettings(onboardingDone: false) }
        state.bootstrap()
        #expect(state.screen == .onboarding(1))

        state.advanceOnboarding()
        state.advanceOnboarding()
        state.finishOnboarding()

        #expect(state.screen == .home)
        #expect(sim.storedSettings.onboardingDone)
    }
}
