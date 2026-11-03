import CoreGraphics
import Darwin
import Foundation

/// 把内建屏从显示拓扑里摘掉、再装回来。
///
/// 走的是 MacHead 那条路：`dlopen` SkyLight，`dlsym` 拿私有函数
/// `CGSConfigureDisplayEnabled`，配合公开的 `CGBeginDisplayConfiguration` /
/// `CGCompleteDisplayConfiguration` 提交一次显示配置事务。不需要 root，也不需要
/// 装后台服务——它改的是当前登录会话的显示拓扑，不是系统设置。
///
/// **失败必须如实说。** `CGSConfigureDisplayEnabled` 返回 0 只代表「这次调用没报错」，
/// 真正的结果要去活动列表里回读。这个软件所有「说不清就别说成成功」的规矩，
/// 在这里同样适用。
public final class DisplayController: @unchecked Sendable {
    public enum Outcome: Sendable, Equatable {
        /// 已经处于目标状态，什么都没做（幂等，不是失败）。
        case unchanged(id: CGDirectDisplayID)
        case disconnected(id: CGDirectDisplayID)
        case reconnected(id: CGDirectDisplayID)
        /// 当前系统里找不到内建屏：可能已经断了、也可能被别的软件摘了。
        case builtinNotFound
        /// 私有接口在系统上拿不到。这个版本能做的事到此为止。
        case apiUnavailable
        case failed(reason: String)

        public var isChanging: Bool {
            switch self {
            case .disconnected, .reconnected: return true
            default: return false
            }
        }
    }

    /// 上次成功断开的那个 ID 存在这里。
    ///
    /// 内建屏断开之后 `CGDisplayIsBuiltin` 仍然认得出 ID，但它不再出现在 online /
    /// active 列表里，所以只靠枚举是找不到的。存一份，`--restore-builtin` 和
    /// 键盘恢复都依赖它。
    private static let cacheKey = "BuiltInDisplayID"

    /// Apple Silicon 的内建屏历来是 1 号。**只在验证过 `CGDisplayIsBuiltin` 之后
    /// 才拿它动手**——盲试会把别人的屏关掉。
    private static let appleSiliconBuiltinID: CGDirectDisplayID = 1

    /// 提交一次、等它生效、再回读，最多试这么多次。
    private let maxAttempts = 5
    private let retryDelay: Duration = .milliseconds(200)

    private let setEnabled: CGSConfigureDisplayEnabledFunc?

    public init() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        ) else {
            setEnabled = nil
            HKMLog.error("DisplayController：打不开 SkyLight，断不了内建屏")
            return
        }
        let symbol = dlsym(handle, "CGSConfigureDisplayEnabled")
        setEnabled = symbol.map { unsafeBitCast($0, to: CGSConfigureDisplayEnabledFunc.self) }
        if setEnabled == nil {
            HKMLog.error("DisplayController：SkyLight 里没有 CGSConfigureDisplayEnabled")
        }
    }

    /// 这个系统能不能干这件事。设置页用它决定要不要把开关显示成灰的。
    public var isAvailable: Bool { setEnabled != nil }

    // MARK: - 查询

    /// 内建屏现在亮着吗（在活动列表里）。
    public var isBuiltinActive: Bool {
        guard let id = builtinDisplayID() else { return false }
        return CGDisplayIsActive(id) == 1
    }

    /// 内建屏现在还算「插着」吗（断开之后是 false）。
    public var isBuiltinOnline: Bool {
        DisplayWatcher.onlineDisplayIDs().contains { CGDisplayIsBuiltin($0) == 1 }
    }

    /// 当前内建屏的 ID。
    ///
    /// 顺序：在线列表里找 → 缓存 → Apple Silicon 的 1 号兜底。**每一条都必须过
    /// `CGDisplayIsBuiltin == 1` 这一关**：`CGDisplayIsBuiltin` 对不存在的 ID 返回
    /// -1 而不是 0，所以判断写 `== 1`，不用 `!= 0`。
    public func builtinDisplayID() -> CGDirectDisplayID? {
        if let id = DisplayWatcher.onlineDisplayIDs().first(where: { CGDisplayIsBuiltin($0) == 1 }) {
            cache(id)
            return id
        }
        if let cached = cachedID(), CGDisplayIsBuiltin(cached) == 1 {
            return cached
        }
        if CGDisplayIsBuiltin(Self.appleSiliconBuiltinID) == 1 {
            return Self.appleSiliconBuiltinID
        }
        return nil
    }

    // MARK: - 断开 / 接回

    /// 断开内建屏。已经在断开状态时直接返回 `.unchanged`。
    public func disconnect() async -> Outcome {
        guard setEnabled != nil else { return .apiUnavailable }
        guard let id = builtinDisplayID() else { return .builtinNotFound }
        if CGDisplayIsActive(id) == 0, !isBuiltinOnline {
            cache(id)
            return .unchanged(id: id)
        }
        HKMLog.info("断开内建屏 #\(id)（当前 online：\(DisplayWatcher.describeDisplays())）")
        return await apply(enabled: false, id: id)
    }

    /// 接回内建屏。已经亮着时返回 `.unchanged`。
    public func reconnect() async -> Outcome {
        guard setEnabled != nil else { return .apiUnavailable }
        guard let id = builtinDisplayID() else { return .builtinNotFound }
        if CGDisplayIsActive(id) == 1 {
            return .unchanged(id: id)
        }
        HKMLog.info("接回内建屏 #\(id)")
        return await apply(enabled: true, id: id)
    }

    /// 提交 + 回读。回读不过就重试：WindowServer 应用显示配置是异步的，
    /// 第一次提交之后立刻读，经常还能读到旧状态。
    private func apply(enabled: Bool, id: CGDirectDisplayID) async -> Outcome {
        var lastDetail = ""
        for attempt in 1...maxAttempts {
            let status = commit(enabled: enabled, id: id)
            if status != 0 {
                lastDetail = "提交失败，状态码 \(status)"
                HKMLog.error("内建屏 \(enabled ? "接回" : "断开")第 \(attempt) 次：\(lastDetail)")
            } else if await waitUntilSettled(enabled: enabled, id: id) {
                if enabled {
                    cache(id)
                    HKMLog.info("内建屏已接回 #\(id)，online：\(DisplayWatcher.describeDisplays())")
                    return .reconnected(id: id)
                }
                cache(id)
                HKMLog.info("内建屏已断开 #\(id)，online：\(DisplayWatcher.describeDisplays())")
                return .disconnected(id: id)
            } else {
                lastDetail = "提交成功但状态没变"
                HKMLog.error("内建屏 \(enabled ? "接回" : "断开")第 \(attempt) 次：\(lastDetail)")
            }
            if attempt < maxAttempts {
                try? await Task.sleep(for: retryDelay)
            }
        }
        return .failed(reason: lastDetail.isEmpty ? "没试出结果" : lastDetail)
    }

    private func commit(enabled: Bool, id: CGDirectDisplayID) -> Int32 {
        guard let setEnabled else { return -1 }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            return -2
        }
        let status = setEnabled(config, id, enabled)
        guard status == 0 else {
            CGCancelDisplayConfiguration(config)
            return status
        }
        // `.permanently` 跟 MacHead 一致：`.forSession` 在系统重排（拔插另一块屏、
        // 唤醒）时会被丢掉，那时用户看到的就是内屏自己又亮了。
        let complete = CGCompleteDisplayConfiguration(config, .permanently)
        guard complete == .success else {
            CGCancelDisplayConfiguration(config)
            return complete.rawValue
        }
        return 0
    }

    /// 等 WindowServer 把配置应用上去。最多等 1 秒，够用且不卡界面。
    private func waitUntilSettled(enabled: Bool, id: CGDirectDisplayID) async -> Bool {
        for _ in 0..<10 {
            let active = CGDisplayIsActive(id) == 1
            if active == enabled { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return (CGDisplayIsActive(id) == 1) == enabled
    }

    // MARK: - ID 缓存

    /// 用 standard 而不是 `UserDefaults(suiteName: bundleID)`。
    ///
    /// 后者会触发 AppKit 的 «Using your own bundle identifier as a suite name
    /// does not make sense»，而且真的不生效。standard 在 .app 里就是 bundle 的域，
    /// 从 `.app/Contents/MacOS/Knight --restore-builtin` 跑也读得到——命令行进程
    /// 仍然带着 Info.plist，bundle id 是同一个。
    private func cache(_ id: CGDirectDisplayID) {
        guard cachedID() != id else { return }
        UserDefaults.standard.set(Int(id), forKey: Self.cacheKey)
        HKMLog.info("记下内建屏 ID：\(id)")
    }

    private func cachedID() -> CGDirectDisplayID? {
        guard let raw = UserDefaults.standard.object(forKey: Self.cacheKey) as? Int,
              raw > 0 else { return nil }
        return CGDirectDisplayID(raw)
    }
}

private typealias CGSConfigureDisplayEnabledFunc = @convention(c) (
    CGDisplayConfigRef?,
    CGDirectDisplayID,
    Bool
) -> Int32
