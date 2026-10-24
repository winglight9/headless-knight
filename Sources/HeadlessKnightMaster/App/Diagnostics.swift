import Foundation
import HKMKit

/// `HeadlessKnightMaster --diagnose` prints what the app sees, without changing
/// anything. Every call here is read-only.
enum Diagnostics {
    static func run() -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        let scanner = AssertionScanner()
        print("== 阻止睡眠的断言 ==")
        do {
            let result = try scanner.scanSync()
            if result.blockers.isEmpty {
                print("  （没有需要关闭的程序）")
            }
            for blocker in result.blockers {
                print("  \(blocker.processName)  \(blocker.detailText)")
                print("    \(blocker.technicalDescription)")
                let explanation = blocker.explanation
                print("    挡的是：\(explanation.reason)\(explanation.suggestion.map { "　建议：\($0)" } ?? "")")
                if blocker.allPIDs.count > 1 {
                    print("    合并进程：\(blocker.allPIDs.map(String.init).joined(separator: ", "))")
                }
            }
            print("  系统进程（会自己退出）：\(result.systemCount)")
            for entry in result.systemEntries {
                print("    \(entry.processName)(\(entry.pid))")
            }
        } catch {
            print("  读取失败：\(error.localizedDescription)")
        }

        print("\n== 电源设置 ==")
        let power = PowerSettings()
        if let snapshot = try? power.readSnapshot() {
            for key in PmsetSnapshot.trackedKeys {
                print("  \(key) = \(snapshot[key].map(String.init) ?? "未知")")
            }
        } else {
            print("  读取失败")
        }
        let scheduled = power.scheduledWakes()
        print("  定时唤醒：\(scheduled.count) 条")
        for line in scheduled {
            print("    \(line)")
        }

        print("\n== 强力模式 / 远程登录 ==")
        let settings = SessionStore().loadSettings()
        print("  强力模式：\(settings.strongMode ? "开（醒着满 10 分钟强制睡眠）" : "关")")
        let remote = RemoteSessionProbe().remoteLoginsSync()
        print(remote.isEmpty ? "  远程登录：没有" : "  远程登录：\(remote.joined(separator: "；"))")

        print("\n== 蓝牙 ==")
        let bluetooth = BluetoothControl()
        print("  私有 API 符号存在：\(bluetooth.hasPrivateAPI)")
        print("  蓝牙权限：\(bluetoothPermissionText())")
        print("  ※ 没有权限就调私有 API，进程会被 TCC 直接 abort，所以那条路只在有权限时才走")
        print("  实际读到的状态：\(bluetooth.powerStateSync().map { $0 == 1 ? "开" : "关" } ?? "未知")")
        print("  后台服务读到的状态：\(bluetooth.powerStateViaHelper().map { $0 == 1 ? "开" : "关" } ?? "未知")")
        print("  偏好文件读到的状态：\(bluetooth.powerStateViaDefaults().map(String.init) ?? "未知")")
        print("  system_profiler 读到的状态：\(bluetooth.powerStateViaSystemProfiler().map { $0 == 1 ? "开" : "关" } ?? "未知")")
        if let helperState = bluetooth.powerStateViaDefaults(),
           let realState = bluetooth.powerStateViaSystemProfiler(),
           helperState != realState {
            print("  ⚠️ 偏好文件说 \(helperState)，控制器实际是 \(realState) —— 只能信 system_profiler")
        }

        print("\n== 挡住 pmset sleepnow 的进程 ==")
        let holders = PowerSettings.parseSystemSleepBlockers(
            (try? ShellRunner().run("/usr/bin/pmset", arguments: ["-g", "assertions"], timeout: 10))?.stdout ?? ""
        )
        print(holders.isEmpty ? "  （没有）" : "  " + holders.joined(separator: "、"))

        print("\n== 电量 / 显示器 / 共享 / TM ==")
        print("  电量：\(BatteryReader().percentage().map { "\($0)%" } ?? "未知")")
        print("  活动显示器：\(SystemInfo.displayCount())")
        let listening = SharingControl().listeningLabelsSync()
        print("  正在监听的共享服务：\(listening.isEmpty ? "（没有，出门时不会动它们）" : listening.joined(separator: "、"))")
        print("  Time Machine：\(TimeMachineControl().isEnabledSync().map { $0 ? "开" : "关" } ?? "未知")")
        print("  helper 已安装：\(HelperClient().isInstalled)，可连接：\(HelperClient().isReachable())")

        print("\n== 唤醒审计 ==")
        let endedAt = Date()
        var startedAt = endedAt.addingTimeInterval(-12 * 3600)
        if let index = CommandLine.arguments.firstIndex(of: "--since"),
           CommandLine.arguments.count > index + 1,
           let parsed = PowerLogDateFormatter.date(from: CommandLine.arguments[index + 1]) {
            startedAt = parsed
        }
        print("  区间：\(PowerLogDateFormatter.string(from: startedAt)) → \(PowerLogDateFormatter.string(from: endedAt))")
        let log = (try? ShellRunner().run("/usr/bin/pmset", arguments: ["-g", "log"], timeout: 60))?.stdout ?? ""
        let result = WakeAuditor().audit(log: log, startedAt: startedAt, endedAt: endedAt, displayDetachedAt: nil)
        print("  睡过：\(result.sleptAtAll)")
        print("  暗唤醒 \(result.darkWakeCount) 次 / 通知唤醒 \(result.notificationWakeCount) 次 / 真实唤醒 \(result.realWakeCount) 次")
        for wake in result.realWakes {
            print("    真实唤醒 \(wake.headlineText)  原因=\(wake.reason)")
        }
        print("  被排除 \(result.excludedWakes.count) 条")
        return 0
    }

    /// `--diagnose` 是命令行，没有 bundle，查不到真实授权状态，只能说明情况。
    private static func bluetoothPermissionText() -> String {
        guard Bundle.main.bundleIdentifier != nil else {
            return "命令行进程查不到（需要从 .app 里运行）"
        }
        return BluetoothControl.hasBluetoothPermission ? "已允许" : "未允许（自动关蓝牙会失败，会请你手动关）"
    }
}
