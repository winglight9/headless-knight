import Foundation
import Testing

@testable import HKMKit

private let customSample = """
Battery Power:
 Sleep On Power Button 1
 lowpowermode         0
 standby              1
 ttyskeepawake        1
 hibernatemode        3
 powernap             1
 hibernatefile        /var/vm/sleepimage
 displaysleep         2
 womp                 0
 networkoversleep     0
 sleep                1
 tcpkeepalive         1
 lessbright           0
 disksleep            10
AC Power:
 Sleep On Power Button 1
 lowpowermode         0
 standby              1
 ttyskeepawake        1
 hibernatemode        3
 powernap             1
 hibernatefile        /var/vm/sleepimage
 displaysleep         0
 womp                 1
 networkoversleep     0
 sleep                0
 tcpkeepalive         1
 disksleep            10
"""

private let globalSample = """
System-wide power settings:
 SleepDisabled\t\t1
Currently in use:
 standby              1
 Sleep On Power Button 1
 powernap             1
 disksleep            10
 sleep                0 (sleep prevented by coreaudiod, powerd, ChatGPT)
 tcpkeepalive         1
 womp                 1
"""

@Suite("PowerSettings 读取")
struct PowerSettingsParsingTests {
    @Test("分段解析 pmset -g custom")
    func parsesSections() {
        let sections = PowerSettings.parseCustom(customSample)
        #expect(sections["AC Power"]?["sleep"] == "0")
        #expect(sections["AC Power"]?["womp"] == "1")
        #expect(sections["Battery Power"]?["sleep"] == "1")
        #expect(sections["Battery Power"]?["womp"] == "0")
    }

    @Test("带空格的值不会被拆错")
    func parsesKeysWithSpaces() {
        let sections = PowerSettings.parseCustom(customSample)
        #expect(sections["AC Power"]?["Sleep On Power Button"] == "1")
        #expect(sections["AC Power"]?["hibernatefile"] == "/var/vm/sleepimage")
    }

    @Test("pmset -g 里被括号污染的值要清干净")
    func stripsParenthetical() {
        let values = PowerSettings.parseGlobal(globalSample)
        #expect(values["sleep"] == "0")
        #expect(values["SleepDisabled"] == "1")
        #expect(values["womp"] == "1")
    }

    @Test("定时唤醒任务只保留事件行")
    func parsesScheduledWakes() {
        let text = """
        Scheduled power events:
         [0]  wake at 10/22/2026 18:21:07 by 'com.apple.alarm.user-invisible'
         [1]  wake at 10/23/2026 07:57:43 by 'com.apple.alarm.user-invisible'
        """
        let events = PowerSettings.parseScheduledWakes(text)
        #expect(events.count == 2)
        #expect(events[0].hasPrefix("[0]  wake at"))
    }

    @Test("快照按设计文档的 JSON 形状编码")
    func snapshotEncodesAsFlatObject() throws {
        var snapshot = PmsetSnapshot()
        snapshot["disablesleep"] = 1
        snapshot["sleep"] = 0
        snapshot["displaysleep"] = 10
        snapshot["womp"] = 1
        snapshot["powernap"] = 1
        snapshot["tcpkeepalive"] = 1
        snapshot["standby"] = 1

        let data = try JSONEncoder().encode(snapshot)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Int]
        #expect(object == [
            "disablesleep": 1,
            "sleep": 0,
            "displaysleep": 10,
            "womp": 1,
            "powernap": 1,
            "tcpkeepalive": 1,
            "standby": 1
        ])
        #expect(snapshot.isComplete)
    }
}

// MARK: - 关屏时间要按电源分开读、分开还原

/// `ScriptedRunner` 只按可执行文件分派，而 `readSnapshot` 要分别调
/// `pmset -g custom` 和 `pmset -g`，所以这里按参数分派。
private struct TwoCommandRunner: CommandRunning {
    let custom: String
    let global: String

    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        CommandResult(status: 0, stdout: arguments.contains("custom") ? custom : global, stderr: "")
    }

    func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        try run(executable, arguments: arguments, timeout: 20)
    }
}

@Suite("关屏时间（displaysleep）")
struct DisplaySleepTests {
    private let custom = """
    Battery Power:
     displaysleep         2
     sleep                1
     womp                 1
     powernap             1
     tcpkeepalive         1
     standby              1
    AC Power:
     displaysleep         0
     sleep                0
     womp                 1
     powernap             1
     tcpkeepalive         1
     standby              1
    """

    /// 用户这台机器：插电「永不关屏」(0)、电池 2 分钟。两套必须各记一份。
    @Test("快照要读到 displaysleep，插电和电池各一份")
    func readsBothProfiles() throws {
        let settings = PowerSettings(
            runner: TwoCommandRunner(custom: custom, global: " SleepDisabled\t\t1\n"),
            executor: RecordingExecutor()
        )
        let snapshot = try settings.readSnapshot()
        #expect(snapshot["displaysleep"] == 0)
        #expect(snapshot["displaysleep_battery"] == 2)
    }

    /// `pmset -a` 会把两套写成同一个值，所以电池那套要单独补一次 `-b`。
    /// 不补的话，用户的「用电池 2 分钟关屏」会被永久改成「永不关屏」。
    @Test("还原时电池那套要单独写一次 -b")
    func restoresBatteryProfileSeparately() async {
        let executor = RecordingExecutor()
        let settings = PowerSettings(runner: ScriptedRunner(), executor: executor)
        var snapshot = PmsetSnapshot()
        snapshot["displaysleep"] = 0
        snapshot["displaysleep_battery"] = 2

        _ = await settings.restore(snapshot)

        let displayWrites = executor.callsWithArguments
            .filter { $0.1["key"] == "displaysleep" }
            .map { ($0.1["scope"] ?? "a", $0.1["value"] ?? "") }
        #expect(displayWrites.count == 2)
        #expect(displayWrites.contains { $0.0 == "a" && $0.1 == "0" })
        #expect(displayWrites.contains { $0.0 == "b" && $0.1 == "2" })
    }

    /// 没有电池的机器（台式机）不该多出一次无意义的写入。
    @Test("没有电池就不写 -b")
    func skipsBatteryWriteOnDesktops() async {
        let executor = RecordingExecutor()
        let settings = PowerSettings(runner: ScriptedRunner(), executor: executor)
        var snapshot = PmsetSnapshot()
        snapshot["displaysleep"] = 0

        _ = await settings.restore(snapshot)

        let scoped = executor.callsWithArguments.filter { $0.1["scope"] == "b" }
        #expect(scoped.isEmpty)
    }
}
