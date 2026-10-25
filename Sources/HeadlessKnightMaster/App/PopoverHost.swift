import AppKit
import Combine
import HKMKit
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
        // 万一还是摆到了别扭的地方，用户能自己拖出来。
        // 以前这里只有 `isMovable = false`：窗口掉到屏幕下面之后既拖不动也点不到，
        // 只能看着它。
        panel.isMovableByWindowBackground = true
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

        // 插拔显示器会让系统重新安排所有窗口的位置，我们这扇面板也在其中。
        // 屏幕参数一变就重新摆一次，别等下一次 show()。
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.place() }
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

    /// 把面板挂到状态栏按钮上。
    ///
    /// 以前只有 `show()` 里才记这个锚点，于是「开机时状态就是外出中」那条路径
    /// （`screenChanged` 直接 `orderFrontRegardless`）从来没被摆过位置，面板
    /// 一直待在创建时的坐标上——屏幕最下面，然后一路往下长。
    func attach(to button: NSStatusBarButton) {
        anchorButton = button
    }

    func show(relativeTo button: NSStatusBarButton) {
        anchorButton = button
        resize()
        place()
        activateApp()
        panel.makeKeyAndOrderFront(nil)
        resize()
        place()
        // 状态栏窗口在启动初期还没摆好，这会儿拿到的锚点可能是假的。
        // 等菜单栏布好之后再对一次位置，用户不会看见这个过程。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.place()
        }
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
                resize()
                panel.orderFrontRegardless()
                place()
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
        let width = PopoverHost.contentWidth
        if abs(view.frame.height - height) > 0.5 {
            view.setFrameSize(NSSize(width: width, height: height))
        }
        var sizeChanged = false
        if abs(panel.frame.height - height) > 0.5 {
            // 窗口是往下长的，所以固定顶边、只改高度。
            var frame = panel.frame
            frame.origin.y = frame.maxY - height
            frame.size = NSSize(width: width, height: height)
            panel.setFrame(frame, display: true)
            sizeChanged = true
        }
        // 尺寸变了就重新摆一次；没变的话只在「已经跑到屏幕外」时纠正。
        // 无条件摆会让用户手动拖过的位置每秒被拽回去一次（ticker 每秒都在发状态）。
        if sizeChanged || !isFullyOnScreen {
            place()
        }
    }

    private var isFullyOnScreen: Bool {
        guard let visible = anchorScreen()?.visibleFrame else { return true }
        return PanelPlacement.isFullyVisible(panel.frame, in: visible)
    }

    private func anchorScreen() -> NSScreen? {
        anchorButton?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func anchorRect() -> CGRect? {
        guard let button = anchorButton, let window = button.window else { return nil }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        // 启动那一下状态栏窗口还没就位，`convertToScreen` 会算出 (0, -23) 这种
        // 落在屏幕外面的坐标。拿它去摆窗口，面板就跑到屏幕左下角去了。
        // 菜单栏按钮必然在上半屏，不满足就当没有锚点。
        guard let screen = anchorScreen(), rect.midY > screen.frame.midY else { return nil }
        return rect
    }

    /// 摆到状态栏按钮下面，并且保证整块都在屏幕里。
    private func place() {
        guard let visible = anchorScreen()?.visibleFrame else { return }
        let anchor = anchorRect()
        let origin = PanelPlacement.origin(
            anchor: anchor,
            content: panel.frame.size,
            visible: visible
        )
        if panel.frame.origin != origin {
            HKMLog.info("面板摆位：锚点 \(anchor.map { "\($0)" } ?? "无")，尺寸 \(panel.frame.size)，可用 \(visible) → \(origin)")
            panel.setFrameOrigin(origin)
        }
    }
}

/// 无边框面板默认不能当 key window，那样里面的按钮点不动。
final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
