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

    /// 确保有权限再发。没授权就当场要一次，而不是把通知丢进黑洞。
    ///
    /// 「试一下」点了没反应，一半原因是没授权：`center.add` 对没授权的应用
    /// 不会报错，它只是什么都不做。
    public func ensureAuthorization() async -> Bool {
        guard let center else { return false }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            HKMLog.info("通知授权：\(granted ? "已允许" : "被拒绝")")
            return granted
        default:
            return false
        }
    }

    /// 发一条测试通知，然后**去核实**它到底有没有出现。
    ///
    /// 只看 `add` 有没有抛错是不够的：没授权、专注模式、通知样式设成「无」，
    /// `add` 全都一声不吭地成功。用户看到的就是「点了没反应」。
    /// 所以发完要分两处核对——前台代理有没有真的展示它，系统有没有收进通知中心。
    public func sendTest(title: String, body: String) async -> NotificationTestResult {
        guard let center else { return .failed("没有 bundle id，弹不了") }
        guard await ensureAuthorization() else { return .notAuthorized }

        let identifier = UUID().uuidString
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        } catch {
            HKMLog.error("发送通知失败：\(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }

        // 派发是异步的，等一会儿再问。等太久用户会以为按钮坏了。
        try? await Task.sleep(nanoseconds: 900_000_000)
        if NotificationPresenter.shared.lastPresentedIdentifier == identifier {
            HKMLog.info("测试通知已弹出")
            return .shown
        }
        let delivered = await center.deliveredNotifications()
        if delivered.contains(where: { $0.request.identifier == identifier }) {
            HKMLog.info("测试通知已送达通知中心，但前台没弹")
            return .delivered
        }
        HKMLog.info("测试通知被系统挡掉了")
        return .suppressed
    }

    /// 装上前台展示的代理。
    ///
    /// 应用是活动应用时，系统默认**不显示**横幅：它把通知交给 delegate，
    /// 没人实现 `willPresent` 就什么也不弹。设置页开着的时候点「试一下」，
    /// 正好命中这一条——日志里写着「已发送通知」，屏幕上什么都没有。
    public static func installDelegate() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
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

/// 应用在前台时把通知照常显示出来。
///
/// `willPresent` 的默认行为是「不显示」——这是 macOS 的规矩，不是 bug。可对一个
/// 菜单栏软件来说，用户几乎总是在前台点它（设置页、拔线页都在面板里），
/// 于是所有通知都变成了日志里的一行。
@MainActor
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    /// 最后一条真的被展示出来的通知的 id。
    ///
    /// 「试一下」发完之后比对它，就能知道横幅到底弹没弹——比看 `add` 有没有
    /// 抛错靠谱得多，后者对专注模式、关掉横幅这些情况完全无感。
    private(set) var lastPresentedIdentifier: String?

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let identifier = notification.request.identifier
        await MainActor.run {
            NotificationPresenter.shared.lastPresentedIdentifier = identifier
        }
        return [.banner, .sound, .list]
    }
}
