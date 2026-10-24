import Foundation

public enum HKMError: Error, LocalizedError, Sendable, Equatable {
    case commandFailed(executable: String, status: Int32, message: String)
    case permissionDenied(String)
    case unavailable(String)
    case parseFailure(String)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(executable, status, message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(executable) 执行失败（\(status)）：\(trimmed)"
        case let .permissionDenied(message):
            return "没有权限：\(message)"
        case let .unavailable(message):
            return "不可用：\(message)"
        case let .parseFailure(message):
            return "解析失败：\(message)"
        }
    }
}
