import Foundation
import Testing

@testable import HeadlessKnightMaster
@testable import HKMKit

// MARK: - 「它挡了什么、能怎么办」
//
// 检测页原来只写「已持续 50 小时」，用户知道它挡了很久，却不知道挡的是睡眠还是
// 屏幕，也不知道该去哪儿关。下面这些用例锁住的是「说得准」这件事：
// 断言名认得出来就说具体理由，认不出来就老实退回断言类型，绝不编。

private func blocker(
    _ name: String,
    bundle: String? = nil,
    types: [String] = ["PreventUserIdleSystemSleep"],
    names: [String] = [],
    kind: SleepBlocker.Kind = .blocking
) -> SleepBlocker {
    SleepBlocker(
        pid: 4242,
        processName: name,
        bundleIdentifier: bundle,
        assertionTypes: types,
        assertionNames: names,
        durationSeconds: 3600,
        kind: kind
    )
}

@Suite("阻止睡眠的理由")
struct BlockerExplainerTests {
    @Test("Chrome 在放声音：说理由，并指向那个标签页")
    func chromeAudio() {
        let chrome = blocker(
            "Google Chrome",
            bundle: "com.google.Chrome",
            types: ["NoIdleSleepAssertion"],
            names: ["AudioPlayback"]
        )
        #expect(chrome.explanation.reason == "正在放音频")
        #expect(chrome.explanation.suggestion?.contains("标签页") == true)
    }

    @Test("UU：说得出挡的是空闲睡眠，并指向它自己的防休眠开关")
    func uuRemote() {
        let uu = blocker("UU远程", bundle: "com.netease.uuremote")
        #expect(uu.explanation.reason == "不许电脑空闲睡眠")
        #expect(uu.explanation.suggestion?.contains("防休眠") == true)
    }

    @Test("只挡屏幕的断言不会说成「挡睡眠」")
    func displayOnly() {
        let player = blocker(
            "QuickTime Player",
            bundle: "com.apple.QuickTimePlayerX",
            types: ["PreventUserIdleDisplaySleep"],
            kind: .displayOnly
        )
        #expect(player.explanation.reason == "只让屏幕不灭")
        #expect(player.explanation.suggestion == "不影响睡眠，可以不管它")
    }

    @Test("powerd 那句「屏幕亮着就不睡」认得出来")
    func displayIsOn() {
        let powerd = blocker(
            "powerd",
            types: ["PreventUserIdleSystemSleep"],
            names: ["Powerd - Prevent sleep while display is on"]
        )
        #expect(powerd.explanation.reason == "屏幕亮着就不许睡")
    }

    @Test("caffeinate 说成命令行保活")
    func caffeinate() {
        let caffeinate = blocker(
            "caffeinate",
            types: ["PreventUserIdleSystemSleep"],
            names: ["caffeinate command-line tool"]
        )
        #expect(caffeinate.explanation.reason == "caffeinate 在保活")
        #expect(caffeinate.explanation.suggestion?.contains("保活工具") == true)
    }

    @Test("和自己干同一件事的程序会被点出来")
    func headlessPeer() {
        let macHead = blocker(
            "MacHead",
            bundle: "com.example.machead",
            names: ["MacHead: Headless mode active"]
        )
        #expect(macHead.explanation.reason == "它也在做无头模式")
        #expect(macHead.explanation.suggestion == "它和你在做同一件事，退出它")
    }

    @Test("备份中的断言说成正在备份")
    func backupInProgress() {
        let backupd = blocker("backupd", names: ["Time Machine backup in progress"])
        #expect(backupd.explanation.reason == "正在备份")
    }

    @Test("会议软件：提醒退出现在等于挂断")
    func meetingApp() {
        let zoom = blocker("zoom.us", bundle: "us.zoom.xos")
        #expect(zoom.explanation.suggestion?.contains("挂断") == true)
    }

    @Test("认不出来的程序不编理由，只退回断言类型")
    func unknownApp() {
        let tool = blocker("SomeTool", bundle: "com.example.sometool", types: ["InternalPreventSleep"])
        #expect(tool.explanation.reason == "系统内部保持唤醒")
        #expect(tool.explanation.suggestion == "退出它，或者在它的设置里关掉保活")
    }

    @Test("PreventSystemSleep 说得比空闲睡眠更硬")
    func hardSystemSleep() {
        let hard = blocker("Foo", types: ["PreventSystemSleep"])
        #expect(hard.explanation.reason == "不许电脑睡眠")
    }
}

// MARK: - 20 秒 + 只退该退的

private func displayOnlyPlayer() -> SleepBlocker {
    SleepBlocker(
        pid: 66410,
        processName: "QuickTime Player",
        bundleIdentifier: "com.apple.QuickTimePlayerX",
        assertionTypes: ["PreventUserIdleDisplaySleep"],
        durationSeconds: 600,
        kind: .displayOnly
    )
}

@Suite(.serialized)
@MainActor
struct DetectCountdownTests {
    @Test("检测页默认等 20 秒")
    func defaultIsTwentySeconds() {
        #expect(Timing().detectCountdownSeconds == 20)
    }

    @Test("只挡屏幕的程序不退出，页面上单独说明")
    func displayOnlyIsNotKilled() async {
        let harness = AwayHarness { sim in
            sim.blockers = [
                hkmBlocker("UU远程", pid: 8322, bundle: "com.netease.uuremote"),
                displayOnlyPlayer()
            ]
        }
        await harness.enterAway()

        #expect(harness.state.screen == .readyToUnplug)
        #expect(harness.state.killedCount == 1)
        #expect(harness.state.displayOnlyCount == 1)
        #expect(harness.killEvents.count == 1)
    }

    @Test("只有屏幕断言时，连检测页都不用弹")
    func onlyDisplayOnlySkipsDetectPage() async {
        let harness = AwayHarness { sim in
            sim.blockers = [displayOnlyPlayer()]
        }
        await harness.enterAway()

        #expect(harness.killEvents.isEmpty)
        #expect(harness.state.screen == .readyToUnplug)
        #expect(harness.state.displayOnlyCount == 1)
    }
}
