import CoreGraphics
import Foundation
import Testing

@testable import HeadlessKnightMaster
@testable import HKMKit

// MARK: - 2026-10-25 那一夜
//
// 用户带着笔记本出门，机器从 00:21 一直睡到早上，一整夜只掉了 4% 的电。
// 软件却：
//   · 01:57 醒来时读不到电源日志，直接把「读不到」当成「没睡」；
//   · 之后每醒一次就叫一次睡、失败一次、弹一条「没能进入睡眠」，一夜七条；
//   · 早上用户开屏，第一眼看到的就是「还没能睡着」；
//   · 而那扇窗口掉在屏幕下面，拖不动也点不到。
//
// 下面每一条都对着其中一个具体环节。

@MainActor
private func makeState(
    sleepVerifySeconds: Double = 0,
    sleepRetrySeconds: Double = 3600,
    _ configure: (SimulatedServices) -> Void = { _ in }
) -> (SimulatedServices, AppState) {
    let sim = SimulatedServices()
    sim.storedSettings = AppSettings(
        onboardingDone: true,
        launchAtLogin: false,
        sleepDelaySeconds: 1
    )
    sim.powerLog = Simulation.log(startingAt: sim.currentDate, sleeps: true, realWake: false)
    configure(sim)
    let state = AppState(
        deps: .simulated(sim),
        timing: Timing(
            countdownTick: 0.01,
            detectPollSeconds: 0.05,
            sleepVerifySeconds: sleepVerifySeconds,
            unplugPollSeconds: 3600,
            sleepRetrySeconds: sleepRetrySeconds
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

@MainActor
private func reachReadyToUnplug(_ state: AppState) async {
    state.beginAway()
    await waitUntil { state.screen == .readyToUnplug && !state.isBusy }
}

@MainActor
private func sleepFailureNotifications(_ sim: SimulatedServices) -> [String] {
    sim.notifications.filter { $0.hasPrefix("没能进入睡眠") }
}

// MARK: - 睡眠证据

@Suite("「叫它睡」之后到底睡没睡")
struct SleepEvidenceTests {
    private func power(lastSleep: Date?, log: String) -> PowerSettings {
        let runner = ScriptedRunner(results: [
            "/usr/bin/pmset": CommandResult(status: 0, stdout: log, stderr: "")
        ])
        return PowerSettings(
            runner: runner,
            executor: RecordingExecutor(),
            lastSleepProvider: { lastSleep }
        )
    }

    private var now: Date { Date(timeIntervalSince1970: 1_760_000_000) }

    private func sleepLine(at date: Date) -> String {
        PowerLogDateFormatter.string(from: date)
            + " Sleep               \tEntering Sleep state due to 'Idle Sleep': Using Batt (Charge: 96%) 7200 secs"
    }

    @Test("内核记着「请求之后睡过」：直接算睡了，不用读那几兆日志")
    func kernelTimestampIsEnough() async {
        let since = now
        let subject = power(lastSleep: since.addingTimeInterval(30), log: "")
        #expect(await subject.sleepEvidence(since: since) == .slept)
    }

    @Test("日志读不出来：结论是「不知道」，不是「没睡」")
    func unreadableLogIsUnknown() async {
        // 这就是 01:57 那次：pmset -g log 什么都没返回。
        let subject = power(lastSleep: now.addingTimeInterval(-3600), log: "")
        #expect(await subject.sleepEvidence(since: now) == .unknown)
    }

    @Test("内核没更新但日志里有 Entering Sleep：仍然算睡了")
    func logRescuesWhenKernelSaysNothing() async {
        // 万一某台机器的 kern.sleeptime 不更新，只信它就会把「睡了」报成「没睡」。
        let since = now
        let subject = power(
            lastSleep: since.addingTimeInterval(-3600),
            log: sleepLine(at: since.addingTimeInterval(120))
        )
        #expect(await subject.sleepEvidence(since: since) == .slept)
    }

    @Test("两边都说没睡：才敢说没睡")
    func bothSayAwake() async {
        let since = now
        let subject = power(
            lastSleep: since.addingTimeInterval(-3600),
            log: sleepLine(at: since.addingTimeInterval(-120))
        )
        #expect(await subject.sleepEvidence(since: since) == .awake)
    }
}

// MARK: - 流程

@Suite(.serialized)
@MainActor
struct SleepTruthFlowTests {
    @Test("机器真的睡了、日志又读不出来：不许报「没睡」")
    func suspendedProcessCountsAsSlept() async {
        let (sim, state) = makeState { sim in
            sim.sleepSucceeds = false
            sim.sleepEvidenceValue = .unknown
            // 进程被挂起 96 分钟 —— 01:57 那次的真实时长。
            sim.advanceClockOnSleepNow = 96 * 60
        }
        await reachReadyToUnplug(state)

        sim.simulateDisplayCount(0)
        await waitUntil { state.sleepOutcome == .slept }

        #expect(state.sleepOutcome == .slept, "墙上时钟跳了 96 分钟，就是睡了")
        #expect(sim.sleepNowCalls == 1, "确认睡过就不该再叫第二次")
        #expect(sleepFailureNotifications(sim).isEmpty)
        #expect(state.screen == .away)
        #expect(state.unplugCountdown == nil)
    }

    @Test("日志读不出来、时钟也没跳：只说「没法确认」，不推送")
    func unreadableLogDoesNotAlarm() async {
        let (sim, state) = makeState { sim in
            sim.sleepSucceeds = false
            sim.sleepEvidenceValue = .unknown
        }
        await reachReadyToUnplug(state)

        sim.simulateDisplayCount(0)
        await waitUntil {
            if case .unverified = state.sleepOutcome { return true }
            return false
        }

        if case .unverified = state.sleepOutcome {} else {
            Issue.record("拿不到证据时必须是 unverified，不能是 failed")
        }
        #expect(sleepFailureNotifications(sim).isEmpty, "不知道就别推「没能进入睡眠」")
        #expect(state.screen == .readyToUnplug)
    }

    @Test("已经确认睡过：显示器再怎么变也不许重新叫睡")
    func noSecondSleepRequestAfterSuccess() async {
        let (sim, state) = makeState()
        await reachReadyToUnplug(state)

        sim.simulateDisplayCount(0)
        await waitUntil { state.sleepOutcome == .slept }
        #expect(state.screen == .away)
        let callsAfterSleep = sim.sleepNowCalls

        // 01:57 那次：用户掀开盖子，内建屏出现，基线里那块外接屏仍然不在。
        // 以前这里会重新起一次 3 秒倒计时，然后连叫三次睡、连弹三条通知。
        sim.builtinIsOnline = true
        sim.simulateDisplayState(active: 1, online: [1], main: 1)
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(sim.sleepNowCalls == callsAfterSleep, "睡着之后再叫就是打扰")
        #expect(state.unplugCountdown == nil)
        #expect(state.screen == .away)
    }

    @Test("盖子开着 = 人在电脑前：自动流程不许把机器弄睡")
    func lidOpenBlocksAutomaticSleep() async {
        let (sim, state) = makeState()
        await reachReadyToUnplug(state)

        // 外接屏拔了，但笔记本盖子开着。
        sim.builtinIsOnline = true
        sim.simulateDisplayState(active: 0, online: [], main: 0)
        try? await Task.sleep(nanoseconds: 300_000_000)

        #expect(sim.sleepNowCalls == 0, "人在电脑前，自动流程不该动手")
        #expect(state.unplugCountdown == nil)
        #expect(state.sleepOutcome == .idle)
    }

    @Test("一夜只提醒一次，不许攒一屏「没能进入睡眠」")
    func onlyOneFailureNotificationPerTrip() async {
        let (sim, state) = makeState(sleepRetrySeconds: 0.05) { sim in
            sim.sleepSucceeds = false
            sim.sleepEvidenceValue = .awake
        }
        await reachReadyToUnplug(state)

        sim.simulateDisplayCount(0)
        await waitUntil {
            if case .failed = state.sleepOutcome { return true }
            return false
        }
        // 后台看门狗会接着重试好几轮。
        await waitUntil(timeout: 3) { sim.sleepNowCalls >= 4 }

        #expect(sim.sleepNowCalls >= 4, "看门狗应该真的重试了")
        #expect(sleepFailureNotifications(sim).count == 1, "重试几次就弹几条，正是那次被刷屏的原因")
    }
}

// MARK: - 报告里的电量

@Suite(.serialized)
@MainActor
struct ReportBatteryTests {
    @Test("回来先插了电源：掉电照样按期间最低点算")
    func reportUsesTheLowestPoint() async {
        // 2026-10-25 的真实过程：98% 出门，睡一夜到 96%，回来插上电源充回 98%，
        // 然后才点「结束外出模式」。旧代码在这时候读到的结束电量是 98%，
        // 报告写成「没有下降」。
        let (sim, state) = makeState { sim in
            sim.batteryLevel = 98
        }
        await reachReadyToUnplug(state)
        sim.simulateDisplayCount(0)
        await waitUntil { state.sleepOutcome == .slept }

        sim.batteryLevel = 96
        // 等一拍 ticker（1 秒一次）把最低点记下来。
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        sim.batteryLevel = 98
        sim.advanceClock(by: 9 * 3600)

        await state.finishAway()

        #expect(state.report?.batteryStart == 98)
        #expect(state.report?.batteryEnd == 98)
        #expect(state.report?.batteryLow == 96)
        #expect(state.report?.batteryText == "掉电 2%")
    }
}

// MARK: - 窗口位置
@Suite("面板不许跑到屏幕外面")
struct PanelPlacementTests {
    /// 这台机器的真实数字：1504×940，菜单栏 24pt，程序坞占掉下面 61pt。
    private let visible = CGRect(x: 0, y: 61, width: 1504, height: 854)
    private let button = CGRect(x: 1063, y: 916, width: 34, height: 24)
    private let content = CGSize(width: 300, height: 466)

    @Test("正常情况：贴在状态栏按钮下面，水平居中")
    func sitsUnderTheButton() {
        let origin = PanelPlacement.origin(anchor: button, content: content, visible: visible)
        #expect(origin.x == 930)
        // 顶边贴着可用区域上沿（离菜单栏留 8pt），不越过按钮。
        #expect(origin.y + content.height <= visible.maxY)
        #expect(origin.y + content.height >= visible.maxY - PanelPlacement.margin - 1)
        let frame = CGRect(origin: origin, size: content)
        #expect(PanelPlacement.isFullyVisible(frame, in: visible))
    }

    @Test("已经掉到屏幕下面的窗口：拉回来")
    func pullsBackFromBelowTheScreen() {
        // 早上的真实现场：顶边 281、高 466 → 底边 -185，按钮全在屏幕外。
        let broken = CGRect(x: 892, y: -185, width: 300, height: 466)
        #expect(!PanelPlacement.isFullyVisible(broken, in: visible))

        let origin = PanelPlacement.origin(anchor: button, content: content, visible: visible)
        let fixed = CGRect(origin: origin, size: content)
        #expect(PanelPlacement.isFullyVisible(fixed, in: visible))
        #expect(fixed.minY >= visible.minY)
    }

    @Test("内容比屏幕还高：底边不许沉到屏幕外")
    func neverBelowTheDock() {
        let tall = CGSize(width: 300, height: 1200)
        let origin = PanelPlacement.origin(anchor: button, content: tall, visible: visible)
        #expect(origin.y >= visible.minY + PanelPlacement.margin)
    }

    @Test("贴着屏幕右边缘的图标：横向夹进来")
    func clampsHorizontally() {
        let edgeButton = CGRect(x: 1470, y: 916, width: 34, height: 24)
        let origin = PanelPlacement.origin(anchor: edgeButton, content: content, visible: visible)
        #expect(origin.x + content.width <= visible.maxX)
        #expect(origin.x >= visible.minX)
    }

    @Test("拿不到状态栏按钮：贴在菜单栏下面，而不是创建时的 (0,0)")
    func fallsBackToMenuBar() {
        let origin = PanelPlacement.origin(anchor: nil, content: content, visible: visible)
        #expect(origin.y == visible.maxY - content.height - PanelPlacement.margin)
        let frame = CGRect(origin: origin, size: content)
        #expect(PanelPlacement.isFullyVisible(frame, in: visible))
    }
}
