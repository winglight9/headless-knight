import Foundation

/// `~/Library/LaunchAgents` based login item. No SMAppService (needs a bundle id
/// registered with the system and full Xcode tooling to be reliable).
public struct LaunchAtLogin: Sendable {
    public static let label = "com.headlessknight.app"

    private let home: URL
    private let runner: any CommandRunning

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()), runner: any CommandRunning = ShellRunner()) {
        self.home = home
        self.runner = runner
    }

    public var plistURL: URL {
        home.appendingPathComponent("Library/LaunchAgents/\(LaunchAtLogin.label).plist")
    }

    public func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// 只写 plist 文件，**不碰** launchd。
    ///
    /// 以前这里还做了 `launchctl bootout` + `bootstrap`。`bootstrap` 会**当场
    /// 把 agent 加载起来**，而它 `RunAtLoad` 为真——于是第二个实例立刻被拉起，
    /// 菜单栏出现两个图标（用户报的就是这个）。`bootout` 又反着来：如果当前这个
    /// 进程本来就是登录时由该 agent 拉起的，bootout 会把自己杀掉。
    ///
    /// `~/Library/LaunchAgents` 里的 plist 在**每次登录时由 launchd 自动加载**，
    /// 这正是「开机自启」的定义，根本不需要手动 bootstrap。
    public func enable(executablePath: String) throws {
        if DryRun.isEnabled {
            DryRun.log("不会真的写入自启动项 \(plistURL.path)")
            return
        }
        try writePlist(executablePath: executablePath)
        HKMLog.info("已写入自启动项：\(plistURL.path) → \(executablePath)（下次登录生效）")
    }

    /// 只把 plist 里的路径改对，**不碰** launchd 里的 job。
    ///
    /// 换过名字或目录之后，旧路径就失效了，下次登录再也起不来。路径改对就行，
    /// 下一次登录自然生效。
    public func rewriteIfNeeded(executablePath: String) {
        guard isEnabled(), !DryRun.isEnabled else { return }
        guard let current = try? String(contentsOf: plistURL, encoding: .utf8) else { return }
        guard !current.contains(executablePath) else { return }
        try? writePlist(executablePath: executablePath)
        HKMLog.info("自启动项里的路径过期了，已改成 \(executablePath)")
    }

    private func writePlist(executablePath: String) throws {
        let directory = plistURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(LaunchAtLogin.label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>
        """
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
    }

    /// 只删 plist，同样不碰 launchd。
    ///
    /// `bootout` 在这里是有害的：如果这个进程就是登录时被该 agent 拉起来的，
    /// 关掉「开机自启」这个动作会**顺手把软件自己关掉**。删掉文件就够了——下次
    /// 登录 launchd 找不到它，自然不会再启动。
    public func disable() throws {
        if DryRun.isEnabled {
            DryRun.log("不会真的移除自启动项 \(plistURL.path)")
            return
        }
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
        HKMLog.info("已移除自启动项（下次登录不再自动启动）")
    }
}
