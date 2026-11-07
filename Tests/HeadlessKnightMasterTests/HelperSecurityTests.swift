import Foundation
import Testing

@testable import HeadlessKnightMaster
@testable import HKMKit

/// 这些测试守的是「root 权限只用来做我们说好的那几件事」。
///
/// 背景：helper 的 socket 是 0666，只靠 uid 判断谁在问；同一个登录用户下任何
/// 进程都能连进来。所以边界必须在 root 进程里、而且必须能被测试守住。
@Suite("helper 的权限边界")
struct HelperPolicyTests {
    @Test("launchctl 白名单就是应用管理的三个共享服务")
    func labelWhitelistMatchesSharing() {
        #expect(Set(HelperPolicy.allowedLaunchctlLabels) == Set(SharingControl.labels))
        for label in SharingControl.labels {
            #expect(HelperPolicy.isAllowedLaunchctlLabel(label))
        }
    }

    @Test("任意 label 一律拒绝")
    func rejectsArbitraryLabels() {
        for label in [
            "com.apple.periodic",
            "com.apple.WindowServer",
            "com.headlessknight.helper",
            "",
            "com.apple.smbd.evil"
        ] {
            #expect(!HelperPolicy.isAllowedLaunchctlLabel(label))
        }
    }

    @Test("bootstrap 的 plist 路径只从白名单生成，挡掉路径穿越")
    func rejectsPathTraversal() {
        #expect(HelperPolicy.launchDaemonPlistPath(for: "com.apple.smbd")
            == "/System/Library/LaunchDaemons/com.apple.smbd.plist")
        // 这些字符串如果被拼进路径，launchd 就会以 root 去 bootstrap 一个
        // 用户可写的 plist —— 等于把 root 交出去。
        for evil in [
            "../../tmp/evil",
            "../../../../tmp/evil",
            "com.apple.smbd/../../../../tmp/evil",
            "/tmp/evil",
            "com.apple.smbd.plist"
        ] {
            #expect(HelperPolicy.launchDaemonPlistPath(for: evil) == nil)
        }
    }

    @Test("pmset 的键、电源类型、值都要过白名单")
    func pmsetArgumentsAreRestricted() {
        for key in PmsetSnapshot.trackedKeys {
            #expect(HelperPolicy.isAllowedPmsetKey(key))
        }
        #expect(!HelperPolicy.isAllowedPmsetKey("everything"))
        #expect(!HelperPolicy.isAllowedPmsetKey("sleep; rm -rf /"))

        #expect(HelperPolicy.isAllowedPmsetScope("a"))
        #expect(HelperPolicy.isAllowedPmsetScope("c"))
        #expect(HelperPolicy.isAllowedPmsetScope("b"))
        #expect(!HelperPolicy.isAllowedPmsetScope("d"))

        #expect(HelperPolicy.isAllowedPmsetValue("0"))
        #expect(HelperPolicy.isAllowedPmsetValue("1"))
        #expect(!HelperPolicy.isAllowedPmsetValue("0; reboot"))
        #expect(!HelperPolicy.isAllowedPmsetValue(""))
    }
}

@Suite("安装脚本的 shell 转义")
struct ShellQuoteTests {
    /// 真的交给 `/bin/sh` 跑一遍：转义错了这里就会多出一个文件。
    @Test("带命令替换的路径不会被 shell 执行")
    func survivesRealShell() throws {
        let marker = "/tmp/hkm-quote-test-\(UUID().uuidString)"
        let payload = "/tmp/$(touch \(marker))/`touch \(marker)`/a b; touch \(marker)\ntouch \(marker)"
        defer { try? FileManager.default.removeItem(atPath: marker) }

        let result = try ShellRunner().run(
            "/bin/sh",
            arguments: ["-c", "printf %s \(ShellQuote.quote(payload))"],
            timeout: 10
        )

        #expect(result.succeeded)
        #expect(result.stdout == payload)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test("单引号自己也转义得对")
    func escapesSingleQuotes() throws {
        let payload = "it's a 'quoted' path"
        let result = try ShellRunner().run(
            "/bin/sh",
            arguments: ["-c", "printf %s \(ShellQuote.quote(payload))"],
            timeout: 10
        )
        #expect(result.stdout == payload)
    }

    @Test("安装脚本里的 App 路径是单引号包着的，不是拼进正文的")
    func installScriptQuotesHelperPath() {
        let evil = "/tmp/$(touch /tmp/hkm-pwned)/Knight.app"
        let script = HelperInstaller.makeScript(helperPath: evil, uid: 501)

        // 原始形态（双引号或裸插）一个字都不许出现。
        #expect(!script.contains("cp \"\(evil)\""))
        #expect(!script.contains("cp \(evil)"))
        #expect(script.contains("cp \(ShellQuote.quote(evil)) \(ShellQuote.quote(HelperPaths.binaryPath))"))
        // 写 uid 的那行是数字，不是用户可控字符串。
        #expect(script.contains("echo \"501\" > \(ShellQuote.quote(HelperPaths.allowedUIDPath))"))
    }
}
