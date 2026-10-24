import AppKit
import CoreGraphics
import Foundation

/// Watches the active display count. Used for "拔线后 5 秒睡眠" and for the
/// one-time "欢迎回来" notification — event driven, never a polling timer.
public final class DisplayWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@MainActor @Sendable (Int) -> Void)?
    private var registered = false

    public init() {}

    deinit {
        if registered {
            CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    public static func activeDisplayCount() -> Int {
        var count: UInt32 = 0
        let result = CGGetActiveDisplayList(0, nil, &count)
        guard result == .success else { return 0 }
        return Int(count)
    }

    /// 接着的显示器（含已休眠但还插着的）。判断「拔没拔」要看它，不要看数量。
    public static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// 主显示器。拔掉唯一那块屏之后这个 ID 会换人，是最可靠的「拔线」信号。
    public static func mainDisplayID() -> CGDirectDisplayID {
        CGMainDisplayID()
    }

    /// 一块屏在当前这一刻的完整身份。日志和「残影屏」判断都要用。
    public struct DisplaySnapshot: Sendable, CustomStringConvertible {
        public let id: CGDirectDisplayID
        public let builtin: Bool
        public let active: Bool
        public let asleep: Bool
        public let vendor: UInt32
        public let model: UInt32
        public let serial: UInt32
        public let width: Int
        public let height: Int

        public init(
            id: CGDirectDisplayID,
            builtin: Bool,
            active: Bool,
            asleep: Bool,
            vendor: UInt32,
            model: UInt32,
            serial: UInt32,
            width: Int,
            height: Int
        ) {
            self.id = id
            self.builtin = builtin
            self.active = active
            self.asleep = asleep
            self.vendor = vendor
            self.model = model
            self.serial = serial
            self.width = width
            self.height = height
        }

        public var description: String {
            var parts = ["#\(id)"]
            if builtin { parts.append("内建") }
            if !active { parts.append("非活动") }
            if asleep { parts.append("已休眠") }
            parts.append("\(width)x\(height)")
            // 拔线之后系统留下的影子屏，vendor/model/serial 通常是 0。
            parts.append("v\(vendor)/m\(model)/s\(serial)")
            return parts.joined(separator: " ")
        }
    }

    public static func snapshot(of id: CGDirectDisplayID) -> DisplaySnapshot {
        let bounds = CGDisplayBounds(id)
        return DisplaySnapshot(
            id: id,
            builtin: CGDisplayIsBuiltin(id) != 0,
            active: CGDisplayIsActive(id) != 0,
            asleep: CGDisplayIsAsleep(id) != 0,
            vendor: CGDisplayVendorNumber(id),
            model: CGDisplayModelNumber(id),
            serial: CGDisplaySerialNumber(id),
            width: Int(bounds.width),
            height: Int(bounds.height)
        )
    }

    public static func snapshots() -> [DisplaySnapshot] {
        onlineDisplayIDs().map { snapshot(of: $0) }
    }

    /// 给日志用：把每块屏的 ID / 是否内建 / 尺寸 / 厂商型号写出来。
    public static func describeDisplays() -> String {
        let list = snapshots()
        guard !list.isEmpty else { return "无" }
        return list.map(\.description).joined(separator: " / ")
    }

    public func setHandler(_ handler: (@MainActor @Sendable (Int) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    public func start() {
        lock.lock()
        let alreadyRegistered = registered
        registered = true
        lock.unlock()
        guard !alreadyRegistered else { return }
        CGDisplayRegisterReconfigurationCallback(
            displayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    public func stop() {
        lock.lock()
        let wasRegistered = registered
        registered = false
        lock.unlock()
        guard wasRegistered else { return }
        CGDisplayRemoveReconfigurationCallback(
            displayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    fileprivate func handleReconfiguration() {
        let count = DisplayWatcher.activeDisplayCount()
        // 无头机上拔掉唯一那块屏之后到底还剩什么，这个数字直接决定「会不会睡」。
        // 2026-10-24 09:41 那次：显示器确实被拔了（coreaudiod 的显示断言同一秒全
        // 释放），但 activeDisplayCount 仍然返回 1——系统留了一块影子屏。所以数量
        // 不能作为判据，必须把 ID 一起打出来。
        HKMLog.info("显示器变化 → active \(count) 个，online：\(DisplayWatcher.describeDisplays())，主屏 \(CGMainDisplayID())")
        lock.lock()
        let current = handler
        lock.unlock()
        guard let current else { return }
        Task { @MainActor in
            current(count)
        }
    }
}

private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, _, userInfo in
    guard let userInfo else { return }
    let watcher = Unmanaged<DisplayWatcher>.fromOpaque(userInfo).takeUnretainedValue()
    watcher.handleReconfiguration()
}
