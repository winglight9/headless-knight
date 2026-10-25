import Foundation
import Testing

@testable import HKMKit

@Suite("helper 协议")
struct HelperProtocolTests {
    @Test("请求能编解码")
    func roundTripsRequest() throws {
        let request = HelperRequest(operation: .pmsetSet, arguments: ["key": "womp", "value": "0"])
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(HelperRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.operation == .pmsetSet)
        #expect(decoded.arguments["key"] == "womp")
    }

    @Test("响应能编解码，含 intValue")
    func roundTripsResponse() throws {
        let response = HelperResponse(id: "1", ok: true, output: "1", intValue: 1)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: data)
        #expect(decoded == response)
        #expect(decoded.intValue == 1)
    }

    @Test("操作名是稳定的字符串，daemon 与 App 必须一致")
    func operationRawValues() {
        #expect(HelperOperation.pmsetSet.rawValue == "pmsetSet")
        #expect(HelperOperation.pmsetSleepNow.rawValue == "pmsetSleepNow")
        #expect(HelperOperation.bluetoothSetPower.rawValue == "bluetoothSetPower")
        #expect(HelperOperation.allCases.count == 12)
    }

    @Test("没有 helper 时给出可读错误")
    func notInstalledMessage() {
        let error = HelperError.notInstalled
        #expect(error.errorDescription?.contains("后台服务") == true)
    }
}

@Suite("SharingControl 解析")
struct SharingControlTests {
    @Test("只认 LISTEN，别把已建立的连接当成监听")
    func parsesListeningPorts() {
        let text = """
        tcp46      0      0  *.445                  *.*                    LISTEN
        tcp4       0      0  127.0.0.1.631          *.*                    LISTEN
        tcp4       0      0  192.168.1.5.50000      1.1.1.1.443            ESTABLISHED
        tcp4       0      0  *.22                   *.*                    LISTEN
        """
        let ports = SharingControl.parseListeningPorts(text)
        #expect(ports.contains(445))
        #expect(ports.contains(631))
        #expect(ports.contains(22))
        #expect(ports.contains(50000) == false)   // ESTABLISHED 的本地端口不算
    }

    @Test("端口映射到 launchd label")
    func mapsPortsToLabels() {
        #expect(SharingControl.ports["com.apple.smbd"] == 445)
        #expect(SharingControl.ports["com.apple.screensharing"] == 5900)
        #expect(SharingControl.ports["com.apple.AppleFileServer"] == 548)
    }
}

@MainActor
@Suite("ProcessKiller dry-run")
struct ProcessKillerDryRunTests {
    @Test("dry-run 下不真的杀进程，但算成功")
    func dryRunNeverKills() async {
        let killer = ProcessKiller(dryRun: true)
        let blocker = SleepBlocker(pid: 999_999, processName: "Nonexistent")
        let outcome = await killer.kill(blocker)
        #expect(outcome == .dryRun)
        #expect(outcome.isSuccess)
    }
}

@Suite("时长格式化")
struct DurationFormatterTests {
    @Test("人类可读时长")
    func humanized() {
        #expect(DurationFormatter.humanized(seconds: 19_320) == "5 小时 22 分")
        #expect(DurationFormatter.humanized(seconds: 3600) == "1 小时")
        #expect(DurationFormatter.humanized(seconds: 2_880) == "48 分钟")
        #expect(DurationFormatter.humanized(seconds: 37) == "37 秒")
    }

    @Test("紧凑时长")
    func compact() {
        #expect(DurationFormatter.compact(seconds: 50 * 3600) == "50 小时")
        #expect(DurationFormatter.compact(seconds: 130) == "2 分钟")
        #expect(DurationFormatter.compact(seconds: 5) == "刚刚")
    }
}

@Suite("蓝牙与 Time Machine 状态读取")
struct PowerSourceReadTests {
    @Test("system_profiler 输出里读到控制器开关")
    func parsesProfilerState() {
        let on = """
        Bluetooth:

              Bluetooth Controller:
                  Address: C8:89:F3:B6:84:7B
                  State: On
                  Chipset: BCM_4387
        """
        #expect(BluetoothControl.parsePowerState(fromProfiler: on) == 1)

        let off = """
              Bluetooth Controller:
                  Address: C8:89:F3:B6:84:7B
                  State: Off
        """
        #expect(BluetoothControl.parsePowerState(fromProfiler: off) == 0)
    }

    @Test("没有控制器时不猜")
    func missingProfilerState() {
        #expect(BluetoothControl.parsePowerState(fromProfiler: "Bluetooth:\n\n") == nil)
    }

    @Test("没有备份目标就是没开备份")
    func timeMachineWithoutDestinations() {
        #expect(TimeMachineControl.parseDestinationInfo("tmutil: No destinations configured.\n") == false)
    }

    @Test("有备份目标就是开着")
    func timeMachineWithDestination() {
        let text = """
        ==================================================
        Name :          Time Capsule
        Kind :          Network
        """
        #expect(TimeMachineControl.parseDestinationInfo(text) == true)
    }

    @Test("读不懂就不下结论")
    func timeMachineUnreadable() {
        #expect(TimeMachineControl.parseDestinationInfo("") == nil)
    }
}

// MARK: - 后台服务是不是这一版

/// 2026-10-25 用户掉进的死循环：装一次 → 报「旧版本」→ 再装 → 还报。
///
/// 根因是拿**二进制内容**当判据，而安装脚本会 `codesign --force --sign -` 重新
/// 签名，装到 /Library 的那份比 App 里的大 18KB，字节永远对不上。现在改成问它
/// 自己报的协议版本，跟签名无关。
@Suite("后台服务的协议版本")
struct HelperVersionTests {
    @Test("新版本会报号")
    func parsesVersionedPong() {
        #expect(HelperClient.parseProtocolVersion("pong 2") == 2)
        #expect(HelperClient.parseProtocolVersion("pong 7") == 7)
    }

    @Test("只回 pong 的是很老的版本，按 1 算")
    func parsesBarePong() {
        #expect(HelperClient.parseProtocolVersion("pong") == 1)
    }

    @Test("当前协议版本要大于 1，否则「旧版」这条判断永远不成立")
    func apiVersionIsMeaningful() {
        #expect(HelperProtocol.apiVersion >= 2)
    }
}
