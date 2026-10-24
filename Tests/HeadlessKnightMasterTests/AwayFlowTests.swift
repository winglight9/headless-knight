import Foundation
import Testing

@testable import HeadlessKnightMaster
@testable import HKMKit

// MARK: - 夹具
//
// 这些测试存在的唯一理由：之前 81 个测试全绿，用户却连着两次走不通流程。
// 因为那些测试只覆盖纯函数，没有一条把 `AppState` 的状态机从头走到尾。
// 这里每一条都从「点开始外出模式」开始，断言**最终停在哪一页**、
// **失败项是什么级别**、**机器上到底写了什么**。

@MainActor
final class AwayHarness {
    let sim: SimulatedServices
    let state: AppState
    /// 流程自己打出来的每一步，用来断言「跳过检测页」这类看不见的行为。
    private(set) var lines: [String] = []

    init(sleepDelaySeconds: Int = 1, _ configure: (SimulatedServices) -> Void = { _ in }) {
        let sim = SimulatedServices()
        sim.storedSettings = AppSettings(
            onboardingDone: true,
            launchAtLogin: false,
            sleepDelaySeconds: sleepDelaySeconds
        )
        sim.powerLog = Simulation.log(startingAt: sim.currentDate, sleeps: true, realWake: false)
        configure(sim)
        self.sim = sim
        self.state = AppState(
            deps: .simulated(sim),
            timing: Timing(detectCountdownSeconds: 1, countdownTick: 0.01, sleepVerifySeconds: 0, unplugPollSeconds: 3600, sleepRetrySeconds: 3600)
        )
        state.narrator = { [weak self] line in self?.lines.append(line) }
        state.bootstrap()
    }

    /// 点「开始外出模式」，一路等到流程停稳（检测页 / 阻塞页 / 拔线页）。
    func enterAway() async {
        state.beginAway()
        await AwayHarness.waitUntil { self.state.screen != .detecting && !self.state.isBusy }
        await state.waitForFlow()
    }

    /// 拔掉显示器，等到系统睡眠请求发出去。
    func unplug() async {
        sim.simulateDisplayCount(0)
        // 等到「睡没睡」这件事有结论，而不是等到请求发出去——请求发出去不等于睡了。
        await AwayHarness.waitUntil {
            switch self.state.sleepOutcome {
            case .slept, .failed: return true
            case .idle, .requesting: return false
            }
        }
    }

    /// 走完完整一趟：进外出 → 拔线 → 睡 → 若干小时后回来 → 出报告。
    func runFullTrip(awaySeconds: TimeInterval = 5 * 3600 + 22 * 60) async {
        await enterAway()
        await unplug()
        sim.advanceClock(by: awaySeconds)
        await state.finishAway()
    }

    func acknowledge() async {
        await state.acknowledgeReportNow()
    }

    var killEvents: [String] { sim.events.filter { $0.hasPrefix("kill ") } }

    var restoredKeys: [String] { sim.events.filter { $0.hasPrefix("restore ") } }

    static func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    static func sleep(seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - 测试数据

func hkmBlocker(_ name: String, pid: pid_t, bundle: String?) -> SleepBlocker {
    SleepBlocker(
        pid: pid,
        processName: name,
        bundleIdentifier: bundle,
        assertionTypes: ["PreventUserIdleSystemSleep"],
        durationSeconds: 49 * 3600
    )
}

@MainActor
private func twoBlockers(_ sim: SimulatedServices) {
    sim.blockers = [
        hkmBlocker("UU远程", pid: 8322, bundle: "com.netease.uuremote"),
        hkmBlocker("Chrome", pid: 66273, bundle: "com.google.Chrome")
    ]
    sim.sharingLabels = ["com.apple.smbd"]
}

// MARK: - 1. 顺利出门

@Suite(.serialized)
@MainActor
struct AwayFlowHappyPathTests {
    @Test("全部成功：停在「可以拔掉显示器了」，没有任何失败项")
    func allSuccess() async {
        let harness = AwayHarness { twoBlockers($0) }
        await harness.enterAway()

        #expect(harness.state.screen == .readyToUnplug)
        #expect(harness.state.failedItems.isEmpty)
        #expect(harness.state.killedCount == 2)
        #expect(harness.state.displayCount == 1)
        #expect(harness.sim.displayWatcherRunning)
        #expect(harness.state.needsHelperInstall == false)
    }

    @Test("全部成功：五组 pmset 都真的写进去了")
    func powerSettingsWritten() async {
        let harness = AwayHarness { twoBlockers($0) }
        await harness.enterAway()

        let written = Set(harness.sim.pmsetWrites.map(\.key))
        #expect(written == Set(PowerSettings.awayTargets.map(\.key)))
        #expect(harness.sim.pmsetValues["disablesleep"] == 0)
        #expect(harness.sim.pmsetValues["womp"] == 0)
    }

    @Test("拔线后请求睡眠，状态变成外出中")
    func unplugTriggersSleep() async {
        let harness = AwayHarness { twoBlockers($0) }
        await harness.enterAway()
        await harness.unplug()

        #expect(harness.state.screen == .away)
        #expect(harness.state.iconState == .away)
        #expect(harness.sim.sleepNowCalls == 1)
        #expect(harness.state.session?.displayDetachedAt != nil)
        #expect(harness.state.session?.sleepRequestedAt != nil)
    }

    @Test("没有程序阻止睡眠时跳过检测页，不让用户白等 10 秒")
    func skipsDetectingWhenNoBlockers() async {
        let harness = AwayHarness { sim in
            sim.blockers = []
        }
        await harness.enterAway()

        #expect(harness.state.screen == .readyToUnplug)
        #expect(harness.state.blockers.isEmpty)
        #expect(harness.lines.contains { $0.contains("跳过检测页") })
        #expect(harness.state.completedActions.first == "没有程序在阻止睡眠")
    }

    @Test("有程序阻止睡眠时走检测页，倒计时结束后自动继续")
    func countdownFinishesAndContinues() async {
        let harness = AwayHarness { twoBlockers($0) }
        harness.state.beginAway()
        #expect(harness.state.screen == .detecting)
        #expect(harness.state.countdownTotal == 1)

        await AwayHarness.waitUntil { harness.state.screen != .detecting }
        await harness.state.waitForFlow()

        #expect(harness.state.screen == .readyToUnplug)
        #expect(harness.lines.contains { $0.contains("[1/8] 扫描断言… 发现 2 个") })
    }
}

// MARK: - 2. 关键项失败必须拦住

@Suite(.serialized)
@MainActor
struct AwayFlowCriticalFailureTests {
    @Test("一个程序关不掉：停在阻塞页，失败项是 critical")
    func unkillableAppBlocks() async {
        let harness = AwayHarness { sim in
            twoBlockers(sim)
            sim.killOutcomes["UU远程"] = .failed("无法自动退出")
        }
        await harness.enterAway()

        #expect(harness.state.screen == .blocked)
        #expect(harness.state.failedItems.count == 1)
        #expect(harness.state.criticalFailures.count == 1)
        #expect(harness.state.failedItems.first?.title == "UU远程")
        // 阻塞页要列出还活着的那个，用户才知道去关谁。
        #expect(harness.state.blockers.map(\.processName) == ["UU远程"])
    }

    @Test("程序退出后又被 launchd 拉起来：必须识别成失败，不能误报成功")
    func respawnedAppBlocks() async {
        let harness = AwayHarness { sim in
            twoBlockers(sim)
            sim.respawnsAfterKill = true
        }
        await harness.enterAway()

        #expect(harness.state.screen == .blocked)
        #expect(harness.state.criticalFailures.count == 2)
        #expect(harness.state.failedItems.allSatisfy { $0.detail.contains("又自己起来了") })
        #expect(harness.state.blockers.count == 2)
    }

    @Test("蓝牙关不掉：停在阻塞页，标题是蓝牙")
    func bluetoothFailureBlocks() async {
        let harness = AwayHarness { sim in
            twoBlockers(sim)
            sim.bluetoothSetFailure = "蓝牙状态没有变化"
        }
        await harness.enterAway()

        #expect(harness.state.screen == .blocked)
        #expect(harness.state.criticalFailures.count == 1)
        #expect(harness.state.failedItems.first?.title == "蓝牙")
        // 英文原文不许漏到界面上。
        #expect(harness.state.failedItems.first?.detail.contains("Bluetooth") == false)
    }

    @Test("pmset 写失败：停在阻塞页，能指出是哪一项")
    func pmsetFailureBlocks() async {
        let harness = AwayHarness { sim in
            twoBlockers(sim)
            sim.failingPmsetKeys = ["womp"]
        }
        await harness.enterAway()

        #expect(harness.state.screen == .blocked)
        #expect(harness.state.criticalFailures.count == 1)
        #expect(harness.state.failedItems.first?.title == "睡眠设置 womp")
    }

    @Test("后台服务没装：只报一条汇总失败，不是五条，并且给出安装入口")
    func helperMissingOffersInstall() async {
        let harness = AwayHarness { sim in
            twoBlockers(sim)
            sim.helperInstalled = false
        }
        await harness.enterAway()

        #expect(harness.state.screen == .blocked)
        #expect(harness.state.failedItems.count == 1)
        #expect(harness.state.failedItems.first?.detail == "后台服务没有安装")
        #expect(harness.state.needsHelperInstall)
        // 一条失败就短路，不该把五个键都试一遍（每个都可能等 20 秒超时）。
        #expect(harness.sim.pmsetWrites.isEmpty)
    }

    @Test("装好后端服务后自动重跑整条流程，并保留最初的快照")
    func helperInstallRecovers() async {
        let harness = AwayHarness { sim in
            twoBlockers(sim)
            sim.helperInstalled = false
        }
        await harness.enterAway()
        #expect(harness.state.screen == .blocked)

        await harness.state.installHelperFromBlockedNow()

        #expect(harness.sim.helperInstallAttempts == 1)
        #expect(harness.state.screen == .readyToUnplug)
        #expect(harness.state.failedItems.isEmpty)
        #expect(harness.state.needsHelperInstall == false)
        // 关键：重跑不能重新拍快照，否则恢复时会把「外出中」的设置当成原始设置。
        #expect(harness.state.session?.snapshot.pmset["disablesleep"] == 1)
        #expect(harness.state.session?.snapshot.pmset["sleep"] == 0)
    }

    @Test("阻塞页上「仍然继续」：进入拔线页，但报告会写明有东西没搞定")
    func continueAnywayProceeds() async {
        let harness = AwayHarness { sim in
            twoBlockers(sim)
            sim.killOutcomes["UU远程"] = .failed("无法自动退出")
        }
        await harness.enterAway()
        #expect(harness.state.screen == .blocked)

        harness.state.continueAnyway()

        #expect(harness.state.screen == .readyToUnplug)
        #expect(harness.state.criticalFailures.isEmpty)
        #expect(harness.state.session?.snapshot.failedItems.isEmpty == false)
    }

    @Test("「我处理好了」：手动退出后重扫通过，进入拔线页")
    func retryAfterManualFixSucceeds() async {
        let harness = AwayHarness { sim in
            twoBlockers(sim)
            sim.killOutcomes["UU远程"] = .failed("无法自动退出")
        }
        await harness.enterAway()
        #expect(harness.state.screen == .blocked)

        harness.sim.blockers = []
        await harness.state.retryAfterManualFixNow()

        #expect(harness.state.screen == .readyToUnplug)
        #expect(harness.state.failedItems.isEmpty)
        #expect(harness.state.blockers.isEmpty)
    }

    @Test("「我处理好了」但程序还在：留在阻塞页，不假装成功")
    func retryAfterManualFixStillBlocked() async {
        let harness = AwayHarness { sim in
            twoBlockers(sim)
            sim.killOutcomes["UU远程"] = .failed("无法自动退出")
        }
        await harness.enterAway()

        await harness.state.retryAfterManualFixNow()

        #expect(harness.state.screen == .blocked)
        #expect(harness.state.criticalFailures.count == 1)
        #expect(harness.state.failedItems.first?.detail.contains("请手动退出") == true)
    }
}

// MARK: - 3. 优化项失败不许拦住

@Suite(.serialized)
@MainActor
struct AwayFlowOptionalFailureTests {
    @Test("Time Machine 关不掉：照常出门，只留一条 optional 小字")
    func timeMachineFailureDoesNotBlock() async {
        let harness = AwayHarness { sim in
            twoBlockers(sim)
            sim.timeMachineIsOn = true
            sim.timeMachineDisableFailure = "tmutil: disable requires Full Disk Access privileges."
        }
        await harness.enterAway()

        #expect(harness.state.screen == .readyToUnplug)
        #expect(harness.state.criticalFailures.isEmpty)
        #expect(harness.state.optionalFailures.count == 1)
        #expect(harness.state.failedItems.first?.title == "Time Machine")
        // shell 原文必须被翻译掉。
        #expect(harness.state.failedItems.first?.detail == "需要额外权限，这一项不影响睡眠")
    }

    @Test("共享服务关不掉：照常出门，失败项是 optional")
    func sharingFailureDoesNotBlock() async {
        let harness = AwayHarness { sim in
            twoBlockers(sim)
            sim.sharingFailure = "Operation not permitted"
        }
        await harness.enterAway()

        #expect(harness.state.screen == .readyToUnplug)
        #expect(harness.state.optionalFailures.count == 1)
        #expect(harness.state.failedItems.first?.title == "共享服务")
        #expect(harness.state.failedItems.first?.severity == .optional)
    }

    @Test("没开备份时根本不去动 tmutil")
    func timeMachineSkippedWhenOff() async {
        let harness = AwayHarness { sim in
            twoBlockers(sim)
            sim.timeMachineIsOn = false
        }
        await harness.enterAway()

        #expect(harness.state.screen == .readyToUnplug)
        #expect(harness.sim.events.contains("tm disable") == false)
        #expect(harness.state.session?.snapshot.timeMachineEnabled == false)
    }
}

// MARK: - 4. 拔线、睡眠、插回

@Suite(.serialized)
@MainActor
struct AwayFlowDisplayTests {
    @Test("从两个显示器拔掉一个：不该触发睡眠")
    func removingOneOfTwoDisplaysDoesNotSleep() async {
        let harness = AwayHarness { sim in
            twoBlockers(sim)
            sim.displayCountValue = 2
        }
        await harness.enterAway()
        #expect(harness.state.displayCount == 2)

        harness.sim.simulateDisplayCount(1)
        await AwayHarness.sleep(seconds: 0.3)

        #expect(harness.state.screen == .readyToUnplug)
        #expect(harness.state.unplugCountdown == nil)
        #expect(harness.sim.sleepNowCalls == 0)
    }

    @Test("全部拔掉：进入睡眠倒计时并请求睡眠")
    func removingAllDisplaysSleeps() async {
        let harness = AwayHarness { sim in
            twoBlockers(sim)
            sim.displayCountValue = 2
        }
        await harness.enterAway()

        harness.sim.simulateDisplayCount(0)
        // 等到「睡没睡」有结论：请求发出去不等于睡了，验证完才会切到「外出中」。
        await AwayHarness.waitUntil { harness.state.sleepOutcome == .slept }

        #expect(harness.sim.sleepNowCalls == 1)
        #expect(harness.state.screen == .away)
    }

    @Test("倒计时还没走完就把线插回来：取消睡眠，不许硬睡")
    func replugDuringCountdownCancels() async {
        let harness = AwayHarness(sleepDelaySeconds: 30) { twoBlockers($0) }
        await harness.enterAway()

        harness.sim.simulateDisplayCount(0)
        #expect(harness.state.unplugCountdown != nil)

        harness.sim.simulateDisplayCount(1)
        #expect(harness.state.unplugCountdown == nil)

        await AwayHarness.sleep(seconds: 0.6)
        #expect(harness.sim.sleepNowCalls == 0)
        #expect(harness.state.screen == .readyToUnplug)
        #expect(harness.lines.contains { $0.contains("插回来了") })
    }

    // 设计文档 3.1 第 9 项：请求睡眠失败要重试；而且失败后**不许**再切到
    // 「外出中」，更不许在界面上写「系统已进入睡眠」——2026-10-24 早上那次
    // 「拔了线键盘灯一直亮着」就是被这句话骗的。
    @Test("请求睡眠失败：重试之后仍失败，就必须留在拔线页并说实话")
    func sleepNowFailureIsReported() async {
        let harness = AwayHarness { sim in
            twoBlockers(sim)
            sim.sleepNowFails = "pmset: sleepnow failed"
            sim.sleepSucceeds = false
            sim.sleepBlockers = ["WindowServer"]
        }
        await harness.enterAway()
        await harness.unplug()

        #expect(harness.sim.sleepNowCalls == 3)          // 重试过，不是一次就放弃
        #expect(harness.state.screen == .readyToUnplug)  // 绝不假装已经出门
        #expect(harness.state.errorMessage != nil)
        #expect(harness.state.session?.sleepRequestedAt != nil)
        if case let .failed(reason) = harness.state.sleepOutcome {
            #expect(reason.contains("WindowServer"))
        } else {
            Issue.record("睡眠失败必须落成 .failed，而不是被吞掉")
        }
    }

    @Test("请求睡眠成功但系统其实没睡：同样不许谎报")
    func sleepNowSilentlyDoesNothing() async {
        let harness = AwayHarness { sim in
            twoBlockers(sim)
            sim.sleepSucceeds = false
        }
        await harness.enterAway()
        await harness.unplug()

        #expect(harness.state.screen == .readyToUnplug)
        #expect(harness.state.sleepOutcome != .slept)
    }

    @Test("取消拔线：恢复设置并回到首页，不留半截状态文件")
    func cancelReadyToUnplugRestores() async {
        let harness = AwayHarness { twoBlockers($0) }
        await harness.enterAway()

        harness.state.cancelReadyToUnplug()
        await AwayHarness.waitUntil { harness.state.screen == .home }

        #expect(harness.state.screen == .home)
        #expect(harness.state.session == nil)
        #expect(harness.sim.storedState == nil)
        #expect(harness.sim.pmsetValues["disablesleep"] == 1)
        #expect(harness.sim.displayWatcherRunning == false)
    }
}

// MARK: - 5. 取消检测

@Suite(.serialized)
@MainActor
struct AwayFlowCancelTests {
    @Test("检测页上点取消：回首页，一个字节都不写")
    func cancelDuringDetectingWritesNothing() async {
        let harness = AwayHarness { twoBlockers($0) }
        harness.state.beginAway()
        #expect(harness.state.screen == .detecting)

        harness.state.cancelDetecting()

        #expect(harness.state.screen == .home)
        #expect(harness.state.blockers.isEmpty)
        #expect(harness.state.isBusy == false)
        #expect(harness.sim.savedStates.isEmpty)
        #expect(harness.sim.pmsetWrites.isEmpty)
        #expect(harness.sim.storedState == nil)
    }

    @Test("检测页上点「立即关闭」：跳过剩余倒计时直接开始流程")
    func closeImmediatelyStartsSequence() async {
        let harness = AwayHarness { twoBlockers($0) }
        harness.state.beginAway()
        #expect(harness.state.screen == .detecting)

        harness.state.closeImmediately()
        await AwayHarness.waitUntil { harness.state.screen == .readyToUnplug }
        await harness.state.waitForFlow()

        #expect(harness.state.screen == .readyToUnplug)
        #expect(harness.state.countdown == 0)
    }

    @Test("连点两下「开始外出模式」：只跑一条流程")
    func doubleClickRunsOneFlow() async {
        let harness = AwayHarness { twoBlockers($0) }

        harness.state.beginAway()
        harness.state.beginAway()

        await AwayHarness.waitUntil { harness.state.screen != .detecting && !harness.state.isBusy }
        await harness.state.waitForFlow()

        // 每个程序只该被关一次；两条流程会变成四次。
        #expect(harness.killEvents.count == 2)
        #expect(harness.state.killedCount == 2)
        #expect(harness.sim.pmsetWrites.count == PowerSettings.awayTargets.count)
    }
}

// MARK: - 6. 出报告

@Suite(.serialized)
@MainActor
struct AwayFlowReportTests {
    @Test("干净的一趟：报告说「这次很干净」，图标回白")
    func cleanReport() async {
        let harness = AwayHarness { twoBlockers($0) }
        await harness.runFullTrip()

        #expect(harness.state.screen == .report)
        #expect(harness.state.report?.headline == "这次很干净")
        #expect(harness.state.report?.sleptAtAll == true)
        #expect(harness.state.report?.realWakeCount == 0)
        #expect(harness.state.iconState == .home)
        #expect(harness.state.report?.durationSeconds == 5 * 3600 + 22 * 60)
    }

    @Test("暗唤醒要算出来，不能当成一次没醒")
    func darkWakesCounted() async {
        let harness = AwayHarness { twoBlockers($0) }
        await harness.runFullTrip()

        #expect(harness.state.report?.darkWakeCount == 2)
        #expect(harness.state.report?.backgroundWakeCount == 2)
    }

    @Test("叫它睡它没睡：报告首行必须是「这次没睡成」")
    func noSleepReport() async {
        let harness = AwayHarness { sim in
            twoBlockers(sim)
            sim.powerLog = Simulation.log(startingAt: sim.currentDate, sleeps: false, realWake: false)
        }
        await harness.runFullTrip()

        #expect(harness.state.report?.headline == "这次没睡成")
        #expect(harness.state.report?.sleptAtAll == false)
        #expect(harness.state.iconState == .alert)
        #expect(harness.state.report?.failedItems.contains { $0.contains("没有进入睡眠") } == true)
    }

    @Test("期间被真实唤醒：报告说「被唤醒 1 次」，图标变红")
    func realWakeReport() async {
        let harness = AwayHarness { sim in
            twoBlockers(sim)
            sim.powerLog = Simulation.log(startingAt: sim.currentDate, sleeps: true, realWake: true)
        }
        await harness.runFullTrip()

        #expect(harness.state.report?.headline == "被唤醒 1 次")
        #expect(harness.state.report?.realWakeCount == 1)
        #expect(harness.state.report?.realWakes.count == 1)
        #expect(harness.state.iconState == .alert)
    }

    @Test("报告落盘，重启后还能看到")
    func reportPersisted() async {
        let harness = AwayHarness { twoBlockers($0) }
        await harness.runFullTrip()

        #expect(harness.sim.storedReports.count == 1)
        #expect(harness.state.lastReport?.headline == "这次很干净")
        #expect(harness.sim.storedState?.phase == .audited)
    }

    @Test("离开期间机器重启过：报告要标出来")
    func rebootDetected() async {
        let harness = AwayHarness { twoBlockers($0) }
        await harness.enterAway()
        await harness.unplug()
        harness.sim.bootTimeValue += 500
        harness.sim.advanceClock(by: 3600)
        await harness.state.finishAway()

        #expect(harness.state.report?.rebooted == true)
    }
}

// MARK: - 7. 恢复

@Suite(.serialized)
@MainActor
struct AwayFlowRestoreTests {
    @Test("正常恢复：pmset 回到最初的值，状态文件清掉")
    func restorePutsEverythingBack() async {
        let harness = AwayHarness { twoBlockers($0) }
        await harness.runFullTrip()
        await harness.acknowledge()

        #expect(harness.state.screen == .home)
        #expect(harness.state.session == nil)
        #expect(harness.sim.storedState == nil)
        #expect(harness.sim.clearedStateCount >= 1)
        #expect(harness.sim.pmsetValues["disablesleep"] == 1)
        #expect(harness.sim.pmsetValues["sleep"] == 0)
        #expect(harness.sim.pmsetValues["womp"] == 1)
        #expect(harness.sim.pmsetValues["powernap"] == 1)
        #expect(harness.sim.pmsetValues["tcpkeepalive"] == 1)
        #expect(harness.sim.bluetoothState == 1)
        #expect(harness.sim.sharingLabels == ["com.apple.smbd"])
    }

    @Test("恢复失败必须能被看到：写进刚生成的那份报告")
    func restoreFailureLandsInReport() async {
        let harness = AwayHarness { sim in
            twoBlockers(sim)
            sim.failingRestoreKeys = ["disablesleep"]
        }
        await harness.runFullTrip()
        await harness.acknowledge()

        #expect(harness.state.screen == .home)
        #expect(harness.state.errorMessage != nil)
        let stored = harness.sim.storedReports.last
        #expect(stored?.failedItems.contains { $0.contains("恢复 disablesleep") } == true)
        #expect(harness.state.lastReport?.failedItems.isEmpty == false)
    }

    @Test("没关过 Time Machine 就不许在恢复时把它打开")
    func restoreDoesNotEnableTimeMachineItNeverDisabled() async {
        let harness = AwayHarness { sim in
            twoBlockers(sim)
            sim.timeMachineIsOn = false
        }
        await harness.runFullTrip()
        await harness.acknowledge()

        #expect(harness.sim.events.contains("tm enable") == false)
        #expect(harness.sim.timeMachineIsOn == false)
    }

    @Test("真的关过 Time Machine 才恢复它")
    func restoreEnablesTimeMachineWhenWeDisabledIt() async {
        let harness = AwayHarness { sim in
            twoBlockers(sim)
            sim.timeMachineIsOn = true
        }
        await harness.runFullTrip()
        #expect(harness.state.session?.snapshot.timeMachineEnabled == true)

        await harness.acknowledge()

        #expect(harness.sim.events.contains("tm enable"))
        #expect(harness.sim.timeMachineIsOn == true)
    }

    @Test("状态文件丢了也能恢复：用安全默认值，并且说明原因")
    func restoreWithoutStateUsesSafeDefaults() async {
        let harness = AwayHarness { twoBlockers($0) }
        await harness.enterAway()

        harness.sim.storedState = nil
        harness.state.discardSession()
        await harness.acknowledge()

        #expect(harness.state.screen == .home)
        #expect(harness.state.failedItems.contains { $0.title == "状态文件" })
        // 安全默认值 = 把蓝牙打开，这台机器必须保持可达。
        #expect(harness.sim.bluetoothState == 1)
    }
}

// MARK: - 8. 从阻塞页退出

@Suite(.serialized)
@MainActor
struct AwayFlowAbortTests {
    @Test("阻塞页上「算了，恢复原设置」：设置回到原样，回首页，之后还能重新开始")
    func abortFromBlockedRestores() async {
        let harness = AwayHarness { sim in
            twoBlockers(sim)
            sim.killOutcomes["UU远程"] = .failed("无法自动退出")
        }
        await harness.enterAway()
        #expect(harness.state.screen == .blocked)

        harness.state.abortAway()
        await AwayHarness.waitUntil { harness.state.screen == .home }

        #expect(harness.state.screen == .home)
        #expect(harness.state.session == nil)
        #expect(harness.sim.storedState == nil)
        #expect(harness.sim.pmsetValues["disablesleep"] == 1)
        #expect(harness.sim.pmsetValues["womp"] == 1)
        #expect(harness.sim.bluetoothState == 1)

        // 退出之后必须能重新开始，不能被 phase == .away 卡死。
        harness.sim.killOutcomes = [:]
        await harness.enterAway()
        #expect(harness.state.screen == .readyToUnplug)
    }
}

// MARK: - 9. 图标点击不该结束还没开始的外出
//
// 用户那两条 16 秒 / 41 秒的失败记录就是这么来的：在「可以拔掉显示器了」
// 那一页点了一下菜单栏图标，phase 已经是 .away，于是被当成「结束外出」，
// 立刻生成一份「这次没睡成」。

@Suite(.serialized)
@MainActor
struct AwayFlowIconTapRegressionTests {
    @Test("在「可以拔掉显示器了」页点图标：只弹面板，不结束外出")
    func tapOnReadyToUnplugDoesNotFinish() async {
        let harness = AwayHarness { twoBlockers($0) }
        await harness.enterAway()
        #expect(harness.state.screen == .readyToUnplug)

        harness.state.handleIconTap()
        await AwayHarness.sleep(seconds: 0.2)

        #expect(harness.state.screen == .readyToUnplug)
        #expect(harness.state.report == nil)
        #expect(harness.sim.storedReports.isEmpty)
        #expect(harness.state.session?.phase == .away)
    }

    @Test("倒计时期间点图标：不该结束外出")
    func tapDuringCountdownDoesNotFinish() async {
        let harness = AwayHarness(sleepDelaySeconds: 30) { twoBlockers($0) }
        await harness.enterAway()
        harness.sim.simulateDisplayCount(0)

        harness.state.handleIconTap()
        await AwayHarness.sleep(seconds: 0.1)

        #expect(harness.state.report == nil)
        #expect(harness.sim.storedReports.isEmpty)
    }

    @Test("真的睡过之后再点图标才结束外出")
    func tapAfterSleepFinishes() async {
        let harness = AwayHarness { twoBlockers($0) }
        await harness.enterAway()
        await harness.unplug()
        #expect(harness.state.screen == .away)

        harness.sim.advanceClock(by: 3600)
        harness.state.handleIconTap()
        await AwayHarness.waitUntil { harness.state.screen == .report }

        #expect(harness.state.screen == .report)
        #expect(harness.sim.storedReports.count == 1)
    }
}
