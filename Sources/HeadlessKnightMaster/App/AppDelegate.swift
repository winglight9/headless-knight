import AppKit
import Foundation
import HKMKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var appState: AppState?

    /// 通知代理必须在「启动完成」之前装好，否则第一批通知不会经过它。
    ///
    /// 前台应用的通知默认不显示，`willPresent` 是唯一的出口——不装这个代理，
    /// 用户点「试一下」永远看不到东西。
    func applicationWillFinishLaunching(_ notification: Notification) {
        Notifier.installDelegate()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // 菜单栏软件只能有一个实例：两个实例会并排出现两个图标，而且它们会同时
        // 读写同一份 state.json、同时改 pmset——那是最危险的一种并发。
        if terminateIfDuplicateInstance() {
            NSApp.terminate(nil)
            return
        }
        if DryRun.isEnabled {
            HKMLog.info("dry-run 模式：所有破坏性操作只打印不执行")
        }
        installMainMenu()
        let state = AppState()
        appState = state
        statusController = StatusItemController(state: state)
        state.bootstrap()

        // 只在真正的 GUI 里问，而且只在「还没问过」时问一次。
        //
        // 必须放在这里而不是 bootstrap()：`--simulate-away` 也会构造 AppState，
        // 而命令行进程没有 LaunchServices 上下文，TCC 弹不出授权框，会直接
        // abort 掉进程（退出码 134）。这类崩溃已经出现过一次了。
        BluetoothPermission.shared.requestIfNeeded()

        // 机器一醒就先读好唤醒日志：用户接下来点的第一下大概率是「结束外出」，
        // 那一步要拿这份日志做统计。提前读掉，他就不用对着转圈圈等一秒。
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func systemDidWake() {
        appState?.systemDidWake()
    }

    /// 已经有同名实例在跑了吗。
    ///
    /// 判据是 bundle id + pid 大小：pid 小的留下。这样两个实例几乎同时启动时，
    /// 只有后到的那个退出，不会互相把对方劝退、结果一个都不剩。
    private func terminateIfDuplicateInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .map(\.processIdentifier)
            .filter { $0 != mine && $0 > 0 }
        guard !others.isEmpty else { return false }
        if others.contains(where: { $0 < mine }) {
            HKMLog.info("已经有一个实例在跑（pid \(others.map(String.init).joined(separator: "、"))），这个退出")
            return true
        }
        // 我最小：把后到的那些结束掉，别在菜单栏留两个图标。
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where other.processIdentifier != mine && other.processIdentifier > mine {
            HKMLog.info("结束多出来的实例（pid \(other.processIdentifier)）")
            other.terminate()
        }
        return false
    }

    /// 只为了 ⌘Q 存在。
    ///
    /// 这是个 `LSUIElement` 的菜单栏软件，没有 Dock 图标，也就没有 App 菜单——
    /// 以前装上去就找不到任何退出入口，只能用 `kill` 或者活动监视器。
    /// 菜单里只有一项，但 ⌘Q 是所有人都会下意识按的键，必须能用。
    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let quitItem = NSMenuItem(
            title: L("退出无头骑士大师"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        // target 留 nil：动作顺着响应链走到 NSApp，最终进 applicationShouldTerminate，
        // 那里会先把机器恢复原样。设置页那个按钮走的是同一条路的另一头。
        quitItem.target = nil
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu

        NSApp.mainMenu = mainMenu
    }

    /// 所有退出路径的总闸：⌘Q、菜单、AppleScript、注销、关机。
    ///
    /// 正处在外出中、或者上次没恢复完，就先恢复再退；恢复不掉就不退，把原因留在
    /// 首页上——总比让用户以为软件已经关了、机器却睡不着要好。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = appState, state.needsRestoreBeforeQuit else { return .terminateNow }
        state.prepareForQuit { canQuit in
            sender.reply(toApplicationShouldTerminate: canQuit)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
