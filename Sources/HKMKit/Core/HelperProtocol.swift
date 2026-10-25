import Foundation

/// 后台服务的协议版本。**改了 helper 的参数或协议就 +1。**
///
/// 用版本握手判断「装的是不是这一版」，而不是比对二进制内容：安装脚本里
/// `codesign --force --sign -` 会给复制过去的那份重新签名，文件直接大 18KB，
/// 字节比对永远不相等——2026-10-25 用户装一次、报一次「旧版本」，反复卡在这里。
///
/// 历史：1 = 最初的版本；2 = `pmsetSet` 支持 `scope`（按电源类型分开写）。
public enum HelperProtocol {
    public static let apiVersion = 2
}

public enum HelperOperation: String, Codable, Sendable, CaseIterable {
    case ping
    case pmsetSet
    case pmsetSleepNow
    case pmsetScheduleCancelAll
    case timeMachineDisable
    case timeMachineEnable
    case launchctlDisable
    case launchctlEnable
    case launchctlBootout
    case launchctlBootstrap
    case bluetoothSetPower
    case bluetoothReadPower
}

public struct HelperRequest: Codable, Sendable, Equatable {
    public var id: String
    public var operation: HelperOperation
    public var arguments: [String: String]

    public init(id: String = UUID().uuidString, operation: HelperOperation, arguments: [String: String] = [:]) {
        self.id = id
        self.operation = operation
        self.arguments = arguments
    }
}

public struct HelperResponse: Codable, Sendable, Equatable {
    public var id: String
    public var ok: Bool
    public var output: String
    public var errorMessage: String?
    public var intValue: Int?

    public init(id: String, ok: Bool, output: String = "", errorMessage: String? = nil, intValue: Int? = nil) {
        self.id = id
        self.ok = ok
        self.output = output
        self.errorMessage = errorMessage
        self.intValue = intValue
    }

    public static func success(id: String, output: String = "", intValue: Int? = nil) -> HelperResponse {
        HelperResponse(id: id, ok: true, output: output, intValue: intValue)
    }

    public static func failure(id: String, message: String) -> HelperResponse {
        HelperResponse(id: id, ok: false, errorMessage: message)
    }
}

public enum HelperPaths {
    public static let label = "com.headlessknight.helper"
    public static let socketPath = "/var/run/com.headlessknight.sock"
    public static let binaryPath = "/Library/PrivilegedHelperTools/com.headlessknight.helper"
    public static let plistPath = "/Library/LaunchDaemons/com.headlessknight.helper.plist"
    public static let allowedUIDPath = "/Library/Application Support/HeadlessKnightMaster/allowed-uid"
}

public enum HelperError: Error, LocalizedError, Sendable, Equatable {
    case notInstalled
    case connectionFailed(String)
    case protocolViolation(String)
    case remote(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "后台服务没有安装，改系统设置需要它"
        case let .connectionFailed(message):
            return "连不上后台服务：\(message)"
        case let .protocolViolation(message):
            return "后台服务返回了无法解析的数据：\(message)"
        case let .remote(message):
            return "后台服务执行失败：\(message)"
        case .timeout:
            return "后台服务响应超时"
        }
    }
}
