import Foundation

/// 谁还登录着这台机器。
///
/// 强力模式要在「外出中机器一直醒着」的时候强制睡眠。但有一种「醒着」是正当的：
/// 有人正通过 SSH 在这台机器上干活。把人家正在跑的任务弄睡，比多耗一点电糟糕
/// 得多，所以强制睡眠前必须先问一句。
///
/// 判据只看**带来源地址的登录**：macOS 的 `who` 对 SSH 会话会在行尾附上
/// `(10.0.0.5)`，而本机的终端窗口（包括 App 自己开的）没有这一段。用
/// 「有没有 ttys」判断是不行的——本机 Terminal 也是 ttys，会把用户自己的终端
/// 误当成远程登录，导致强力模式永远不触发。
public struct RemoteSessionProbe: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ShellRunner()) {
        self.runner = runner
    }

    public func remoteLogins() -> [String] {
        guard let result = try? runner.run("/usr/bin/who", arguments: [], timeout: 5),
              result.succeeded
        else { return [] }
        return RemoteSessionProbe.parse(result.stdout)
    }

    public static func parse(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            // SSH 会话长这样：alice  ttys001  Oct 24 09:20 (10.0.0.5)
            guard let open = line.lastIndex(of: "("), line.hasSuffix(")") else { return nil }
            let source = line[line.index(after: open)..<line.index(before: line.endIndex)]
            guard !source.isEmpty else { return nil }
            return line
        }
    }
}
