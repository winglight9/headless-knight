import Foundation

/// Turns file sharing / screen sharing / AFP off while away.
///
/// 共享服务属于「少醒几次」的优化项：关不掉也不能挡住用户出门，所以这里的失败
/// 一律标成 optional，并且只对当前确实开着的服务动手。
public struct SharingControl: Sendable {
    public static let labels = [
        "com.apple.smbd",
        "com.apple.screensharing",
        "com.apple.AppleFileServer"
    ]

    private let runner: any CommandRunning
    private let executor: any PrivilegedExecuting

    public init(runner: any CommandRunning = ShellRunner(), executor: any PrivilegedExecuting = PrivilegedExecutorFactory.make()) {
        self.runner = runner
        self.executor = executor
    }

    /// 每个服务对应的「开着就一定会监听」的端口。
    public static let ports: [String: Int] = [
        "com.apple.smbd": 445,
        "com.apple.screensharing": 5900,
        "com.apple.AppleFileServer": 548
    ]

    /// 只看**真的在监听端口**的服务。
    ///
    /// 以前用的是 `launchctl print-disabled`，那里「没有记录」被当成「开着」——
    /// 于是三个服务永远都被认为开着，出门时统统 disable + bootout，回来时统统
    /// enable + **bootstrap**。`bootstrap` 会把服务真的**启动**起来：用户本来没开
    /// 文件共享，出趟门回来 445 端口就开始监听了。这是实打实的功能被偷偷打开。
    ///
    /// 端口在监听，就是「外面能连进来」，这正是我们要判断的事；没监听就一个字节
    /// 都不该动它。
    public func listeningLabels() async -> [String] {
        await offMain { self.listeningLabelsSync() }
    }

    /// `netstat -an -p tcp` 要几十毫秒，界面路径走 async 版本。
    public func listeningLabelsSync() -> [String] {
        let ports = listeningPorts()
        return SharingControl.labels.filter { label in
            guard let port = SharingControl.ports[label] else { return false }
            return ports.contains(port)
        }
    }

    public func listeningPorts() -> Set<Int> {
        guard let result = try? runner.run("/usr/sbin/netstat", arguments: ["-an", "-p", "tcp"], timeout: 10),
              result.succeeded else {
            return []
        }
        return SharingControl.parseListeningPorts(result.stdout)
    }

    /// `netstat -an -p tcp` 的行长这样：
    /// `tcp46  0  0  *.445  *.*  LISTEN`
    /// `tcp4   0  0  127.0.0.1.631  *.*  LISTEN`
    public static func parseListeningPorts(_ text: String) -> Set<Int> {
        var ports: Set<Int> = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 6, fields[0].hasPrefix("tcp") else { continue }
            guard fields[5].uppercased() == "LISTEN" else { continue }
            let local = fields[3]
            guard let portText = local.split(separator: ".").last, let port = Int(portText) else { continue }
            ports.insert(port)
        }
        return ports
    }

    /// 只关当前真的在监听的；本来就没开的，一个字节都不碰。
    public func disableAll() async -> [FailedItem] {
        // 这一步要跑 netstat，放到后台去查，别卡主线程。
        let enabled = Set(await listeningLabels())
        var failures: [FailedItem] = []
        for label in SharingControl.labels where enabled.contains(label) {
            do {
                _ = try await executor.perform(.launchctlDisable, arguments: ["label": label])
            } catch {
                HKMLog.error(L("关闭共享服务 {0} 失败：{1}", label, error.localizedDescription))
                failures.append(FailedItem(title: "共享服务", error: error, severity: .optional))
                // 后台服务不可用时剩下的 label 只会同样失败，而且每次都要等超时。
                if PowerSettings.isHelperUnavailable(error) { return failures }
                continue
            }
            // bootout 对没在运行的服务必然报错，那属于正常情况，不算失败：
            // disable 已经保证它重启后不会自己回来。
            do {
                _ = try await executor.perform(.launchctlBootout, arguments: ["label": label])
            } catch {
                HKMLog.error(L("停止共享服务 {0} 失败（不影响睡眠）：{1}", label, error.localizedDescription))
            }
        }
        return failures
    }

    public func restore(_ labels: [String]) async -> [FailedItem] {
        var failures: [FailedItem] = []
        for label in labels {
            do {
                _ = try await executor.perform(.launchctlEnable, arguments: ["label": label])
                _ = try await executor.perform(.launchctlBootstrap, arguments: ["label": label])
            } catch {
                HKMLog.error(L("恢复共享服务 {0} 失败：{1}", label, error.localizedDescription))
                failures.append(FailedItem(title: "恢复共享服务", error: error, severity: .optional))
            }
        }
        return failures
    }
}
