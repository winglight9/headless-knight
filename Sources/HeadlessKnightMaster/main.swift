import AppKit
import Foundation
import HKMKit

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

/// 不依赖界面的「接回内建屏」。
///
/// 存在的理由很直白：断内建屏之后如果一块屏都没有了，菜单栏和面板都不在视野里，
/// ⌘H 也可能被别的软件占着。这条路只要 App 还在磁盘上就能走：
///
///     /Applications/Knight.app/Contents/MacOS/Knight --restore-builtin
///
/// 它不走 `AppState`，也不看设置，因为它的使用场景就是「设置可能已经不对了」。
@MainActor
func runRestoreBuiltin() async -> Int32 {
    let controller = DisplayController()
    guard controller.isAvailable else {
        print("这个系统上拿不到断屏接口，没法处理内建屏")
        return 1
    }
    guard let id = controller.builtinDisplayID() else {
        print("找不到内建屏：这台机器可能真的没有")
        return 1
    }
    print("内建屏 #\(id)，现在\(CGDisplayIsActive(id) == 1 ? "亮着" : "断开着")")
    switch await controller.reconnect() {
    case let .reconnected(id):
        print("已接回内建屏 #\(id)")
        return 0
    case let .unchanged(id):
        print("内建屏 #\(id) 本来就亮着，不用动")
        return 0
    case .builtinNotFound:
        print("找不到内建屏，没法接回")
        return 1
    case .apiUnavailable:
        print("这个系统上拿不到断屏接口")
        return 1
    case let .failed(reason):
        print("接回失败：\(reason)")
        return 1
    case .disconnected:
        print("状态异常：请求接回，结果却是断开")
        return 1
    }
}

if arguments.contains("--restore-builtin") {
    exit(await runRestoreBuiltin())
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
