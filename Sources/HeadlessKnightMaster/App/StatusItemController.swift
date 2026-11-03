import AppKit
import HKMKit
import Combine

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let state: AppState
    private let popover: PopoverHost
    private var cancellables: Set<AnyCancellable> = []
    /// 出门流程进行中才注册的「结束外出」快捷键。
    private var endAwayHotKey: GlobalHotKey?
    /// 常驻的「断开 / 接回内建屏」。屏黑了只有它还够得着。
    private var builtinHotKey: GlobalHotKey?

    init(state: AppState) {
        self.state = state
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = PopoverHost(state: state)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = L("无头骑士大师")
            // 锚点一开始就记上。开机时状态就是「外出中」那条路径不会再走到
            // show()，面板得有个参照物才知道自己该贴在哪。
            popover.attach(to: button)
        }

        state.iconStatePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &cancellables)

        // 页面一变就决定快捷键要不要在：只在出门流程里注册，回到首页立刻注销，
        // 免得这个组合在用户干别的事时被我们占着。
        state.$screen
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncEndAwayHotKey() }
            .store(in: &cancellables)
        syncEndAwayHotKey()

        // ⌘H：常驻，按一下接回内建屏、再按一下断开。
        //
        // 它必须常驻——「断开」这个动作本身就可能发生在只剩一块屏的时候，
        // 那一刻正是它要救命的时候。所以这个组合在全天候被我们占着，代价是
        // 别的 App 的「隐藏窗口」会失效，用户知情并同意。
        builtinHotKey = GlobalHotKey(
            keyCode: GlobalHotKey.builtinKeyCode,
            modifiers: GlobalHotKey.builtinModifiers,
            label: GlobalHotKey.builtinLabel
        ) { [weak self] in
            self?.state.toggleBuiltinByHotKey()
        }
        if builtinHotKey == nil {
            HKMLog.error("快捷键 \(GlobalHotKey.builtinLabel) 注册失败（可能被别的软件占着），屏黑了只能靠命令行")
        }

        // 机器被叫醒时把窗口摆出来：那一刻用户最想看到的是「结束外出模式」。
        state.onSystemWake = { [weak self] in
            self?.showForWake()
        }

        // 报告页的「完成」= 关窗口，跟别的 app 里的结果窗口一样。
        state.onDismissReport = { [weak self] in
            self?.popover.hide()
        }
        popover.onHidden = { [weak self] in
            self?.state.dismissReportIfNeeded()
        }

        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
        refreshIcon()
    }

    deinit {
        DistributedNotificationCenter.default.removeObserver(self)
    }

    @objc private func handleClick() {
        guard let button = statusItem.button else { return }
        // 右键（或者双指轻点）给一份菜单。面板是一扇贴在菜单栏下面的窗口，
        // 多屏摆错、被别的窗口盖住的时候它可能根本点不到——菜单是系统画的，
        // 一定出现在鼠标底下，是最稳的那条退路。
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.hide()
            showContextMenu()
            return
        }
        if popover.isShown {
            // 流程进行中时点图标不是「关掉窗口」——用户要的是「一直看着」。
            if popover.isStickyScreen {
                popover.bringToFront()
            } else {
                popover.hide()
            }
            return
        }
        state.handleIconTap()
        popover.show(relativeTo: button)
    }

    /// 右键菜单：只有「结束外出」和「打开面板」两条真正有用的，外加退出。
    private func showContextMenu() {
        let menu = NSMenu()
        if state.canEndAway {
            let item = NSMenuItem(
                title: L("结束外出模式（{0}）", GlobalHotKey.endAwayLabel),
                action: #selector(endAwayFromMenu),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }
        let open = NSMenuItem(
            title: L("打开面板"),
            action: #selector(openPanelFromMenu),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: L("退出无头骑士大师"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        )
        quit.target = nil
        menu.addItem(quit)

        // 直接弹在图标下面：不用把菜单挂到 statusItem 上，也就没有「弹完忘了摘、
        // 之后左键也弹菜单」这一串麻烦。
        if let button = statusItem.button {
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: button.bounds.height + 4),
                in: button
            )
        }
    }

    @objc private func endAwayFromMenu() {
        state.endAwayByShortcut()
        if let button = statusItem.button, !popover.isShown {
            popover.show(relativeTo: button)
        }
    }

    @objc private func openPanelFromMenu() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button)
    }

    /// 出门流程里注册 ⌃⌥⌘E，回到首页就注销。
    private func syncEndAwayHotKey() {
        if state.canEndAway {
            guard endAwayHotKey == nil else { return }
            endAwayHotKey = GlobalHotKey(
                keyCode: GlobalHotKey.endAwayKeyCode,
                modifiers: GlobalHotKey.endAwayModifiers,
                label: GlobalHotKey.endAwayLabel
            ) { [weak self] in
                guard let self else { return }
                self.state.endAwayByShortcut()
                // 按下之后把界面亮出来：否则「正在恢复设置…」藏在一个没打开的面板里，
                // 用户只能靠蓝牙灯猜发生了什么。
                if let button = self.statusItem.button, !self.popover.isShown {
                    self.popover.show(relativeTo: button)
                }
            }
            if endAwayHotKey == nil {
                HKMLog.info("快捷键 \(GlobalHotKey.endAwayLabel) 注册失败（可能被别的软件占着）")
            }
        } else if let hotKey = endAwayHotKey {
            hotKey.unregister()
            endAwayHotKey = nil
        }
    }

    /// 系统唤醒时调用：把「外出中」那一页摆出来。
    private func showForWake() {
        guard let button = statusItem.button, !popover.isShown else { return }
        popover.show(relativeTo: button)
    }

    @objc private func appearanceChanged() {
        refreshIcon()
    }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        button.image = MenuBarIcon.image(for: state.iconState, appearance: button.effectiveAppearance)
        button.setAccessibilityLabel(L("无头骑士大师"))
    }
}
