import Foundation
import Testing

@testable import HKMKit

/// Lines copied verbatim from `pmset -g log` on the target machine.
private enum Samples {
    static let sleepEnter = "2026-10-22 13:17:25 +0800 Sleep               \tEntering Sleep state due to 'Sleep Service Back to Sleep':TCPKeepAlive=active Using Batt (Charge:66%) 947 secs"
    static let darkWake = "2026-10-22 13:33:12 +0800 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to NUB.SPMISw3IRQ nub-spmi0.0x02 rtc/SleepService Using BATT (Charge:66%) 27 secs"
    static let notificationWake = "2026-10-22 15:49:32 +0800 Wake                \tDarkWake to FullWake from Deep Idle [CDNVAPB] : due to Notification Using AC (Charge:65%) 2 secs"
    static let userActivityWake = "2026-10-22 15:49:39 +0800 Wake                \tDarkWake to FullWake from Deep Idle [CDNVA] : due to UserActivity Assertion Using AC (Charge:65%)"
    static let darkWakeExit = "2026-10-22 15:49:34 +0800 Sleep               \tEntering DarkWake state due to 'Notification Wake Back to Sleep':TCPKeepAlive=active Using AC (Charge:65%) 5 secs"
    static let wakeRequests = "2026-10-22 14:35:28 +0800 Wake Requests      \t[process=mDNSResponder request=Maintenance deltaSecs=3236 wakeAt=2026-10-22 15:29:24]"
    static let assertions = "2026-10-22 15:49:32 +0800 Assertions          \tPID 448(WindowServer) Created PreventSystemSleep \"com.apple.WindowServer.PUIDS\" 00:00:00"
}

private func date(_ text: String) -> Date {
    guard let value = PowerLogDateFormatter.date(from: text) else {
        fatalError("bad fixture timestamp \(text)")
    }
    return value
}

@Suite("WakeAuditor 解析")
struct WakeAuditorParsingTests {
    @Test("五种行首都能识别")
    func parsesAllLineKinds() {
        let log = [
            Samples.sleepEnter,
            Samples.darkWake,
            Samples.notificationWake,
            Samples.userActivityWake,
            Samples.darkWakeExit
        ].joined(separator: "\n")

        let entries = WakeAuditor.parse(log)
        #expect(entries.count == 5)
        #expect(entries[0].kind == .sleepEnter)
        #expect(entries[1].kind == .darkWakeStart)
        #expect(entries[2].kind == .fullWake)
        #expect(entries[3].kind == .fullWake)
        #expect(entries[4].kind == .darkWakeExit)
    }

    @Test("reason 用 due to … Using 提取")
    func extractsReason() {
        let entry = WakeAuditor.parse(Samples.darkWake).first
        #expect(entry?.reason == "NUB.SPMISw3IRQ nub-spmi0.0x02 rtc/SleepService")
    }

    @Test("时长用行尾 N secs 提取")
    func extractsDuration() {
        #expect(WakeAuditor.parse(Samples.darkWake).first?.durationSeconds == 27)
        #expect(WakeAuditor.parse(Samples.notificationWake).first?.durationSeconds == 2)
        // 这一行没有 secs，时长必须是 nil 而不是 0
        #expect(WakeAuditor.parse(Samples.userActivityWake).first?.durationSeconds == nil)
    }

    @Test("Wake Requests 这种同前缀的域不会被当成唤醒")
    func ignoresWakeRequestsDomain() {
        #expect(WakeAuditor.parse(Samples.wakeRequests).isEmpty)
        #expect(WakeAuditor.parse(Samples.assertions).isEmpty)
    }

    @Test("时间戳解析带时区")
    func parsesTimestamp() {
        let parsed = WakeAuditor.parseTimestamp("2026-10-22 13:33:12 +0800")
        #expect(parsed != nil)
        #expect(parsed == date("2026-10-22 13:33:12 +0800"))
    }
}

@Suite("WakeAuditor 分类")
struct WakeAuditorClassificationTests {
    @Test("UserActivity 是真实唤醒")
    func userActivityIsReal() {
        #expect(WakeAuditor.classify(reason: "UserActivity Assertion", durationSeconds: nil) == .real)
    }

    @Test("HID 是真实唤醒")
    func hidIsReal() {
        #expect(WakeAuditor.classify(reason: "HID Activity", durationSeconds: 1) == .real)
    }

    @Test("通知且不足 5 秒是通知唤醒")
    func notificationIsSoft() {
        #expect(WakeAuditor.classify(reason: "Notification", durationSeconds: 2) == .notification)
    }

    @Test("全唤醒超过 5 秒算真实唤醒")
    func longFullWakeIsReal() {
        #expect(WakeAuditor.classify(reason: "Notification", durationSeconds: 5) == .real)
    }

    @Test("没有时长的全唤醒按真实唤醒处理")
    func missingDurationIsReal() {
        #expect(WakeAuditor.classify(reason: "smc.70070000 USB-C_plug", durationSeconds: nil) == .real)
    }
}

@Suite("WakeAuditor 审计")
struct WakeAuditorAuditTests {
    private var sessionLog: String {
        [
            "2026-10-23 21:01:00 +0800 Sleep               \tEntering Sleep state due to 'Sleep Service Back to Sleep':TCPKeepAlive=active Using Batt (Charge:78%) 600 secs",
            "2026-10-23 21:11:00 +0800 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to NUB.SPMISw3IRQ nub-spmi0.0x02 rtc/SleepService Using BATT (Charge:77%) 27 secs",
            "2026-10-23 21:11:27 +0800 Sleep               \tEntering Sleep state due to 'Sleep Service Back to Sleep':TCPKeepAlive=active Using Batt (Charge:77%) 600 secs",
            "2026-10-23 21:21:27 +0800 Wake                \tDarkWake to FullWake from Deep Idle [CDNVAPB] : due to Notification Using AC (Charge:77%) 2 secs",
            "2026-10-23 21:21:29 +0800 Sleep               \tEntering DarkWake state due to 'Notification Wake Back to Sleep':TCPKeepAlive=active Using AC (Charge:77%) 5 secs",
            "2026-10-23 21:30:00 +0800 Wake                \tDarkWake to FullWake from Deep Idle [CDNVA] : due to UserActivity Assertion Using AC (Charge:76%) 138 secs",
            "2026-10-23 21:32:18 +0800 Sleep               \tEntering Sleep state due to 'Sleep Service Back to Sleep':TCPKeepAlive=active Using Batt (Charge:76%) 900 secs"
        ].joined(separator: "\n")
    }

    private let startedAt = date("2026-10-23 21:00:00 +0800")
    private let endedAt = date("2026-10-23 23:00:00 +0800")

    @Test("正常区间：一暗一通知一真实")
    func countsEachKind() {
        let result = WakeAuditor().audit(
            log: sessionLog,
            startedAt: startedAt,
            endedAt: endedAt,
            displayDetachedAt: nil
        )
        #expect(result.sleptAtAll)
        #expect(result.sleepStart == date("2026-10-23 21:01:00 +0800"))
        #expect(result.darkWakeCount == 1)
        #expect(result.notificationWakeCount == 1)
        #expect(result.realWakeCount == 1)
        #expect(result.realWakes.first?.reason == "UserActivity Assertion")
        #expect(result.realWakes.first?.durationSeconds == 138)
    }

    @Test("区间起点是 startedAt 之后第一条 Entering Sleep")
    func ignoresSleepBeforeStart() {
        let log = """
        2026-10-23 20:00:00 +0800 Sleep               \tEntering Sleep state due to 'Idle':TCPKeepAlive=active Using Batt (Charge:80%) 60 secs
        """ + "\n" + sessionLog

        let result = WakeAuditor().audit(
            log: log,
            startedAt: startedAt,
            endedAt: endedAt,
            displayDetachedAt: nil
        )
        #expect(result.sleepStart == date("2026-10-23 21:01:00 +0800"))
    }

    @Test("完全没有进入睡眠：sleptAtAll = false 且不计数")
    func noSleepAtAll() {
        let log = """
        2026-10-23 21:10:00 +0800 Wake                \tDarkWake to FullWake from Deep Idle [CDNVA] : due to UserActivity Assertion Using AC (Charge:76%) 300 secs
        """
        let result = WakeAuditor().audit(
            log: log,
            startedAt: startedAt,
            endedAt: endedAt,
            displayDetachedAt: nil
        )
        #expect(result.sleptAtAll == false)
        #expect(result.realWakeCount == 0)
        #expect(result.darkWakeCount == 0)
    }

    @Test("排除规则 1：最后一条唤醒后没有回睡且距结束不足 120 秒")
    func excludesTailWake() {
        // 21:31:00 结束 → 距 21:30:00 的唤醒只有 60 秒，且 21:32:18 的睡眠在区间外
        let result = WakeAuditor().audit(
            log: sessionLog,
            startedAt: startedAt,
            endedAt: date("2026-10-23 21:31:00 +0800"),
            displayDetachedAt: nil
        )
        #expect(result.realWakeCount == 0)
        #expect(result.excludedWakes.count == 1)
        #expect(result.excludedWakes.first?.reason == "UserActivity Assertion")
    }

    @Test("排除规则 1 不适用于其后已经回睡的唤醒")
    func keepsWakeThatFellBackAsleep() {
        let log = """
        2026-10-23 21:01:00 +0800 Sleep               \tEntering Sleep state due to 'Sleep Service Back to Sleep':TCPKeepAlive=active Using Batt (Charge:78%) 600 secs
        2026-10-23 21:30:00 +0800 Wake                \tDarkWake to FullWake from Deep Idle [CDNVA] : due to UserActivity Assertion Using AC (Charge:76%) 138 secs
        2026-10-23 21:32:18 +0800 Sleep               \tEntering Sleep state due to 'Sleep Service Back to Sleep':TCPKeepAlive=active Using Batt (Charge:76%) 900 secs
        """
        let result = WakeAuditor().audit(
            log: log,
            startedAt: startedAt,
            endedAt: date("2026-10-23 21:33:00 +0800"),
            displayDetachedAt: nil
        )
        #expect(result.realWakeCount == 1)
        #expect(result.excludedWakes.isEmpty)
    }

    @Test("排除规则 2：显示器接入时间戳 ± 60 秒内的唤醒")
    func excludesWakeNearDisplayDetach() {
        let result = WakeAuditor().audit(
            log: sessionLog,
            startedAt: startedAt,
            endedAt: endedAt,
            displayDetachedAt: date("2026-10-23 21:21:27 +0800")
        )
        #expect(result.notificationWakeCount == 0)
        #expect(result.darkWakeCount == 1)
        #expect(result.realWakeCount == 1)
        #expect(result.excludedWakes.count == 1)
    }

    @Test("暗唤醒结束回睡不算一次睡眠，也不算唤醒")
    func darkWakeExitIsNotAWake() {
        let log = """
        2026-10-23 21:01:00 +0800 Sleep               \tEntering Sleep state due to 'Sleep Service Back to Sleep':TCPKeepAlive=active Using Batt (Charge:78%) 600 secs
        2026-10-23 21:21:29 +0800 Sleep               \tEntering DarkWake state due to 'Notification Wake Back to Sleep':TCPKeepAlive=active Using AC (Charge:77%) 5 secs
        """
        let result = WakeAuditor().audit(
            log: log,
            startedAt: startedAt,
            endedAt: endedAt,
            displayDetachedAt: nil
        )
        #expect(result.darkWakeCount == 0)
        #expect(result.notificationWakeCount == 0)
        #expect(result.realWakeCount == 0)
    }
}
