import Foundation

/// root helper 愿意替客户端做的事的边界。
///
/// socket 是 0666，只靠 uid 判断「谁在问」——同一个用户下**任何**进程都能连进来
/// （不只是一个 App）。所以白名单必须做在 root 进程里，不能指望调用方自觉：
///
/// - `launchctl disable/enable/bootout` 如果不限制 label，任何同 uid 的进程都能
///   停掉任意系统服务；
/// - `launchctl bootstrap` 更危险：label 会被拼进
///   `/System/Library/LaunchDaemons/<label>.plist`，传 `../../tmp/evil` 就能让
///   root 去 bootstrap 一个用户可写的 plist —— 直接拿到 root。
///
/// 所有判断都放在这里（而不是 helper 的 main.swift），是为了能被测试守住：
/// helper 是独立可执行文件，测试进程里根本调不到。
public enum HelperPolicy {
    /// 应用真正管理的服务，只有一个来源：`SharingControl.labels`。
    /// 测试会核对两者不漂移。
    public static var allowedLaunchctlLabels: [String] { SharingControl.labels }

    /// `pmsetSet` 允许写的键。多一个都算越权。
    public static let allowedPmsetKeys: Set<String> = [
        "disablesleep", "sleep", "womp", "powernap", "tcpkeepalive", "standby", "displaysleep", "disksleep"
    ]

    /// `-a` 全部、`-c` 插电、`-b` 电池。
    public static let allowedPmsetScopes: Set<String> = ["a", "c", "b"]

    public static func isAllowedLaunchctlLabel(_ label: String) -> Bool {
        allowedLaunchctlLabels.contains(label)
    }

    /// label → 系统 plist 路径。**只有白名单里的 label 才有路径**，
    /// 客户端给的字符串永远不直接拼进路径。
    public static func launchDaemonPlistPath(for label: String) -> String? {
        guard isAllowedLaunchctlLabel(label) else { return nil }
        return "/System/Library/LaunchDaemons/\(label).plist"
    }

    public static func isAllowedPmsetKey(_ key: String) -> Bool {
        allowedPmsetKeys.contains(key)
    }

    public static func isAllowedPmsetScope(_ scope: String) -> Bool {
        allowedPmsetScopes.contains(scope)
    }

    /// pmset 的值一律是整数。命令行是 argv 传的，不存在 shell 注入，
    /// 但「只收整数」能挡掉拿它当万能参数通道的尝试。
    public static func isAllowedPmsetValue(_ value: String) -> Bool {
        Int(value) != nil
    }
}
