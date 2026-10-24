import Foundation
import Testing
@testable import HKMKit

/// 主线程不许被同步子进程堵住。
///
/// 这是用户真机上量到的那件事：点「一键关闭」之后鼠标会卡一下。根因是
/// `system_profiler`（0.5–2.5 秒）、`pmset -g assertions` 加每个进程一次 `ps`、
/// 以及后台服务的 unix socket 往返，全都跑在主线程上——主线程一停，整个界面
/// 包括鼠标指针就跟着停。
///
/// 现在这些调用都挪到了 `offMain` 里。这个测试用「心跳间隔」来验证：主线程上
/// 每 20 毫秒打一次点，同时去做最重的那几个查询；只要中间有超过 400 毫秒的
/// 空档，就说明又有人在主线程上阻塞了。
///
/// 阈值给得比较松（同步版本要 0.5–2.5 秒才会回来，差一个数量级），是为了不在
/// 忙的机器上误报。
@Suite(.serialized)
struct MainThreadResponsivenessTests {
    /// 主线程心跳：返回期间观察到的最大空档。
    @MainActor
    private final class Heartbeat {
        private(set) var maxGap: TimeInterval = 0
        private var last = Date()
        private var running = true

        func start() {
            last = Date()
            Task { @MainActor in
                while self.running {
                    let now = Date()
                    self.maxGap = max(self.maxGap, now.timeIntervalSince(self.last))
                    self.last = now
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            }
        }

        func stop() {
            running = false
        }
    }

    @Test("扫描断言时主线程保持可响应")
    @MainActor
    func scanKeepsMainThreadFree() async {
        let heartbeat = Heartbeat()
        heartbeat.start()

        let scanner = AssertionScanner()
        for _ in 0 ..< 2 {
            _ = try? await scanner.scan()
        }

        heartbeat.stop()
        #expect(heartbeat.maxGap < 0.4, "主线程被堵了 \(heartbeat.maxGap) 秒")
    }

    @Test("读 pmset 快照时主线程保持可响应")
    @MainActor
    func powerSnapshotKeepsMainThreadFree() async {
        let heartbeat = Heartbeat()
        heartbeat.start()

        let power = PowerSettings()
        for _ in 0 ..< 2 {
            _ = try? await power.readSnapshotAsync()
        }

        heartbeat.stop()
        #expect(heartbeat.maxGap < 0.4, "主线程被堵了 \(heartbeat.maxGap) 秒")
    }
}
