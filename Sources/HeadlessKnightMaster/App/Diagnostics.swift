import Foundation
import HKMKit

/// `HeadlessKnightMaster --diagnose` prints what the app sees, without changing
/// anything. Every call here is read-only.
enum Diagnostics {
    static func run() -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        let scanner = AssertionScanner()
        print(L("== 阻止睡眠的断言 =="))
        do {
            let result = try scanner.scanSync()
            if result.blockers.isEmpty {
                print(L("  （没有需要关闭的程序）"))
            }
            for blocker in result.blockers {
                print("  \(blocker.processName)  \(blocker.detailText)")
                print("    \(blocker.technicalDescription)")
                let explanation = blocker.explanation
                print(L("    挡的是：{0}", explanation.reason))
                if let suggestion = explanation.suggestion {
                    print(L("    建议：{0}", suggestion))
                }
                if blocker.allPIDs.count > 1 {
                    print(L("    合并进程：{0}", blocker.allPIDs.map(String.init).joined(separator: ", ")))
                }
            }
            print(L("  系统进程（会自己退出）：{0}", result.systemCount))
            for entry in result.systemEntries {
                print("    \(entry.processName)(\(entry.pid))")
            }
        } catch {
            print(L("  读取失败：{0}", error.localizedDescription))
        }

        print(L("\n== 电源设置 =="))
        let power = PowerSettings()
        if let snapshot = try? power.readSnapshot() {
            for key in PmsetSnapshot.trackedKeys {
                print("  \(key) = \(snapshot[key].map(String.init) ?? L("未知"))")
            }
        } else {
            print(L("  读取失败"))
        }
        let scheduled = power.scheduledWakes()
        print(L("  定时唤醒：{0} 条", scheduled.count))
        for line in scheduled {
            print("    \(line)")
        }

        print(L("\n== 增强模式 / 远程登录 =="))
        let settings = SessionStore().loadSettings()
        print(L("  增强模式：{0}", settings.strongMode ? L("开（连续醒着满 5 分钟强制睡眠）") : L("关")))
        let remote = RemoteSessionProbe().remoteLoginsSync()
        print(remote.isEmpty ? L("  远程登录：没有") : L("  远程登录：{0}", remote.joined(separator: L("；"))))

        print(L("\n== 蓝牙 =="))
        let bluetooth = BluetoothControl()
        print(L("  私有 API 符号存在：{0}", bluetooth.hasPrivateAPI))
        print(L("  蓝牙权限：{0}", bluetoothPermissionText()))
        print(L("  ※ 没有权限就调私有 API，进程会被 TCC 直接 abort，所以那条路只在有权限时才走"))
        print(L("  实际读到的状态：{0}", bluetooth.powerStateSync().map { $0 == 1 ? L("开") : L("关") } ?? L("未知")))
        print(L("  后台服务读到的状态：{0}", bluetooth.powerStateViaHelper().map { $0 == 1 ? L("开") : L("关") } ?? L("未知")))
        print(L("  偏好文件读到的状态：{0}", bluetooth.powerStateViaDefaults().map(String.init) ?? L("未知")))
        print(L("  system_profiler 读到的状态：{0}", bluetooth.powerStateViaSystemProfiler().map { $0 == 1 ? L("开") : L("关") } ?? L("未知")))
        if let helperState = bluetooth.powerStateViaDefaults(),
           let realState = bluetooth.powerStateViaSystemProfiler(),
           helperState != realState {
            print(L("  ⚠️ 偏好文件说 {0}，控制器实际是 {1} —— 只能信 system_profiler", helperState, realState))
        }

        print(L("\n== 挡住 pmset sleepnow 的进程 =="))
        let holders = PowerSettings.parseSystemSleepBlockers(
            (try? ShellRunner().run("/usr/bin/pmset", arguments: ["-g", "assertions"], timeout: 10))?.stdout ?? ""
        )
        print(holders.isEmpty ? L("  （没有）") : "  " + holders.joined(separator: L("、")))

        print(L("\n== 电量 / 显示器 / 共享 / TM =="))
        print(L("  电量：{0}", BatteryReader().percentage().map { "\($0)%" } ?? L("未知")))
        print(L("  活动显示器：{0}", SystemInfo.displayCount()))
        let listening = SharingControl().listeningLabelsSync()
        print(L("  正在监听的共享服务：{0}", listening.isEmpty ? L("（没有，出门时不会动它们）") : listening.joined(separator: L("、"))))
        print(L("  Time Machine：{0}", TimeMachineControl().isEnabledSync().map { $0 ? L("开") : L("关") } ?? L("未知")))
        print(L("  helper 已安装：{0}，可连接：{1}", HelperClient().isInstalled, HelperClient().isReachable()))
        // 「装了」不等于「是这一版」。旧 helper 会把新参数静默忽略，
        // 只看文件在不在是查不出来的。
        let version = HelperClient().reportedProtocolVersion()
        print(L("  helper 报的协议版本：{0}（当前需要 {1}）", version.map(String.init) ?? L("连不上"), HelperProtocol.apiVersion))

        print(L("\n== 唤醒审计 =="))
        let endedAt = Date()
        var startedAt = endedAt.addingTimeInterval(-12 * 3600)
        if let index = CommandLine.arguments.firstIndex(of: "--since"),
           CommandLine.arguments.count > index + 1,
           let parsed = PowerLogDateFormatter.date(from: CommandLine.arguments[index + 1]) {
            startedAt = parsed
        }
        print(L("  区间：{0} → {1}", PowerLogDateFormatter.string(from: startedAt), PowerLogDateFormatter.string(from: endedAt)))
        let log = (try? ShellRunner().run("/usr/bin/pmset", arguments: ["-g", "log"], timeout: 60))?.stdout ?? ""
        let result = WakeAuditor().audit(log: log, startedAt: startedAt, endedAt: endedAt, displayDetachedAt: nil)
        print(L("  睡过：{0}", result.sleptAtAll))
        print(L("  暗唤醒 {0} 次 / 通知唤醒 {1} 次 / 真实唤醒 {2} 次", result.darkWakeCount, result.notificationWakeCount, result.realWakeCount))
        for wake in result.realWakes {
            print(L("    真实唤醒 {0}  原因={1}", wake.headlineText, wake.reason))
        }
        print(L("  被排除 {0} 条", result.excludedWakes.count))
        return 0
    }

    /// `--diagnose` 是命令行，没有 bundle，查不到真实授权状态，只能说明情况。
    private static func bluetoothPermissionText() -> String {
        guard Bundle.main.bundleIdentifier != nil else {
            return L("命令行进程查不到（需要从 .app 里运行）")
        }
        return BluetoothControl.hasBluetoothPermission ? L("已允许") : L("未允许（自动关蓝牙会失败，会请你手动关）")
    }
}
