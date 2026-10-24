import Foundation

public protocol PrivilegedExecuting: Sendable {
    func perform(_ operation: HelperOperation, arguments: [String: String]) async throws -> HelperResponse
    /// Requirement (not just a convenience) so `perform(_:)` dispatches through
    /// `any PrivilegedExecuting`.
    func perform(_ operation: HelperOperation) async throws -> HelperResponse
}

public extension PrivilegedExecuting {
    func perform(_ operation: HelperOperation) async throws -> HelperResponse {
        try await perform(operation, arguments: [:])
    }
}

/// Real path: forward the request to the root daemon.
public struct HelperExecutor: PrivilegedExecuting {
    private let client: HelperClient

    public init(client: HelperClient = HelperClient()) {
        self.client = client
    }

    public func perform(_ operation: HelperOperation, arguments: [String: String] = [:]) async throws -> HelperResponse {
        let request = HelperRequest(operation: operation, arguments: arguments)
        // `send` 是同步的 unix socket 往返，连不上时要等满超时（交互路径 8 秒）。
        // 留在主线程上就是「点一下，鼠标卡住」。
        let client = self.client
        let response = try await offMainThrowing { try client.send(request) }
        guard response.ok else {
            throw HelperError.remote(response.errorMessage ?? "未知错误")
        }
        return response
    }
}

/// `HKM_DRY_RUN=1`: log the intent, report success, touch nothing.
public struct DryRunExecutor: PrivilegedExecuting {
    public init() {}

    public func perform(_ operation: HelperOperation, arguments: [String: String] = [:]) async throws -> HelperResponse {
        let argumentText = arguments.isEmpty
            ? ""
            : " " + arguments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        DryRun.log("helper \(operation.rawValue)\(argumentText)")
        let intValue = operation == .bluetoothReadPower ? 1 : nil
        return HelperResponse.success(id: UUID().uuidString, output: "[dry-run]", intValue: intValue)
    }
}

public enum PrivilegedExecutorFactory {
    /// 出门流程是交互式的：用户在等，卡 20 秒和失败没什么区别。
    /// 交互路径传一个更短的超时，后台任务用默认值。
    public static let interactiveTimeout: TimeInterval = 8

    public static func make(timeout: TimeInterval = 20) -> any PrivilegedExecuting {
        if DryRun.isEnabled {
            return DryRunExecutor()
        }
        return HelperExecutor(client: HelperClient(timeout: timeout))
    }
}
