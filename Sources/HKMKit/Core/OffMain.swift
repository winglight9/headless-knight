import Foundation

/// 把同步的阻塞调用挪到后台线程。
///
/// 菜单栏软件只有一条主线程：主线程一卡，鼠标指针就跟着卡。而这些读取全都是
/// 同步子进程 —— `system_profiler`（蓝牙，0.5～2.5 秒）、`pmset -g assertions`
/// 加每个进程一次 `ps`（0.3～1 秒）、`netstat`、`tmutil`、以及走 unix socket
/// 的后台服务调用。它们留在主线程上，用户看到的就是「自动关闭的时候鼠标是卡的」。
///
/// 这些类型（`PowerSettings`、`AssertionScanner`…）都是 `Sendable` 的值类型，
/// 内部没有任何主线程状态，放到别的线程上跑是安全的。
public func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: work())
        }
    }
}

public func offMainThrowing<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                continuation.resume(returning: try work())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
