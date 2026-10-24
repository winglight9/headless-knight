import Foundation

/// 把底层错误翻译成用户看得懂的话。
///
/// 设计文档要求技术细节默认不可见，所以界面上永远不出现 `tmutil`、`launchctl`
/// 的英文原文；原文只写到 stderr，方便事后排查。
public enum FailureText {
    public static func humanize(_ raw: String, severity: FailedItem.Severity) -> String {
        let text = raw.lowercased()

        if text.contains("full disk access") {
            return severity == .optional
                ? "需要额外权限，这一项不影响睡眠"
                : "需要额外权限才能完成"
        }
        if text.contains("no destinations configured") {
            return "没有配置备份目标，已跳过"
        }
        if text.contains("operation not permitted")
            || text.contains("permission denied")
            || text.contains("not authorized")
            || text.contains("must be run as root")
            || text.contains("authorization") {
            return severity == .optional
                ? "权限不足，这一项不影响睡眠"
                : "权限不足"
        }
        if text.contains("not installed") || text.contains("后台服务") {
            return severity == .optional
                ? "后台服务没有安装，这一项不影响睡眠"
                : "后台服务没有安装"
        }
        // 已经是中文的（比如「蓝牙状态没有变化」）就原样保留，别降级成「操作失败」。
        if raw.unicodeScalars.contains(where: { $0.value >= 0x4E00 && $0.value <= 0x9FFF }) {
            return raw
        }
        return severity == .optional ? "操作失败，不影响睡眠" : "操作失败"
    }

    /// 历史报告里存的是升级前的 shell 原文，读出来时补一次人话化。
    ///
    /// 新写入的记录本来就是人话，这个函数对它们是空操作。
    public static func sanitizeLegacySummary(_ summary: String) -> String {
        guard let separator = summary.firstIndex(of: "：") else {
            return isShellOutput(summary) ? humanize(summary, severity: .optional) : summary
        }
        let title = String(summary[summary.startIndex..<separator])
        let detail = String(summary[summary.index(after: separator)...])
        guard isShellOutput(detail) else { return summary }
        return "\(title)：\(humanize(detail, severity: .optional))"
    }

    /// 判断一段文字是不是还没翻译过的 shell 输出。
    public static func isShellOutput(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("full disk access")
            || lower.contains("operation not permitted")
            || lower.contains("permission denied")
            || lower.contains("must be run as root")
            || lower.contains("no destinations configured")
            || lower.contains("privileges")
    }
}

/// 走完出门流程后，接下来该去哪一页。
///
/// 抽成纯函数是因为这条判断是这次 bug 的核心：优化项失败绝不能挡住用户出门。
public enum AwayDecision: Equatable, Sendable {
    /// 全部成功。
    case proceed
    /// 只有优化项失败：照常出门，用一行小字交代。
    case proceedWithNotes([FailedItem])
    /// 有关键项失败：进阻塞页。
    case blocked([FailedItem])

    public static func decide(_ failures: [FailedItem]) -> AwayDecision {
        let critical = failures.filter(\.isCritical)
        if !critical.isEmpty {
            return .blocked(critical)
        }
        return failures.isEmpty ? .proceed : .proceedWithNotes(failures)
    }

    /// 是否允许继续走到「可以拔掉显示器了」。
    public var canProceed: Bool {
        switch self {
        case .proceed, .proceedWithNotes: return true
        case .blocked: return false
        }
    }
}
