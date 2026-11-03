import AppKit
import SwiftUI
import Testing

@testable import HeadlessKnightMaster

// MARK: - 面板点不动的那一类毛病
//
// 2026-11-03 下午：「触摸板点按了好多下都不行」。触摸板轻点只发一对几毫秒的
// mouseDown/Up，任何一层「这一下不算」都会被它放大成「按钮坏了」：
//   · 窗口不是 key 时，AppKit 在 `sendEvent` 里就把第一下吞掉了；
//   · 内容再挪一下位置，这一对事件就落在别处了（后者见 `PanelPlacement` 的测试）。

@Suite("面板的点击")
@MainActor
struct PanelInteractionTests {
    /// 只用来数「这一下点击到底有没有送进来」。
    final class ClickSink: NSView {
        private(set) var clicks = 0
        override func mouseDown(with event: NSEvent) {
            clicks += 1
        }
    }

    private func makePanel() -> PopupPanel {
        PopupPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    @Test("面板必须能当 key window，否则里面的按钮点不动")
    func panelCanBecomeKey() {
        let panel = makePanel()
        #expect(panel.canBecomeKey)
        #expect(panel.canBecomeMain == false, "菜单栏小工具不该抢主窗口")
    }

    /// 无边框面板的第一下点击要在 `sendEvent` 里救回来：先 makeKey，再交给
    /// AppKit 正常分发。这条测试盯的是「这一下真的送到了视图里」，而不是
    /// 「窗口变 key 了」——后者 AppKit 自己也会做，代价正是把这一下吞掉。
    @Test("第一下点击要送到视图里，不能只用来激活窗口")
    func firstClickReachesView() throws {
        let panel = makePanel()
        let sink = ClickSink()
        sink.frame = NSRect(x: 0, y: 0, width: 300, height: 220)
        panel.contentView = sink
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        #expect(panel.isKeyWindow == false)

        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 150, y: 110),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        panel.sendEvent(event)

        #expect(sink.clicks == 1, "这一下要是被吞掉，用户点按钮就是「没反应」")
        #expect(panel.isKeyWindow)
    }

    /// 顺手记一笔：`NSHostingController` 在 init 里就把 view 装好了，`loadView`
    /// 不会走。以前打算在 hosting view 上覆写 `acceptsFirstMouse` —— 那条路是死的。
    @Test("hosting view 是系统自己的类，换不掉")
    func hostingViewCannotBeSwapped() {
        let controller = NSHostingController(rootView: AnyView(Text("x")))
        _ = controller.view
        #expect(type(of: controller.view) == NSHostingView<AnyView>.self)
    }
}
