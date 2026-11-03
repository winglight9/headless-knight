import AppKit
import Carbon.HIToolbox

/// 一个全局快捷键。
///
/// 为什么需要它：外出模式的唯一出口是面板上那个「结束外出模式」。面板是一扇
/// 贴在菜单栏下面的窗口，它有可能摆错地方（多屏、拆掉内建屏的机器上都遇到过），
/// 也可能被别的东西挡住——那一刻用户就**没有任何办法**结束这一趟，只能强退。
/// 键盘不依赖窗口，是最可靠的那条退路。
///
/// 用 Carbon 的 `RegisterEventHotKey`，不用 `NSEvent.addGlobalMonitorForEvents`：
/// 后者要「辅助功能」授权，而这是个装完就该能用的菜单栏小工具，不该为了一个
/// 快捷键把用户赶去系统设置里勾权限。
@MainActor
final class GlobalHotKey {
    /// 哪个 id 对应哪个动作。Carbon 的回调里只有 id，没有闭包。
    private static var actions: [UInt32: @MainActor () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handler: EventHandlerRef?
    /// 四字符签名，随便挑一个不撞的。
    private static let signature: OSType = 0x484B_4B31 // 'HKK1'

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// 快捷键显示成什么样，给界面和日志用。
    let label: String

    /// 注册失败（被别的软件占了同一个组合）时返回 nil，调用方自己决定要不要提示。
    init?(keyCode: UInt32, modifiers: UInt32, label: String, action: @escaping @MainActor () -> Void) {
        guard GlobalHotKey.installHandlerIfNeeded() else { return nil }

        let id = GlobalHotKey.nextID
        GlobalHotKey.nextID += 1
        self.id = id
        self.label = label

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: GlobalHotKey.signature, id: id)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else { return nil }
        ref = hotKeyRef
        GlobalHotKey.actions[id] = action
    }

    func unregister() {
        if let ref {
            UnregisterEventHotKey(ref)
        }
        ref = nil
        GlobalHotKey.actions[id] = nil
    }

    private static func installHandlerIfNeeded() -> Bool {
        if handler != nil { return true }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            // Carbon 的回调不在主线程上，界面相关的动作必须回主线程做。
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    GlobalHotKey.actions[id]?()
                }
            }
            return noErr
        }
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &spec,
            nil,
            &ref
        )
        guard status == noErr else { return false }
        handler = ref
        return true
    }

    /// 结束外出模式的默认组合：⌃⌥⌘E。
    ///
    /// 三个修饰键是有意的：这个键会在用户用别的软件时也生效，跟任何常用快捷键
    /// 撞车都会很烦人；而且它只在「出门流程进行中」才注册，回到首页就注销。
    static let endAwayKeyCode = UInt32(kVK_ANSI_E)
    static let endAwayModifiers = UInt32(controlKey | optionKey | cmdKey)
    static let endAwayLabel = "⌃⌥⌘E"

    /// 内建屏开关：⌘H。按一下接回，再按一下断开。
    ///
    /// 选它是用户定的，代价也说清楚了：这个键平时是「隐藏窗口」，被我们占了之后
    /// **所有 App 的 ⌘H 都会失效**。换来的是「屏黑了也有一条不依赖界面的活路」——
    /// 断开内建屏之后，菜单栏、面板都可能在别处，只有键盘还在。
    static let builtinKeyCode = UInt32(kVK_ANSI_H)
    static let builtinModifiers = UInt32(cmdKey)
    static let builtinLabel = "⌘H"
}
