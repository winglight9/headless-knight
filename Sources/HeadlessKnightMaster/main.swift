import AppKit
import Foundation

/// 命令行入口。两条纯终端路径必须在 `NSApplication` 起来之前处理完：
/// 它们要能在一个没有窗口服务的 SSH 会话里跑，也不该在菜单栏留下图标。
///
/// - `--diagnose`      只读体检，把机器当前状态打出来
/// - `--simulate-away` 用内存替身把完整外出流程跑一遍
///
/// `--simulate-away` 默认就是 dry-run：所有依赖都是 `SimulatedServices`，
/// 不会碰 pmset / tmutil / launchctl / 任何进程。
@MainActor
func runSimulateAway(arguments: [String]) async -> Int32 {
    if arguments.contains("--list-scenarios") {
        for item in Simulation.all {
            print("  \(item.name.padding(toLength: 18, withPad: " ", startingAt: 0))\(item.summary)")
        }
        return 0
    }
    var scenario = "success"
    for argument in arguments where argument.hasPrefix("--scenario=") {
        scenario = String(argument.dropFirst("--scenario=".count))
    }
    // 也接受 `--simulate-away success` 这种写法，省得记两种语法。
    if let index = arguments.firstIndex(of: "--simulate-away"),
       arguments.count > index + 1,
       !arguments[index + 1].hasPrefix("--") {
        scenario = arguments[index + 1]
    }
    return await Simulation.run(scenario)
}

let arguments = CommandLine.arguments

/// 用户说过「弹窗一次也没看到过」。与其猜，不如给一条能当场验证的路：
/// 打一条通知出去，然后核对它到底弹没弹。
@MainActor
func runNotifyTest() async -> Int32 {
    let notifier = Notifier()
    // 命令行进程同样要装前台代理，否则从终端跑起来时横幅会被系统吞掉。
    Notifier.installDelegate()
    print("通知授权状态：\(await notifier.authorizationSummary())")
    let result = await notifier.sendTest(
        title: "通知是通的",
        body: "增强模式到点时会这样提醒你：30 秒后强制睡眠"
    )
    print("结果：\(result.summary)")
    return result == .shown || result == .delivered ? 0 : 1
}

if arguments.contains("--notify-test") {
    exit(await runNotifyTest())
}

if arguments.contains("--simulate-away") || arguments.contains("--list-scenarios") {
    exit(await runSimulateAway(arguments: arguments))
}

@MainActor
func runUIPreview() async -> Int32 {
    await UIPreview.run(arguments)
}

if arguments.contains("--render-ui") {
    exit(await runUIPreview())
}

if arguments.contains("--diagnose") {
    exit(Diagnostics.run())
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
