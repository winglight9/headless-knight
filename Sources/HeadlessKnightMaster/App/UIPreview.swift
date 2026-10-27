import AppKit
import HKMKit
import SwiftUI

/// `--render-ui <目录>`：把几个主要界面渲染成 PNG，用来核对排版。
///
/// 为什么需要它：这台机器拆了屏、而且是单屏，靠截屏核对英文排版要来回切语言、
/// 手动点菜单栏，一次只能看一页。这里用 `SimulatedServices` 把流程跑到目标页面，
/// 再用 `ImageRenderer` 直接出图——两种语言各跑一遍，就能一张张对着看。
///
/// 只在命令行下工作，不带这个参数时一行都不会执行。
@MainActor
enum UIPreview {
    struct Shot {
        let name: String
        let scenario: String
        let settle: (AppState, SimulatedServices) async -> Void
    }

    static let shots: [Shot] = [
        Shot(name: "1-home", scenario: "success") { _, _ in },
        Shot(name: "2-detecting", scenario: "success") { state, _ in
            state.beginAway()
            await Simulation.waitUntil { state.screen == .detecting }
            await state.waitForFlow()
        },
        Shot(name: "3-blocked", scenario: "helper-missing") { state, _ in
            state.beginAway()
            await Simulation.waitUntil { state.screen == .blocked }
            await state.waitForFlow()
        },
        Shot(name: "4-ready", scenario: "success") { state, _ in
            await driveToReady(state)
        },
        Shot(name: "5-report", scenario: "anomaly-report") { state, sim in
            await driveToReady(state)
            sim.simulateDisplayCount(0)
            await Simulation.waitUntil {
                switch state.sleepOutcome {
                case .slept, .failed, .unverified: return true
                case .idle, .requesting: return false
                }
            }
            sim.advanceClock(by: 5 * 3600 + 22 * 60)
            sim.batteryLevel = 74
            await state.finishAway()
        },
        Shot(name: "6-settings", scenario: "success") { state, _ in
            state.showSettings()
        },
        Shot(name: "7-away", scenario: "success") { state, sim in
            await driveToReady(state)
            sim.simulateDisplayCount(0)
            await Simulation.waitUntil { state.screen == .away }
            sim.advanceClock(by: 3 * 3600 + 12 * 60)
            await Simulation.waitUntil { state.awayDurationText.contains("3") }
        },
        Shot(name: "8-onboarding", scenario: "success") { state, _ in
            state.replayOnboarding()
        }
    ]

    static func driveToReady(_ state: AppState) async {
        state.beginAway()
        await Simulation.waitUntil { state.screen == .detecting || state.screen == .blocked }
        if state.screen == .detecting {
            state.closeImmediately()
        }
        await Simulation.waitUntil { state.screen == .readyToUnplug }
        await state.waitForFlow()
    }

    static func run(_ arguments: [String]) async -> Int32 {
        var directory = "build/ui-preview"
        if let index = arguments.firstIndex(of: "--render-ui"), arguments.count > index + 1,
           !arguments[index + 1].hasPrefix("--") {
            directory = arguments[index + 1]
        }
        let dark = arguments.contains("--dark")
        let url = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        // 先查一条，逼 bootstrap 跑起来，否则这里打印的是没初始化过的默认值。
        let probe = L("在家")
        print("语言：\(Bundle.main.preferredLocalizations) 首选：\(Locale.preferredLanguages.first ?? "-") 英文模式：\(Loc.isEnglish) 表：\(Loc.table.count) 条 探头：\(probe)")
        for shot in shots {
            guard let scenario = Simulation.scenario(named: shot.scenario) else { continue }
            let sim = scenario.build()
            // 官网截图要拍一台「健康」的机器：模拟场景默认 disablesleep=1（演示告警链路用），
            // 倒计时默认 1 秒（演示时快点走完）。出图前把这两处抹平，否则首页会顶着橙色
            // 「睡眠被锁」标签、拔线页写着「1 秒后睡」，跟页面文案和真实默认（3 秒）对不上。
            sim.pmsetValues.values["disablesleep"] = 0
            if sim.storedSettings.sleepDelaySeconds < 3 {
                sim.storedSettings.sleepDelaySeconds = 3
            }
            let state = AppState(
                deps: .simulated(sim),
                timing: Timing(
                    countdownTick: 0.01,
                    sleepVerifySeconds: 0,
                    unplugPollSeconds: 3600,
                    sleepRetrySeconds: 3600
                )
            )
            state.narrator = { _ in }
            state.bootstrap()
            await shot.settle(state, sim)

            let view = RootView()
                .environmentObject(state)
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else {
                print("  \(shot.name) 渲染失败")
                continue
            }
            let file = url.appendingPathComponent("\(shot.name).png")
            try? png.write(to: file)
            print("  \(shot.name).png  \(Int(image.size.width))x\(Int(image.size.height))")
        }
        return 0
    }
}
