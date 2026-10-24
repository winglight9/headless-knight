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
/// 打一条通知出去，顺便把系统那边记录的授权状态打出来。
@MainActor
func runNotifyTest() async -> Int32 {
    let notifier = Notifier()
    print("通知授权状态：\(await notifier.authorizationSummary())")
    notifier.post(
        title: "通知是通的",
        body: "强力模式到点时会这样提醒你：30 秒后强制睡眠。"
    )
    // 给 UNUserNotificationCenter 一点时间把请求交出去，然后退出。
    try? await Task.sleep(nanoseconds: 2_000_000_000)
    print("已提交。没看到横幅的话，去「系统设置 → 通知 → 无头骑士大师」看看是不是被关掉了。")
    return 0
}

if arguments.contains("--notify-test") {
    exit(await runNotifyTest())
}

if arguments.contains("--simulate-away") || arguments.contains("--list-scenarios") {
    exit(await runSimulateAway(arguments: arguments))
}

if arguments.contains("--diagnose") {
    exit(Diagnostics.run())
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
