import Foundation
import Testing

@testable import HKMKit

private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

private func makeReport(
    sleptAtAll: Bool = true,
    dark: Int = 0,
    notification: Int = 0,
    real: [WakeEvent] = [],
    batteryStart: Int? = 78,
    batteryEnd: Int? = 74,
    batteryLow: Int? = nil
) -> Report {
    Report(
        startedAt: baseDate,
        endedAt: baseDate.addingTimeInterval(19_320),
        durationSeconds: 19_320,
        batteryStart: batteryStart,
        batteryEnd: batteryEnd,
        batteryLow: batteryLow,
        sleptAtAll: sleptAtAll,
        darkWakeCount: dark,
        notificationWakeCount: notification,
        realWakeCount: real.count,
        realWakes: real
    )
}

private func wake(_ reason: String, duration: Int = 138, kind: WakeEvent.Kind = .real) -> WakeEvent {
    WakeEvent(at: baseDate.addingTimeInterval(600), kind: kind, reason: reason, durationSeconds: duration)
}

@Suite("报告文案")
struct ReportTests {
    @Test("干净的报告标题是结论")
    func cleanHeadline() {
        let report = makeReport(dark: 6, notification: 2)
        #expect(report.headline == "这次很干净")
        #expect(report.hasAnomaly == false)
        #expect(report.suggestion == nil)
        #expect(report.backgroundWakeCount == 8)
    }

    @Test("有真实唤醒时标题报次数")
    func anomalyHeadline() {
        let report = makeReport(real: [wake("UserActivity Assertion")])
        #expect(report.headline == "被唤醒 1 次")
        #expect(report.hasAnomaly)
    }

    @Test("完全没睡时标题最高优先级")
    func neverSleptHeadline() {
        let report = makeReport(sleptAtAll: false, real: [wake("UserActivity Assertion")])
        #expect(report.headline == "这次没睡成")
        #expect(report.suggestion?.text == "这次没睡成，有程序一直在阻止睡眠")
        #expect(report.suggestion?.isActionable == true)
    }

    /// 用户 2026-10-25 的质问：「软件提示有一个拓展坞？我没用过类似的东西。」
    ///
    /// 他按了下键盘，唤醒原因里带着 `smc.70070000`（macOS 每条唤醒原因几乎都有），
    /// 旧代码拿 `smc.` 当特征去匹配「扩展坞供电波动」，于是凭空给他编了个坞。
    @Test("带 smc. 的键盘唤醒不许说成扩展坞")
    func keyboardWakeIsNotADock() {
        let report = makeReport(
            real: [wake("smc.70070000 trackpadkeyboard SMC.OutboxNotEmpty/HID Activity")]
        )
        #expect(report.suggestion?.text.contains("扩展坞") == false)
        #expect(report.suggestion?.text.contains("键盘被按下") == true)
    }

    /// 真插了线就说「有人插了线」，别甩给一个用户没有的设备。
    @Test("插线的唤醒说人话")
    func usbPlugSuggestion() {
        let report = makeReport(real: [wake("smc.70070000 USB-C_plug SMC.OutboxNotEmpty/")])
        #expect(report.suggestion?.text.contains("有人插了线") == true)
        #expect(report.suggestion?.text.contains("扩展坞") == false)
    }

    @Test("局域网唤醒给可操作建议")
    func networkSuggestion() {
        let report = makeReport(real: [wake("Network MAGICWAKE en0")])
        #expect(report.suggestion?.text == "已关闭网络唤醒，仍被局域网设备叫醒")
    }

    @Test("系统维护唤醒给可操作建议")
    func maintenanceSuggestion() {
        let report = makeReport(real: [wake("NUB.SPMISw3IRQ rtc/SleepService")])
        #expect(report.suggestion?.text == "系统维护唤醒，可在设置里彻底关闭")
    }

    @Test("键盘唤醒只陈述事实，不给建议")
    func keyboardIsStatementOnly() {
        let report = makeReport(real: [wake("HID Keyboard")])
        let suggestion = report.suggestion
        #expect(suggestion?.isActionable == false)
        #expect(suggestion?.text.contains("键盘被按下") == true)
    }

    @Test("时长格式化")
    func durationText() {
        #expect(makeReport().durationText == "5 小时 22 分")
    }

    @Test("电量文案")
    func batteryText() {
        #expect(makeReport().batteryText == "掉电 4%")
        #expect(makeReport(batteryEnd: nil).batteryText == "外出期间电量耗尽")
        #expect(makeReport(batteryStart: 50, batteryEnd: 50).batteryText == "没有掉电")
        #expect(makeReport().secondaryBatteryText == "共 5 小时 22 分 · 掉电 4%")
    }

    @Test("回来先插了电源：掉电按期间最低点算，不是按结束那一刻")
    func batteryUsesTheLowestPoint() {
        // 2026-10-25 的真实数字：98% 出门，睡一夜到 96%，回来插上电源充回 98%。
        let report = makeReport(batteryStart: 98, batteryEnd: 98, batteryLow: 96)
        #expect(report.batteryDelta == 2)
        #expect(report.batteryText == "掉电 2%")
        #expect(report.secondaryBatteryText == "共 5 小时 22 分 · 掉电 2%")
    }

    @Test("没记最低点（老报告）：退回按首尾算")
    func batteryFallsBackToEndpoints() {
        let report = makeReport(batteryStart: 98, batteryEnd: 96)
        #expect(report.batteryDelta == 2)
        #expect(report.batteryText == "掉电 2%")
    }

    @Test("报告能编码成设计文档里的字段")
    func encodesDesignFields() throws {
        let report = makeReport(dark: 6, notification: 2, real: [wake("UserActivity Assertion")])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["sleptAtAll"] as? Bool == true)
        #expect(object?["darkWakeCount"] as? Int == 6)
        #expect(object?["notificationWakeCount"] as? Int == 2)
        #expect(object?["realWakeCount"] as? Int == 1)
        #expect((object?["realWakes"] as? [[String: Any]])?.count == 1)
    }
}

@Suite("SleepBlocker 展示")
struct SleepBlockerTests {
    @Test("音频断言用原因描述")
    func audioDetail() {
        let blocker = SleepBlocker(
            pid: 1,
            processName: "Chrome",
            assertionTypes: ["NoIdleSleepAssertion"],
            assertionNames: ["Playing audio"],
            durationSeconds: 30
        )
        #expect(blocker.isAudioAssertion)
        #expect(blocker.detailText == "正在放音频")
    }

    @Test("其余按持续时长描述")
    func durationDetail() {
        let blocker = SleepBlocker(pid: 1, processName: "UURemote", durationSeconds: 50 * 3600)
        #expect(blocker.detailText == "50 小时")
        let short = SleepBlocker(pid: 2, processName: "ChatGPT", durationSeconds: 130)
        #expect(short.detailText == "2 分钟")
    }
}
