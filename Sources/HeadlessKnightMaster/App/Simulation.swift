import Foundation
import HKMKit

/// `--simulate-away`：用内存替身把完整流程跑一遍，逐步打印。
///
/// 存在的理由很直接：这台机器的屏幕被拆掉了，用户没法「拔线试试看」，
/// 而之前的单元测试只覆盖纯函数，没有一条走过状态机。
@MainActor
enum Simulation {
    struct Scenario {
        let name: String
        let summary: String
        let build: @MainActor () -> SimulatedServices
    }

    static let all: [Scenario] = [
        Scenario(name: "success", summary: "全部成功，拔线后睡眠，回来报告干净") { success() },
        Scenario(name: "no-blockers", summary: "没有程序阻止睡眠，跳过检测页") { noBlockers() },
        Scenario(name: "blocker-fails", summary: "一个程序关不掉 → 阻塞") { blockerFails() },
        Scenario(name: "blocker-respawns", summary: "程序退出后又被拉起 → 阻塞") { blockerRespawns() },
        Scenario(name: "bluetooth-fails", summary: "蓝牙关不掉 → 阻塞") { bluetoothFails() },
        Scenario(name: "pmset-fails", summary: "pmset 写入失败 → 阻塞") { pmsetFails() },
        Scenario(name: "tm-fails", summary: "Time Machine 关不掉 → 照常出门") { timeMachineFails() },
        Scenario(name: "sharing-fails", summary: "共享服务关不掉 → 照常出门") { sharingFails() },
        Scenario(name: "helper-missing", summary: "后台服务没装 → 引导安装") { helperMissing() },
        Scenario(name: "no-sleep", summary: "叫它睡但没睡成 → 停在拔线页，绝不假装出门") { noSleep() },
        Scenario(name: "anomaly-report", summary: "期间被真实唤醒 → 红色报告") { anomalyReport() },
        Scenario(name: "restore-fails", summary: "结束时恢复失败 → 失败写进报告") { restoreFails() }
    ]

    static func scenario(named name: String) -> Scenario? {
        all.first { $0.name == name }
    }

    // MARK: - 运行

    static func run(_ name: String) async -> Int32 {
        guard let scenario = scenario(named: name) else {
            print("未知场景：\(name)")
            print("可用场景：")
            for item in all {
                print("  \(item.name.padding(toLength: 18, withPad: " ", startingAt: 0))\(item.summary)")
            }
            return 2
        }

        print("场景：\(scenario.name) — \(scenario.summary)")
        print(String(repeating: "─", count: 56))

        let sim = scenario.build()
        let state = AppState(
            deps: .simulated(sim),
            timing: Timing(
                detectCountdownSeconds: 1,
                countdownTick: 0.01,
                sleepVerifySeconds: 0,
                unplugPollSeconds: 3600,
                sleepRetrySeconds: 3600
            )
        )
        state.narrator = { print($0) }

        state.bootstrap()
        state.beginAway()
        await waitUntil { state.screen != .detecting }
        await state.waitForFlow()

        print(String(repeating: "─", count: 56))
        print("→ 流程结束：screen = \(describe(state.screen))，失败 \(state.failedItems.count) 项")
        for item in state.failedItems {
            print("    [\(item.severity.rawValue)] \(item.title)：\(item.detail)")
        }

        if state.screen == .blocked {
            print("→ 阻塞页，不会出门。")
            if state.needsHelperInstall {
                print("→ 阻塞页上会给一个「安装后台服务」按钮；装完自动重试。")
                print(String(repeating: "─", count: 56))
                print("模拟：点「安装后台服务」")
                await state.installHelperFromBlockedNow()
                await state.waitForFlow()
                print("→ 装完重试：screen = \(describe(state.screen))，失败 \(state.failedItems.count) 项")
                for item in state.failedItems {
                    print("    [\(item.severity.rawValue)] \(item.title)：\(item.detail)")
                }
            }
            if state.screen != .readyToUnplug {
                return 0
            }
        }

        guard state.screen == .readyToUnplug else { return 0 }

        // 模拟拔线
        print(String(repeating: "─", count: 56))
        print("模拟：拔掉显示器")
        sim.simulateDisplayCount(0)
        // 等到「睡没睡」有结论。请求发出去不等于睡了——这正是要验证的那件事。
        await waitUntil {
            switch state.sleepOutcome {
            case .slept, .failed: return true
            case .idle, .requesting: return false
            }
        }
        switch state.sleepOutcome {
        case .slept:
            print("→ 请求睡眠 \(sim.sleepNowCalls) 次，已确认进入睡眠，screen = \(describe(state.screen))")
        case let .failed(reason):
            print("→ 请求睡眠 \(sim.sleepNowCalls) 次，系统没睡：\(reason)")
            print("→ screen = \(describe(state.screen))（不会假装已经出门）")
            print(String(repeating: "─", count: 56))
            return 0
        case .idle, .requesting:
            print("→ 睡眠流程没有结论")
            return 0
        }

        // 模拟一段时间之后回来
        sim.advanceClock(by: 5 * 3600 + 22 * 60)
        sim.batteryLevel = 74
        state.beginAway() // 不应再开一条流程，这里只是确认幂等
        await state.finishAway()

        print(String(repeating: "─", count: 56))
        if let report = state.report {
            print("报告：\(report.headline)")
            print("  时长：\(report.durationText)   电量：\(report.batteryText)")
            print("  暗唤醒 \(report.darkWakeCount) / 通知唤醒 \(report.notificationWakeCount) / 真实唤醒 \(report.realWakeCount)")
            if let suggestion = report.suggestion {
                print("  建议：\(suggestion.text)")
            }
            if !report.failedItems.isEmpty {
                print("  未完成：\(report.failedItems.joined(separator: "；"))")
            }
        }

        // 模拟点「知道了」
        print(String(repeating: "─", count: 56))
        print("模拟：点「知道了」，恢复设置")
        await state.acknowledgeReportNow()
        print("→ screen = \(describe(state.screen))")
        if let message = state.errorMessage {
            print("→ 恢复提示：\(message)")
        }
        // 恢复失败必须落在报告里，否则用户点完「知道了」就再也看不到它了。
        if let stored = sim.storedReports.last, !stored.failedItems.isEmpty {
            print("→ 落盘的报告：\(stored.headline)")
            for item in stored.failedItems {
                print("    未完成：\(item)")
            }
        }
        printTrace(sim)
        return 0
    }

    /// 把「真正落到机器上的动作」按顺序打出来，用来核对恢复是不是照原样写回去了。
    private static func printTrace(_ sim: SimulatedServices) {
        let interesting = sim.events.filter {
            $0.hasPrefix("restore") || $0.hasPrefix("sleepNow") || $0.hasPrefix("tm ")
                || $0.hasPrefix("bluetooth") || $0.hasPrefix("sharing")
        }
        guard !interesting.isEmpty else { return }
        print(String(repeating: "─", count: 56))
        print("动作轨迹：")
        for event in interesting {
            print("  · \(event)")
        }
        let values = PmsetSnapshot.trackedKeys.compactMap { key -> String? in
            guard let value = sim.pmsetValues[key] else { return nil }
            return "\(key)=\(value)"
        }
        print("结束时 pmset：\(values.joined(separator: " "))")
    }

    private static func describe(_ screen: AppState.Screen) -> String {
        switch screen {
        case let .onboarding(step): return "onboarding(\(step))"
        case .home: return "home"
        case .detecting: return "detecting"
        case .blocked: return "blocked"
        case .readyToUnplug: return "readyToUnplug"
        case .away: return "away"
        case .auditing: return "auditing"
        case .report: return "report"
        case .settings: return "settings"
        }
    }

    static func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - 场景

    private static func base() -> SimulatedServices {
        let sim = SimulatedServices()
        sim.storedSettings = AppSettings(onboardingDone: true, launchAtLogin: false, sleepDelaySeconds: 1)
        sim.powerLog = log(startingAt: sim.currentDate, sleeps: true, realWake: false)
        return sim
    }

    /// 断言名要一起给：检测页现在显示的是「它挡了什么」，只给类型的话
    /// 三个程序会显示成同一句话，看不出这个页面到底想说什么。
    private static func sampleBlocker(
        _ name: String,
        pid: pid_t,
        bundle: String,
        assertion: String = "PreventUserIdleSystemSleep",
        named: String? = nil
    ) -> SleepBlocker {
        SleepBlocker(
            pid: pid,
            processName: name,
            bundleIdentifier: bundle,
            assertionTypes: [assertion],
            assertionNames: named.map { [$0] } ?? [],
            durationSeconds: 49 * 3600,
            kind: assertion == "PreventUserIdleDisplaySleep" ? .displayOnly : .blocking
        )
    }

    private static func success() -> SimulatedServices {
        let sim = base()
        sim.blockers = [
            sampleBlocker("UU远程", pid: 8322, bundle: "com.netease.uuremote"),
            sampleBlocker(
                "Chrome",
                pid: 66273,
                bundle: "com.google.Chrome",
                assertion: "NoIdleSleepAssertion",
                named: "AudioPlayback"
            ),
            // 只挡屏幕的那个不该被退出，页面会单独说明。
            sampleBlocker(
                "QuickTime Player",
                pid: 66410,
                bundle: "com.apple.QuickTimePlayerX",
                assertion: "PreventUserIdleDisplaySleep"
            )
        ]
        sim.sharingLabels = ["com.apple.smbd"]
        return sim
    }

    private static func noBlockers() -> SimulatedServices {
        let sim = base()
        sim.blockers = []
        return sim
    }

    private static func blockerFails() -> SimulatedServices {
        let sim = success()
        sim.killOutcomes["UU远程"] = .failed("无法自动退出，它还在阻止睡眠。请手动退出这个程序。")
        return sim
    }

    private static func blockerRespawns() -> SimulatedServices {
        let sim = success()
        sim.respawnsAfterKill = true
        return sim
    }

    private static func bluetoothFails() -> SimulatedServices {
        let sim = success()
        sim.bluetoothSetFailure = "蓝牙状态没有变化"
        return sim
    }

    private static func pmsetFails() -> SimulatedServices {
        let sim = success()
        sim.failingPmsetKeys = ["womp"]
        return sim
    }

    private static func timeMachineFails() -> SimulatedServices {
        let sim = success()
        sim.timeMachineIsOn = true
        sim.timeMachineDisableFailure = "tmutil: disable requires Full Disk Access privileges."
        return sim
    }

    private static func sharingFails() -> SimulatedServices {
        let sim = success()
        sim.sharingFailure = "Operation not permitted"
        return sim
    }

    private static func helperMissing() -> SimulatedServices {
        let sim = success()
        sim.helperInstalled = false
        // helper 没装时，真实实现在第一次 root 操作上就抛 notInstalled；
        // 装上之后同样的写入应当一次成功——这里不需要额外让 pmset 失败。
        return sim
    }

    private static func noSleep() -> SimulatedServices {
        let sim = success()
        // 系统压根没睡：日志里没有 Entering Sleep，验证也过不去。
        sim.powerLog = log(startingAt: sim.currentDate, sleeps: false, realWake: false)
        sim.sleepSucceeds = false
        sim.sleepBlockers = ["WindowServer"]
        return sim
    }

    private static func anomalyReport() -> SimulatedServices {
        let sim = success()
        sim.powerLog = log(startingAt: sim.currentDate, sleeps: true, realWake: true)
        return sim
    }

    private static func restoreFails() -> SimulatedServices {
        let sim = success()
        sim.failingRestoreKeys = ["disablesleep"]
        return sim
    }

    // MARK: - 假的电源日志

    /// `pmset -g log` 的真实格式是「26 字符时间戳 + domain + 消息」，暗唤醒的
    /// domain 是 `DarkWake`，完整唤醒才是 `Wake`——写错一个字母，报告就会说
    /// 「一次都没醒」。测试和模拟器共用这一份，改坏了会立刻暴露。
    nonisolated static func log(startingAt start: Date, sleeps: Bool, realWake: Bool) -> String {
        var lines: [String] = []
        func add(_ offset: TimeInterval, _ domain: String, _ message: String) {
            lines.append(PowerLogDateFormatter.string(from: start.addingTimeInterval(offset)) + " \(domain)  \t" + message)
        }
        if sleeps {
            add(60, "Sleep", "Entering Sleep state due to 'Idle Sleep': Using AC (Charge: 80%) 7200 secs")
            add(3600, "DarkWake", "DarkWake from Normal Sleep [CDN] : due to RTC/Maintenance Using AC (Charge: 79%) 45 secs")
            add(5400, "DarkWake", "DarkWake from Normal Sleep [CDN] : due to RTC/Maintenance Using AC (Charge: 78%) 30 secs")
            if realWake {
                add(7200, "Wake", "DarkWake to FullWake from Normal Sleep [CDNVA] : due to HID Activity Using AC (Charge: 76%) 120 secs")
                add(7320, "Sleep", "Entering Sleep state due to 'Idle Sleep': Using AC (Charge: 76%) 3600 secs")
            }
        }
        return lines.joined(separator: "\n")
    }
}

extension AppDependencies {
    @MainActor
    static func simulated(_ sim: SimulatedServices) -> AppDependencies {
        AppDependencies(
            scanner: sim,
            killer: sim,
            power: sim,
            bluetooth: sim,
            battery: sim,
            sharing: sim,
            timeMachine: sim,
            displays: sim,
            store: sim,
            notifier: sim,
            loginItem: sim,
            powerLog: sim,
            helper: sim,
            remote: sim,
            clock: sim,
            auditor: WakeAuditor()
        )
    }
}
