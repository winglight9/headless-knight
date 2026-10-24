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
        snapshot["womp"] = 1
        snapshot["powernap"] = 1
        snapshot["tcpkeepalive"] = 1
        snapshot["standby"] = 1

        let data = try JSONEncoder().encode(snapshot)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Int]
        #expect(object == [
            "disablesleep": 1,
            "sleep": 0,
            "womp": 1,
            "powernap": 1,
            "tcpkeepalive": 1,
            "standby": 1
        ])
        #expect(snapshot.isComplete)
    }
}
