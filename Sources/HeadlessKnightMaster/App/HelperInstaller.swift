import AppKit
import Foundation
import HKMKit

enum HelperInstaller {
    enum InstallError: LocalizedError {
        case missingBundledHelper
        case authorizationFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingBundledHelper:
                return "安装包里缺少后台服务二进制"
            case let .authorizationFailed(message):
                return "授权失败：\(message)"
            }
        }
    }

    static func install() throws {
        guard let bundled = Bundle.main.url(forResource: "com.headlessknight.helper", withExtension: nil) else {
            throw InstallError.missingBundledHelper
        }
        if DryRun.isEnabled {
            DryRun.log("不会真的安装后台服务（\(bundled.path)）")
            return
        }

        let script = makeScript(helperPath: bundled.path, uid: getuid())
        let encoded = Data(script.utf8).base64EncodedString()
        // Base64 avoids every quoting trap of nesting shell inside AppleScript.
        let appleScript = "do shell script \"echo \(encoded) | /usr/bin/base64 -D | /bin/sh\" with administrator privileges"
        let result = try ShellRunner().run("/usr/bin/osascript", arguments: ["-e", appleScript], timeout: 120)
        guard result.succeeded else {
            throw InstallError.authorizationFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        HKMLog.info("后台服务安装完成")
    }

    private static func makeScript(helperPath: String, uid: uid_t) -> String {
        """
        set -e
        mkdir -p /Library/PrivilegedHelperTools
        cp "\(helperPath)" "\(HelperPaths.binaryPath)"
        chown root:wheel "\(HelperPaths.binaryPath)"
        chmod 755 "\(HelperPaths.binaryPath)"
        codesign --force --sign - "\(HelperPaths.binaryPath)" >/dev/null 2>&1 || true
        mkdir -p "/Library/Application Support/HeadlessKnightMaster"
        echo "\(uid)" > "\(HelperPaths.allowedUIDPath)"
        chmod 644 "\(HelperPaths.allowedUIDPath)"
        cat > "\(HelperPaths.plistPath)" <<'HKMPLIST'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(HelperPaths.label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(HelperPaths.binaryPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ProcessType</key>
            <string>Background</string>
        </dict>
        </plist>
        HKMPLIST
        chown root:wheel "\(HelperPaths.plistPath)"
        chmod 644 "\(HelperPaths.plistPath)"
        launchctl bootout system/\(HelperPaths.label) >/dev/null 2>&1 || true
        launchctl enable system/\(HelperPaths.label)
        launchctl bootstrap system "\(HelperPaths.plistPath)"
        """
    }
}
