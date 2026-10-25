import Foundation
import Testing

@testable import HeadlessKnightMaster
@testable import HKMKit

// MARK: - 「试一下」点了没反应
//
// 用户原话：「通知，试一下点了没反应」。
//
// 真实原因是两条叠在一起：
//   1. 应用在最前台时，系统默认**不显示**通知。没人实现 `willPresent`，
//      通知就被静默丢掉——日志里六次「已发送通知」，屏幕上一片空白；
//   2. 界面在 `post()` 之后无条件写「已发送」。`add` 对没授权、专注模式、
//      通知样式设成「无」全都安静地成功，于是这句话经常是假的。
//
// 所以修法不是「多发一次」，而是「发完去核实，然后说实话」。

@MainActor
private func makeState(_ configure: (SimulatedServices) -> Void = { _ in }) -> (SimulatedServices, AppState) {
    let sim = SimulatedServices()
    sim.storedSettings = AppSettings(onboardingDone: true, launchAtLogin: false, sleepDelaySeconds: 1)
    configure(sim)
    let state = AppState(deps: .simulated(sim), timing: Timing(), autoAdvanceDetect: false)
    state.bootstrap()
    return (sim, state)
}

@MainActor
private func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

@Suite("设置页的「试一下」")
struct TestNotificationTests {
    @Test("横幅真弹出来了才说「已弹出」")
    @MainActor
    func reportsShown() async {
        let (sim, state) = makeState { $0.testResult = .shown }
        state.sendTestNotification()
        await waitUntil { sim.testNotificationCount == 1 }
        #expect(state.notificationStatus == NotificationTestResult.shown.summary)
        #expect(state.notificationStatus.contains("已弹出"))
    }

    @Test("被专注模式挡掉时不许说「已发送」")
    @MainActor
    func reportsSuppressed() async {
        let (sim, state) = makeState { $0.testResult = .suppressed }
        state.sendTestNotification()
        await waitUntil { sim.testNotificationCount == 1 }
        // 2026-10-25 之前这里写的是「已发送 · 看屏幕右上角」，而屏幕上什么都没有。
        #expect(!state.notificationStatus.contains("已发送"))
        #expect(state.notificationStatus.contains("挡"))
    }

    @Test("没授权就指路，别让用户干瞪眼")
    @MainActor
    func reportsNotAuthorized() async {
        let (sim, state) = makeState { $0.testResult = .notAuthorized }
        state.sendTestNotification()
        await waitUntil { sim.testNotificationCount == 1 }
        #expect(state.notificationStatus.contains("系统设置"))
    }

    @Test("点一下就发一条，不发两条")
    @MainActor
    func sendsExactlyOne() async {
        let (sim, state) = makeState()
        state.sendTestNotification()
        await waitUntil { sim.testNotificationCount == 1 }
        #expect(sim.testNotificationCount == 1)
    }

    @Test("每一句状态都说人话，而且句末不加句号")
    @MainActor
    func summariesArePlainSentences() {
        let all: [NotificationTestResult] = [
            .shown, .delivered, .suppressed, .notAuthorized, .failed("权限被拒")
        ]
        for result in all {
            let text = result.summary
            #expect(!text.isEmpty)
            #expect(!text.hasSuffix("。"))
            #expect(!text.hasSuffix("."))
            // 别把系统错误原文原样甩给用户。
            #expect(!text.contains("Error Domain"))
        }
    }
}
