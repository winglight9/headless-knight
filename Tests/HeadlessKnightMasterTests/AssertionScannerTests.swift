import Foundation
import Testing

@testable import HKMKit

private struct StubResolver: ProcessResolving {
    var names: [pid_t: String] = [:]
    var bundleIDs: [pid_t: String] = [:]
    var systemPIDs: Set<pid_t> = []

    func name(of pid: pid_t) -> String? { names[pid] }
    func bundleIdentifier(of pid: pid_t) -> String? { bundleIDs[pid] }
    func isSystemProcess(_ pid: pid_t) -> Bool { systemPIDs.contains(pid) }
}

/// Verbatim excerpt of `pmset -g assertions` on the target machine.
private let assertionsSample = """
2026-10-23 21:42:41 +0800
Assertion status system-wide:
   BackgroundTask                 0
   PreventUserIdleSystemSleep     1
   PreventUserIdleDisplaySleep    1
Listed by owning process:
   pid 182(coreaudiod): [0x0002aa1900019315] 00:42:17 PreventUserIdleSystemSleep named: "com.apple.audio.BuiltInSpeakerDevice.context.preventuseridlesleep"
\tCreated for PID: 66332.
\tResources: audio-out BuiltInSpeakerDevice
   pid 105(powerd): [0x0002087300018e3e] 12:11:59 PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"
   pid 105(powerd): [0x0002aa0d00099406] 00:15:51 UserIsActive named: "com.apple.powermanagement.kernel.useractive"
   pid 162(WindowServer): [0x0002087300098e3d] 00:00:00 UserIsActive named: "com.apple.iohideventsystem.queue.tickle"
   pid 8322(UURemote): [0x000038e9000197dc] 50:02:05 PreventUserIdleSystemSleep named: "UURemote Disable Idle System Sleep"
   pid 56712(ChatGPT): [0x0002856000018ad5] 03:18:58 NoIdleSleepAssertion named: "Electron"
   pid 57181(Electron): [0x000164ad00019b04] 23:50:45 NoIdleSleepAssertion named: "Electron"
   pid 66273(Google Chrome): [0x0002aa1a0001940d] 00:42:16 NoIdleSleepAssertion named: "Playing audio"
Kernel Assertions: 0x100=MAGICWAKE
   id=555  level=255 0x100=MAGICWAKE creat=2026/10/21 15:53  mod=2026/10/23 12:17 description=en0 owner=IOSkywalkNetworkBSDClient
"""

@Suite("AssertionScanner 解析")
struct AssertionScannerParsingTests {
    @Test("进程断言块都能解析出来")
    func parsesEntries() {
        let scan = AssertionScanner.parse(assertionsSample)
        #expect(scan.entries.count == 8)
        let audio = scan.entries.first { $0.pid == 182 }
        #expect(audio?.ownerName == "coreaudiod")
        #expect(audio?.assertionType == "PreventUserIdleSystemSleep")
        #expect(audio?.createdForPID == 66332)
        #expect(audio?.resources == ["audio-out", "BuiltInSpeakerDevice"])
        #expect(audio?.durationSeconds == 42 * 60 + 17)
    }

    @Test("没有 Created for PID 的断言 proxy 字段为空")
    func noProxyWhenAbsent() {
        let scan = AssertionScanner.parse(assertionsSample)
        let uur = scan.entries.first { $0.pid == 8322 }
        #expect(uur?.createdForPID == nil)
    }

    @Test("内核断言 MAGICWAKE 能被读到")
    func parsesKernelAssertion() {
        let scan = AssertionScanner.parse(assertionsSample)
        #expect(scan.kernelAssertions.contains { $0.name == "MAGICWAKE" })
    }
}

@Suite("AssertionScanner 代理关系")
struct AssertionScannerResolutionTests {
    private var resolver: StubResolver {
        StubResolver(
            names: [
                66332: "Google Chrome",
                8322: "UURemote",
                56712: "ChatGPT",
                57181: "Electron",
                105: "powerd",
                162: "WindowServer",
                66273: "Google Chrome"
            ],
            bundleIDs: [
                66332: "com.google.Chrome",
                66273: "com.google.Chrome",
                8322: "com.uu.remote",
                56712: "com.openai.chat",
                57181: "com.openai.chat"
            ],
            systemPIDs: [105, 162]
        )
    }

    private func scan() -> BlockerScanResult {
        let parsed = AssertionScanner.parse(assertionsSample)
        let scanner = AssertionScanner(runner: ShellRunner(), resolver: resolver)
        return scanner.blockers(from: parsed)
    }

    @Test("coreaudiod 代持的断言归到 Chrome 头上")
    func resolvesProxyToRealOwner() {
        let result = scan()
        let chrome = result.blockers.first { $0.pid == 66332 }
        #expect(chrome != nil)
        #expect(chrome?.processName == "Google Chrome")
        #expect(chrome?.proxyOwnerPID == 182)
        #expect(chrome?.proxyOwnerName == "coreaudiod")
        #expect(chrome?.bundleIdentifier == "com.google.Chrome")
    }

    @Test("系统守护进程不进入待关闭列表")
    func excludesSystemDaemons() {
        let result = scan()
        #expect(result.blockers.contains { $0.pid == 105 } == false)
        #expect(result.systemEntries.contains { $0.pid == 105 })
        #expect(result.systemCount == 1)
    }

    @Test("同一个 app 的多个进程合并成一行")
    func groupsProcessesOfOneApp() {
        let result = scan()
        #expect(result.blockers.count == 3)
        let chrome = result.blockers.first { $0.bundleIdentifier == "com.google.Chrome" }
        #expect(chrome?.allPIDs.sorted() == [66273, 66332])
        let chatGPT = result.blockers.first { $0.bundleIdentifier == "com.openai.chat" }
        #expect(chatGPT?.allPIDs.sorted() == [56712, 57181])
    }

    @Test("按持续时间从长到短排序")
    func sortsByDuration() {
        let result = scan()
        #expect(result.blockers.first?.pid == 8322)
    }

    @Test("音频断言用原因描述而不是时长")
    func audioDetailText() {
        let result = scan()
        let chrome = result.blockers.first { $0.pid == 66332 }
        #expect(chrome?.detailText == "正在放音频")
        let uur = result.blockers.first { $0.pid == 8322 }
        #expect(uur?.detailText == "50 小时")
    }
}
