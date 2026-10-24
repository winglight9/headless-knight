import AppKit
import Combine
import SwiftUI

/// 唯一的那扇窗口：贴在状态栏图标下面的一块面板。
///
/// 以前用的是 `NSPopover`，`behavior = .transient`。它的规则是「焦点一离开就自己
/// 收起来」——关掉一个程序、点一下别处、系统把 app 挂到后台，窗口就没了。于是
/// 用户看到的是：点「一键关闭」→ 窗口消失 → 鼠标卡一下 → 再点图标才看见「可以
/// 拔掉显示器了」。用户的原话是「需要一直显示着窗口直到用户点结束外出模式」。
///
/// 现在换成一个 `NSPanel`：位置、圆角、阴影都自己控制，流程没结束之前，
/// 点哪儿它都不会消失。
@MainActor
final class PopoverHost: NSObject, NSWindowDelegate {
    private let panel: PopupPanel
    private let hosting: NSHostingController<AnyView>
    private var cancellables: Set<AnyCancellable> = []
    private weak var anchorButton: NSStatusBarButton?
    private var currentScreen: AppState.Screen = .home

    static let contentWidth: CGFloat = 300

    init(state: AppState) {
        hosting = NSHostingController(rootView: AnyView(RootView().environmentObject(state)))
        panel = PopupPanel(
            contentRect: NSRect(x: 0, y: 0, width: PopoverHost.contentWidth, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self
        panel.contentViewController = hosting
        hosting.view.frame = NSRect(x: 0, y: 0, width: PopoverHost.contentWidth, height: 220)

        state.$screen
            .receive(on: RunLoop.main)
            .sink { [weak self] screen in self?.screenChanged(screen) }
            .store(in: &cancellables)

        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self?.resize()
                }
            }
            .store(in: &cancellables)
    }

    var isShown: Bool { panel.isVisible }

    /// 当前这一页是不是「必须一直看着」的那种。
    var isStickyScreen: Bool { isSticky }

    /// 这几页必须一直看得见，直到用户自己点「结束外出模式」。
    private var isSticky: Bool {
        switch currentScreen {
        case .scanning, .detecting, .closing, .blocked, .readyToUnplug, .away:
            return true
        default:
            return false
        }
    }

    func show(relativeTo button: NSStatusBarButton) {
        anchorButton = button
        resize()
        position(relativeTo: button)
        activateApp()
        panel.makeKeyAndOrderFront(nil)
        resize()
    }

    func hide() {
        panel.orderOut(nil)
        onHidden?()
    }

    /// 窗口自己收起来了（点别处、再点一下图标、点「完成」）。报告页收起来
    /// 就等于这一趟看完了，界面该回到首页，别下次点图标还是那份旧报告。
    var onHidden: (@MainActor () -> Void)?

    /// 流程进行中，用户又点了一下图标：别关，把它提到前面就行。
    func bringToFront() {
        panel.orderFrontRegardless()
    }

    private func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func screenChanged(_ screen: AppState.Screen) {
        currentScreen = screen
        // 进了必须一直看着的那几页：窗口被收走了就摆回来。
        if isSticky, !panel.isVisible {
            if let button = anchorButton {
                show(relativeTo: button)
            } else {
                // 拿不到状态栏按钮（比如图标还没就位）也得让用户看见，否则
                // 流程在跑、界面却没影，正是用户抱怨的那件事。
                panel.orderFrontRegardless()
            }
            return
        }
        // 流程结束、人也不在这个 app 上：像普通弹窗一样收起来。
        if !isSticky, panel.isVisible, !panel.isKeyWindow {
            hide()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // 流程没结束就不许自己消失——这正是用户抱怨的那件事。
        guard !isSticky else { return }
        hide()
    }

    private func resize() {
        let view = hosting.view
        view.layoutSubtreeIfNeeded()
        let height = max(120, ceil(view.fittingSize.height))
        if abs(panel.frame.height - height) > 0.5 {
            // 窗口是往下长的，所以固定顶边、只改高度。
            let top = panel.frame.maxY
            panel.setFrame(
                NSRect(x: panel.frame.minX, y: top - height,
                       width: PopoverHost.contentWidth, height: height),
                display: true
            )
        }
        if abs(view.frame.height - height) > 0.5 {
            view.setFrameSize(NSSize(width: PopoverHost.contentWidth, height: height))
        }
    }

    private func position(relativeTo button: NSStatusBarButton) {
        guard let window = button.window else { return }
        let inWindow = button.convert(button.bounds, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        let size = panel.frame.size

        var x = onScreen.midX - size.width / 2
        var y = onScreen.minY - size.height - 6
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            x = min(max(visible.minX + 8, x), visible.maxX - size.width - 8)
            if y < visible.minY + 8 {
                y = onScreen.maxY + 6
            }
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// 无边框面板默认不能当 key window，那样里面的按钮点不动。
final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
