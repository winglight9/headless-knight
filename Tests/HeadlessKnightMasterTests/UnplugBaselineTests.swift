import CoreGraphics
import Foundation
import Testing

@testable import HeadlessKnightMaster
@testable import HKMKit

// MARK: - 2026-11-03 中午那次「拔了线，键盘还亮着」
//
// 真机日志：
//   12:40:07 外接屏消失，只剩那块**拆掉的内建屏**（系统照旧报 1512x982）
//   12:40:08 进拔线页，基线记成 `[]`
//   12:40:28 外接屏回来了 —— 可是基线不会自己补
//   12:40:33 用户拔了线，软件一声不响（基线是空集，空集是任何集合的子集；
//            兜底的 `activeDisplayCount == 0` 又被那块假内建屏挡着）
//   12:40:44 他只好手动点「不拔线，现在就睡」，叫了一次没睡成
//   12:41:08 整趟重来 —— 这次基线记到了 `[2]`，一拔就睡了
//
// 根因只有一个：**基线可以记在显示器拓扑翻腾的空档里，而且记空了就永远补不回来。**

@Suite(.serialized)
@MainActor
struct UnplugBaselineTests {
    /// 进拔线页那一刻只有内建（真机上那块是拆掉的）屏在线。
    private func onlyBuiltinAtStart(_ sim: SimulatedServices) {
        sim.builtinIDs = [99]
        sim.simulateDisplayState(active: 1, online: [99], main: 99)
        sim.sleepEvidenceValue = .slept
    }

    @Test("进拔线页时一块外接屏都没有：它回来之后要补记基线，拔线照样会睡")
    func adoptsBaselineWhenDisplayComesBack() async {
        let harness = AwayHarness(unplugPollSeconds: 0.05) { onlyBuiltinAtStart($0) }
        await harness.enterAway()

        #expect(harness.state.screen == .readyToUnplug)
        // 进页面这一刻确实没东西可记——这就是 12:40:08 的现场。
        #expect(harness.state.baselineDisplayIDsForTesting.isEmpty)
        #expect(harness.state.displaysDetached == false)

        // 12:40:28：外接屏回来了。
        harness.sim.simulateDisplayState(active: 1, online: [2], main: 2)
        await AwayHarness.waitUntil { !harness.state.baselineDisplayIDsForTesting.isEmpty }
        #expect(harness.state.baselineDisplayIDsForTesting == [2], "外接屏出现了就得记成基线，否则后面判不出拔线")

        // 用户拔线。
        harness.sim.simulateDisplayCount(0)
        await AwayHarness.waitUntil { harness.state.sleepOutcome == .slept }

        #expect(harness.state.sleepOutcome == .slept)
        #expect(harness.state.screen == .away)
        #expect(harness.sim.sleepNowCalls >= 1, "补记了基线，拔线才叫得动睡眠")
    }

    /// 真机上显示器回调本来就会漏（拔线那一瞬系统自己在重排）。每秒的对账必须
    /// 也能把基线补上——这里直接改 `onlineIDs`，**故意不触发回调**。
    @Test("显示器回调漏掉也不怕：每秒对账会把基线补上")
    func pollAdoptsBaselineWithoutCallback() async {
        let harness = AwayHarness(unplugPollSeconds: 0.05) { onlyBuiltinAtStart($0) }
        await harness.enterAway()
        #expect(harness.state.baselineDisplayIDsForTesting.isEmpty)

        harness.sim.onlineIDs = [2]
        harness.sim.mainID = 2
        await AwayHarness.waitUntil { harness.state.baselineDisplayIDsForTesting == [2] }
        #expect(harness.state.baselineDisplayIDsForTesting == [2])
    }

    /// 补记只发生在拔线页。别的页面上跑到一半的显示器变化不许偷偷改基线。
    @Test("回到首页之后不再补记基线")
    func noAdoptionOutsideReadyToUnplug() async {
        let harness = AwayHarness(unplugPollSeconds: 0.05) { onlyBuiltinAtStart($0) }
        await harness.enterAway()
        harness.state.cancelReadyToUnplug()
        await AwayHarness.waitUntil { harness.state.screen == .home }

        harness.sim.simulateDisplayState(active: 1, online: [2], main: 2)
        await AwayHarness.sleep(seconds: 0.2)
        #expect(harness.state.baselineDisplayIDsForTesting.isEmpty)
    }

    /// 最坏的一种：基线从头到尾都是空的（外接屏一直没再出现）。拆了屏的机器上
    /// 数量那条兜底永远不成立，宽限期一过就得认「眼前没有真屏 = 拔了」。
    @Test("基线一直空着：等过宽限期也要认「拔线」，不能永远不睡")
    func emptyBaselineGraceCountsAsDetached() async {
        let harness = AwayHarness(unplugPollSeconds: 0.05) { sim in
            onlyBuiltinAtStart(sim)
            sim.storedSettings.noBuiltinDisplay = true
        }
        await harness.enterAway()
        #expect(harness.state.screen == .readyToUnplug)
        #expect(harness.state.displaysDetached == false, "宽限期内不许动手：那阵子拓扑还在抖")

        harness.sim.advanceClock(by: 50)
        await AwayHarness.waitUntil { harness.state.sleepOutcome == .slept }
        #expect(harness.state.sleepOutcome == .slept)
        #expect(harness.state.screen == .away)
    }

    /// 没声明「没有内建屏」的普通 MacBook：宽限期过了也不能把「只剩内建屏」
    /// 当成拔线——人家可能只是把外接屏关了、还在盖着盖子用。
    @Test("普通笔记本：只剩内建屏不算拔线")
    func builtinOnlyIsNotDetachedOnNormalMac() async {
        let harness = AwayHarness(unplugPollSeconds: 0.05) { onlyBuiltinAtStart($0) }
        await harness.enterAway()
        harness.sim.advanceClock(by: 120)
        await AwayHarness.sleep(seconds: 0.3)
        #expect(harness.state.displaysDetached == false)
        #expect(harness.state.screen == .readyToUnplug)
    }
}

// MARK: - 「结束外出模式」不能是一个死按钮

@Suite(.serialized)
@MainActor
struct EndAwayEntryPointTests {
    @Test("内存里没有这一趟记录：结束外出也要真的结束，不能什么都不做")
    func finishAwayWithoutSessionReturnsHome() async {
        let harness = AwayHarness()
        await harness.enterAway()
        // 状态文件被外部删掉 / 上一趟已经结束——界面还停在外出页。
        harness.state.discardSession()

        await harness.state.finishAway()

        #expect(harness.state.screen == .home, "以前这条路上按钮点了毫无反应")
        #expect(harness.state.isBusy == false)
        #expect(harness.state.isEndingAway == false)
    }

    @Test("快捷键在首页不做事：用户没在外出的路上")
    func shortcutDoesNothingAtHome() async {
        let harness = AwayHarness()
        #expect(harness.state.screen == .home)
        #expect(harness.state.canEndAway == false)

        harness.state.endAwayByShortcut()
        await AwayHarness.sleep(seconds: 0.1)
        #expect(harness.state.screen == .home)
    }

    @Test("快捷键在外出中会结束这一趟并出报告")
    func shortcutEndsAway() async {
        let harness = AwayHarness { $0.sleepEvidenceValue = .slept }
        await harness.enterAway()
        harness.sim.simulateDisplayCount(0)
        await AwayHarness.waitUntil { harness.state.screen == .away }
        #expect(harness.state.canEndAway)

        harness.state.endAwayByShortcut()
        await AwayHarness.waitUntil { harness.state.screen == .report }
        #expect(harness.state.screen == .report)
        #expect(harness.state.report != nil)
    }

    @Test("快捷键在「可以拔线」页等于取消这一趟")
    func shortcutAbortsOnReadyPage() async {
        let harness = AwayHarness()
        await harness.enterAway()
        #expect(harness.state.screen == .readyToUnplug)

        harness.state.endAwayByShortcut()
        await AwayHarness.waitUntil { harness.state.screen == .home }
        #expect(harness.state.screen == .home)
        #expect(harness.state.displaysDetached == false)
    }
}

// MARK: - 面板摆在哪块屏上

@Suite("面板该贴哪块屏")
struct PanelTargetScreenTests {
    /// 拆掉内建屏的机器：系统眼里还有一块 1512x982 的「内建屏」，真实那块在左边。
    private let phantom = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let real = CGRect(x: -1920, y: 0, width: 1920, height: 1200)

    @Test("锚点落在哪块屏，就用哪块——哪怕第一块是拆掉的假屏")
    func anchorWins() {
        let anchor = CGRect(x: -1900, y: 1150, width: 34, height: 22)
        let picked = PanelPlacement.targetScreen(
            anchor: anchor,
            pointer: CGPoint(x: 200, y: 200),
            screens: [phantom, real]
        )
        #expect(picked == real)
    }

    @Test("锚点是假的（落在所有屏之外）：跟鼠标走，别跟那块假屏")
    func fakeAnchorFallsBackToPointer() {
        let bogus = CGRect(x: -3688, y: 1183, width: 34, height: 22)
        let picked = PanelPlacement.targetScreen(
            anchor: bogus,
            pointer: CGPoint(x: -500, y: 600),
            screens: [phantom, real]
        )
        #expect(picked == real, "2026-11-03 15:45 面板就是这么被摆到假屏上的")
    }

    @Test("什么都没有的时候退回第一块，别返回 nil")
    func fallsBackToFirst() {
        let picked = PanelPlacement.targetScreen(
            anchor: nil,
            pointer: CGPoint(x: 9999, y: 9999),
            screens: [phantom, real]
        )
        #expect(picked == phantom)
    }
}
