import AppKit
import Combine

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let state: AppState
    private let popover: PopoverHost
    private var cancellables: Set<AnyCancellable> = []

    init(state: AppState) {
        self.state = state
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = PopoverHost(state: state)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "无头骑士大师"
        }

        state.iconStatePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &cancellables)

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
        button.setAccessibilityLabel("无头骑士大师")
    }
}
