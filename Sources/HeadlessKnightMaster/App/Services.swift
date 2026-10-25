import AppKit
import Foundation
import HKMKit

// MARK: - 依赖协议
//
// AppState 之前把流程逻辑和真实的 ProcessKiller / PowerSettings / HelperClient
// 绑死，导致「测试全绿但真机跑不通」。这里把每个外部能力都抽成协议，测试和
// `--simulate-away` 才能驱动完整状态机。

@MainActor
protocol ProcessScanning {
    /// 必须 async：`pmset -g assertions` 加每个进程一次 `ps`，几百毫秒起。
    /// 同步版本会把主线程卡住，用户看到的就是「鼠标一顿一顿的」。
    func scan() async throws -> BlockerScanResult
}

@MainActor
protocol ProcessKilling {
    func kill(_ blocker: SleepBlocker) async -> KillOutcome
}

@MainActor
protocol PowerControlling {
    func readSnapshot() throws -> PmsetSnapshot
    /// 出门流程里读快照用这个：主线程上读一次要卡一两百毫秒。
    func readSnapshotAsync() async throws -> PmsetSnapshot
    func scheduledWakes() -> [String]
    func applyAwaySettings(current: PmsetSnapshot?, cancelScheduledWakes: Bool) async -> [FailedItem]
    func restore(_ snapshot: PmsetSnapshot) async -> [FailedItem]
    func sleepNow() async throws
    /// `since` 之后系统有没有真的进入过睡眠。不验证就切到「外出中」等于骗人。
    /// 读不到证据要返回 `.unknown`，不许当成「没睡」。
    func sleepEvidence(since: Date) async -> PowerSettings.SleepEvidence
    /// 谁在拿 `PreventSystemSleep` 挡着——睡眠失败时要能说清楚是谁。
    func systemSleepBlockers() async -> [String]
}

@MainActor
protocol BluetoothControlling {
    func powerState() async -> Int?
    /// 返回失败原因，nil 表示成功。
    func setPower(_ on: Bool) async -> String?
}

@MainActor
protocol BatteryReading {
    func percentage() -> Int?
}

@MainActor
protocol SharingControlling {
    /// 真的在监听端口的服务。判断「开着没有」看它，不看 launchctl 的开关记录。
    func listeningLabels() async -> [String]
    func disableAll() async -> [FailedItem]
    func restore(_ labels: [String]) async -> [FailedItem]
}

@MainActor
protocol TimeMachineControlling {
    func isEnabled() async -> Bool?
    func disable() async -> TimeMachineControl.PauseOutcome
    func enable() async -> FailedItem?
}

@MainActor
protocol DisplayWatching {
    func setHandler(_ handler: (@MainActor @Sendable (Int) -> Void)?)
    func start()
    func stop()
    func activeDisplayCount() -> Int
    /// 还插着的显示器 ID。拔没拔看这个，不要看数量。
    func onlineDisplayIDs() -> [CGDirectDisplayID]
    /// 主显示器 ID。拔掉唯一那块屏之后它会换人。
    func mainDisplayID() -> CGDirectDisplayID
    /// 内建屏是不是亮着（笔记本 = 盖子开着 = 人在电脑前）。
    func builtinOnline() -> Bool
    /// 给日志用：每块屏的 ID / 内建 / 活动 / 厂商型号。
    func describeDisplays() -> String
    /// 每块屏的 ID + 厂商/型号/序列号。用来认出「拔线后系统留下的影子屏」——
    /// 影子屏有时会沿用原来那个 ID，只靠 ID 是认不出来的。
    func displaySnapshots() -> [DisplayWatcher.DisplaySnapshot]
}

@MainActor
protocol StateStoring {
    func loadState() -> SessionState?
    func saveState(_ state: SessionState) throws
    func clearState() throws
    func loadSettings() -> AppSettings
    func saveSettings(_ settings: AppSettings) throws
    func lastReport() -> Report?
    func appendReport(_ report: Report) throws
    /// 恢复失败要能补进已经生成的那份报告里。
    func updateLastReport(_ report: Report) throws
}

/// 一条测试通知到底怎么了。
///
/// 之所以要分这么细：`UNUserNotificationCenter.add` 只在「请求都没交出去」时报错。
/// 没授权、专注模式、通知样式设成「无」，它全都安静地成功。设置页说「已发送」
/// 而屏幕上一片空白，就是这么来的。
public enum NotificationTestResult: Sendable, Equatable {
    /// 前台横幅真的出现了（走的是 `willPresent`）。
    case shown
    /// 系统收下并投递了，但我们没有经手——app 不在最前台时系统自己弹。
    /// 实测这种情况下横幅一样会出来，所以措辞是「已发出」，不是「没弹」。
    case delivered
    /// 系统收下了，但通知中心里也找不到——被彻底挡掉（多半是专注模式）。
    case suppressed
    /// 用户没给权限，连问都没得问。
    case notAuthorized
    case failed(String)

    /// 设置页那一行状态。不堆小字，一句说完。
    public var summary: String {
        switch self {
        case .shown: "已弹出 · 就在右上角"
        case .delivered: "已发出 · 看右上角"
        case .suppressed: "被系统挡掉了 · 看专注模式"
        case .notAuthorized: "没给通知权限 · 去系统设置里打开"
        case .failed(let reason): "发不出去：\(reason)"
        }
    }
}

@MainActor
protocol Notifying {
    func requestAuthorization()
    func post(title: String, body: String)
    /// 发一条测试通知，并如实回答「用户到底有没有机会看到」。
    func sendTest(title: String, body: String) async -> NotificationTestResult
    /// 通知能不能真的弹出来。设置页要如实显示，不能只说「已授权」。
    func authorizationSummary() async -> String
}

@MainActor
protocol LoginItemManaging {
    func isEnabled() -> Bool
    func enable(executablePath: String) throws
    func disable() throws
    /// 换名字/换目录之后把自启动项里的路径改对（不重启 job，否则会杀掉自己）。
    func rewriteIfNeeded(executablePath: String)
}

@MainActor
protocol PowerLogReading {
    func readPowerLog() async -> String
}

@MainActor
protocol HelperManaging {
    var isInstalled: Bool { get }
    func install() throws
    /// 等后台服务真的能接受连接。安装完、App 刚启动时都要用。
    @discardableResult
    func waitUntilReady(timeout: TimeInterval) -> Bool
}

extension HelperManaging {
    @discardableResult
    func waitUntilReady(timeout: TimeInterval = 6) -> Bool { true }
}

/// 强制睡眠前先确认没人在远程用这台机器。
@MainActor
protocol RemoteSessionChecking {
    func remoteLogins() async -> [String]
}

@MainActor
protocol SystemClock {
    var now: Date { get }
    func bootTime() -> TimeInterval
}

// MARK: - 真实实现的适配

extension AssertionScanner: ProcessScanning {}
extension ProcessKiller: ProcessKilling {}
extension PowerSettings: PowerControlling {}
extension BluetoothControl: BluetoothControlling {}
extension BatteryReader: BatteryReading {}
extension SharingControl: SharingControlling {}
extension TimeMachineControl: TimeMachineControlling {}
extension SessionStore: StateStoring {}
extension Notifier: Notifying {}
extension LaunchAtLogin: LoginItemManaging {}
extension RemoteSessionProbe: RemoteSessionChecking {}

extension DisplayWatcher: DisplayWatching {
    func activeDisplayCount() -> Int {
        DisplayWatcher.activeDisplayCount()
    }

    func onlineDisplayIDs() -> [CGDirectDisplayID] {
        DisplayWatcher.onlineDisplayIDs()
    }

    func mainDisplayID() -> CGDirectDisplayID {
        DisplayWatcher.mainDisplayID()
    }

    func builtinOnline() -> Bool {
        DisplayWatcher.builtinOnline()
    }

    func describeDisplays() -> String {
        DisplayWatcher.describeDisplays()
    }

    func displaySnapshots() -> [DisplayWatcher.DisplaySnapshot] {
        DisplayWatcher.snapshots()
    }
}

/// `pmset -g log` 读起来很慢，放到后台线程，别卡住主线程。
struct SystemPowerLogReader: PowerLogReading {
    func readPowerLog() async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = try? ShellRunner().run("/usr/bin/pmset", arguments: ["-g", "log"], timeout: 30)
                continuation.resume(returning: result?.stdout ?? "")
            }
        }
    }
}

struct SystemClockReader: SystemClock {
    var now: Date { Date() }
    func bootTime() -> TimeInterval { SystemInfo.bootTime() }
}

struct SystemHelperManager: HelperManaging {
    private let client = HelperClient()

    /// 「装了」不够，还得**能连上、而且是这一版**。
    ///
    /// 连不上也算没装：文件在但服务挂了，用户需要的正是「装一次」这个入口。
    /// 以前连不上时宽松返回 true，结果服务明明不可用，界面却连安装按钮都不给。
    /// （App 刚启动、服务还在起的情况，由 `bootstrap` 先等一下再判断。）
    ///
    /// 版本用协议握手，不比二进制：安装脚本会重新签名，字节永远对不上。
    var isInstalled: Bool {
        client.isReady()
    }

    @discardableResult
    func waitUntilReady(timeout: TimeInterval = 6) -> Bool {
        client.waitUntilReachable(timeout: timeout)
    }

    func install() throws {
        try HelperInstaller.install()
    }
}

// MARK: - 依赖容器

struct AppDependencies {
    var scanner: any ProcessScanning
    var killer: any ProcessKilling
    var power: any PowerControlling
    var bluetooth: any BluetoothControlling
    var battery: any BatteryReading
    var sharing: any SharingControlling
    var timeMachine: any TimeMachineControlling
    var displays: any DisplayWatching
    var store: any StateStoring
    var notifier: any Notifying
    var loginItem: any LoginItemManaging
    var powerLog: any PowerLogReading
    var helper: any HelperManaging
    var remote: any RemoteSessionChecking
    var clock: any SystemClock
    var auditor: WakeAuditor

    @MainActor
    static func live() -> AppDependencies {
        // 出门流程里的每一次 root 操作都在用户眼皮底下，用更短的超时：
        // 后台服务真挂了就该快点说出来，而不是让界面转 20 秒。
        let executor = PrivilegedExecutorFactory.make(timeout: PrivilegedExecutorFactory.interactiveTimeout)
        return AppDependencies(
            scanner: AssertionScanner(),
            killer: ProcessKiller(),
            power: PowerSettings(executor: executor),
            bluetooth: BluetoothControl(),
            battery: BatteryReader(),
            sharing: SharingControl(executor: executor),
            timeMachine: TimeMachineControl(executor: executor),
            displays: DisplayWatcher(),
            store: SessionStore(),
            notifier: Notifier(),
            loginItem: LaunchAtLogin(),
            powerLog: SystemPowerLogReader(),
            helper: SystemHelperManager(),
            remote: RemoteSessionProbe(),
            clock: SystemClockReader(),
            auditor: WakeAuditor()
        )
    }
}

/// 倒计时节奏。测试里把 tick 调到很小，就不用真的等。
struct Timing {
    var countdownTick: Double = 1.0
    /// 检测页上重扫「挡睡眠的程序还在不在」的间隔。
    ///
    /// 这一页不再让用户回来点「我关好了」，所以得自己盯着。1.5 秒是权衡：
    /// 再快就是无意义的 `pmset -g assertions` 空转，再慢用户会以为它没反应。
    var detectPollSeconds: Double = 1.5
    /// 请求睡眠后等多久再读日志确认。机器真睡了的话这段时间是在挂起中过去的。
    ///
    /// 10 秒不是随便定的：`pmset sleepnow` 到真正「Entering Sleep」通常要四五秒
    /// （2026-10-25 10:47 那次是 5 秒）。以前是 4 秒——窗口在机器睡下去之前就关了，
    /// 于是判「没睡」，可紧接着机器就睡了。
    /// 等待窗口拉长在成功这一侧是零成本：真睡了的话进程是冻结着过去的，醒来
    /// 一看时钟跳了几分钟，立刻就知道；只有真的没睡才会实打实等满这 10 秒。
    var sleepVerifySeconds: Double = 10.0
    /// 「可以拔线了」这一页的兜底轮询间隔。事件回调会漏，轮询不会。
    var unplugPollSeconds: Double = 1.0
    /// 睡眠失败后后台重试的间隔。
    var sleepRetrySeconds: Double = 15.0

    // MARK: - 强力模式

    /// 外出期间机器**连续醒着**多久之后强制它再睡一次。
    ///
    /// 10 分钟不是随便定的：外出时 `pmset sleep` 已经被设成 1 分钟，所以机器只要
    /// 安静下来一分钟就会自己睡回去。还能醒着 10 分钟，说明有东西在持续按住它
    /// （包里鼠标抖动、某个程序抓着 PreventUserIdleSystemSleep、远程会话）。
    /// 反过来，间隔再短没有收益，只会放大「误判就打断用户」的概率。
    var strongModeIntervalSeconds: Double = 600
    /// 强制睡眠前的倒计时。通知发出后这么久才动手，给人留出取消的时间。
    var strongModeCountdownSeconds: Int = 30
    /// 强力模式的检查间隔。也是「怎么发现机器睡过一觉」的粒度。
    var strongModeTickSeconds: Double = 5
    /// 两次检查之间隔了这么久，说明进程被挂起过（机器真的睡了），醒着时长清零。
    var sleepGapSeconds: Double = 60

    /// 预读的 `pmset -g log` 能用多久。这段时间里点「结束外出」就不用再等它。
    var powerLogCacheSeconds: Double = 1800

    static let real = Timing()
}
