import Foundation
import HKMKit
// `UNNotificationSettings` 没有标注 Sendable，Swift 6 会把 `notificationSettings()`
// 的返回值当成「跨隔离域传递」而报错。这里只是读几个枚举值，用 @preconcurrency
// 承认这个 SDK 缺口，而不是把整个类改成 nonisolated。
@preconcurrency import UserNotifications

/// Thin wrapper so notification failures never break a flow (and so the app can
/// run from `swift run`, where there is no bundle identifier).
///
/// 这里曾经用 completion-handler 版本，把 `@MainActor` 的闭包交给了
/// `UNUserNotificationCenter` 在 `com.apple.usernotifications...call-out` 队列上
/// 的异步回调：闭包里带着主 actor 的断言，在后台线程上执行就直接
/// `_dispatch_assert_queue_fail` → SIGTRAP。
/// 崩溃报告 `HeadlessKnightMaster-2026-10-23-231948.ips` 的触发栈就是这个。
/// 现在一律用 async API，闭包根本不存在，也就没有执行器错配的可能。
@MainActor
public final class Notifier {
    private let center: UNUserNotificationCenter?

    public init() {
        if Bundle.main.bundleIdentifier != nil {
            center = UNUserNotificationCenter.current()
        } else {
            center = nil
        }
    }

    public func requestAuthorization() {
        guard let center else { return }
        Task {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                HKMLog.info("通知授权：\(granted ? "已允许" : "被拒绝")")
            } catch {
                HKMLog.error("通知授权失败：\(error.localizedDescription)")
            }
        }
    }

    public func post(title: String, body: String) {
        guard let center else {
            HKMLog.info("（无 bundle id）通知：\(title) - \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            do {
                try await center.add(request)
                HKMLog.info("已发送通知：\(title)")
            } catch {
                HKMLog.error("发送通知失败：\(error.localizedDescription)")
            }
        }
    }

    /// 通知到底能不能弹出来。
    ///
    /// 用户说过「弹窗一次也没看到过」——真实原因是 `post()` 在真机上从来没被
    /// 调用过（触发点只有「欢迎回来」和「睡眠失败」），但光靠日志没法证明。
    /// 把授权状态摆到界面上，再给一个「试一下」，就不用猜了。
    public func authorizationSummary() async -> String {
        guard let center else { return "没有 bundle id，弹不了" }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            let style: String
            switch settings.alertStyle {
            case .banner: style = "横幅"
            case .alert: style = "提醒"
            default: style = "横幅已关闭"
            }
            return "已允许 · \(style)"
        case .denied:
            return "被拒绝（去系统设置里打开）"
        case .notDetermined:
            return "还没问过"
        @unknown default:
            return "未知"
        }
    }
}
