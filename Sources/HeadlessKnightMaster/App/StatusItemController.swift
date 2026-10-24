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
            popover.hide()
            return
        }
        state.handleIconTap()
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
