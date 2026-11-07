import Foundation
import IOKit.pwr_mgt

/// 一个「别让机器空闲睡眠」的电源断言。
///
/// 用 `kIOPMAssertionTypePreventUserIdleSystemSleep`，不是 `PreventSystemSleep`。
/// 两者的区别很要命：
///   · 前者只挡「空闲自动睡」，`pmset sleepnow` 照样能睡——这正是本产品要的，
///     平时机器醒着干活，出门时我们主动叫它睡，不冲突；
///   · 后者连强制睡眠都挡，一旦勾上，外出模式会把机器留在醒着的状态里。
///
/// **不管屏幕**。屏幕该关就关（电池模式 `displaysleep` 两分钟），机器继续跑——
/// 对无头机器来说这就是对的：省电，也不烧屏。2026-11-03 用户看过黑屏现场之后的
/// 原话是「这蛮好的」。所以这里只拿系统那一条，不要顺手加上显示器断言。
///
/// 断言跟着进程走：App 被杀掉时内核自己回收，不存在「软件关了机器还醒着」。
public final class SleepAssertion: @unchecked Sendable {
    /// 为什么没拿到。设置页要能说清楚，而不是显示一个假的「已生效」。
    public enum Failure: Error, Equatable, Sendable {
        case notPermitted
        case unknown(IOReturn)

        public var message: String {
            switch self {
            case .notPermitted:
                return L("系统不允许这个程序保持清醒")
            case let .unknown(code):
                return L("系统拒绝了请求（代码 {0}）", Int(code))
            }
        }
    }

    private let lock = NSLock()
    private var assertionID: IOPMAssertionID = 0
    /// 上一次「要拿却没拿到」时系统给的原因。
    ///
    /// 有它才能把「系统拒绝」和「我们自己放开了」分开。以前只有一个 Bool，
    /// 两种完全不同的情况在界面上是同一句话——于是设置页把「出门时故意放开」
    /// 说成了「系统没允许」（2026-11-07 用户抓到的就是这句）。
    private var lastFailureStorage: Failure?
    private let reason: String

    public init(reason: String = "无头骑士大师：保持清醒") {
        self.reason = reason
    }

    deinit {
        release()
    }

    /// 现在拿着断言吗。
    public var isHolding: Bool {
        lock.lock()
        defer { lock.unlock() }
        return assertionID != 0
    }

    /// 上一次想拿却没拿到的原因。拿着、或者从没试过，都是 nil。
    public var lastFailure: Failure? {
        lock.lock()
        defer { lock.unlock() }
        return lastFailureStorage
    }

    /// 拿到断言。重复调用是幂等的。
    @discardableResult
    public func hold() -> Result<Void, Failure> {
        lock.lock()
        defer { lock.unlock() }
        guard assertionID == 0 else { return .success(()) }

        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            let failure: Failure = result == kIOReturnNotPermitted ? .notPermitted : .unknown(result)
            lastFailureStorage = failure
            HKMLog.error("防空闲睡眠断言没拿到：\(result)")
            return .failure(failure)
        }
        assertionID = id
        lastFailureStorage = nil
        HKMLog.info("拿到防空闲睡眠断言 #\(id)")
        return .success(())
    }

    /// 放掉。没拿着时什么都不做。
    public func release() {
        lock.lock()
        defer { lock.unlock() }
        // 主动放开不是失败，原因得清掉，否则「出门时放开」会一直被读成「系统拒绝」。
        lastFailureStorage = nil
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        HKMLog.info("放掉防空闲睡眠断言 #\(assertionID)")
        assertionID = 0
    }

    /// 按设置决定拿着还是放掉。返回最终状态：`true` = 现在拿着。
    @discardableResult
    public func apply(enabled: Bool) -> Bool {
        if enabled {
            switch hold() {
            case .success: return true
            case .failure: return false
            }
        }
        release()
        return false
    }
}
