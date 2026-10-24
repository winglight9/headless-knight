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
    func scan() throws -> BlockerScanResult
}

@MainActor
protocol ProcessKilling {
    func kill(_ blocker: SleepBlocker) async -> KillOutcome
}

@MainActor
protocol PowerControlling {
    func readSnapshot() throws -> PmsetSnapshot
    func scheduledWakes() -> [String]
    func applyAwaySettings(current: PmsetSnapshot?, cancelScheduledWakes: Bool) async -> [FailedItem]
    func restore(_ snapshot: PmsetSnapshot) async -> [FailedItem]
    func sleepNow() async throws
    /// `since` 之后系统有没有真的进入过睡眠。不验证就切到「外出中」等于骗人。
    func didEnterSleep(since: Date) async -> Bool
    /// 谁在拿 `PreventSystemSleep` 挡着——睡眠失败时要能说清楚是谁。
    func systemSleepBlockers() async -> [String]
}

@MainActor
protocol BluetoothControlling {
    func powerState() -> Int?
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
    func listeningLabels() -> [String]
    func disableAll() async -> [FailedItem]
    func restore(_ labels: [String]) async -> [FailedItem]
}

@MainActor
protocol TimeMachineControlling {
    func isEnabled() -> Bool?
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

@MainActor
protocol Notifying {
    func requestAuthorization()
    func post(title: String, body: String)
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
}

/// 强制睡眠前先确认没人在远程用这台机器。
@MainActor
protocol RemoteSessionChecking {
    func remoteLogins() -> [String]
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

    var isInstalled: Bool { client.isInstalled }

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

/// 倒计时节奏。测试里把 tick 调到很小，就不用真的等 20 秒。
struct Timing {
    /// 「这些程序在挡睡眠」到「自动退出它们」之间留多久。
    ///
    /// 10 秒不够：用户得先看清是哪个程序、挡了什么，再决定是自己关还是让软件关。
    /// 20 秒刚好够读完两三条理由，又不至于让人对着一个不动的界面等。
    var detectCountdownSeconds: Int = 20
    var countdownTick: Double = 1.0
    /// 请求睡眠后等多久再读日志确认。机器真睡了的话这段时间是在挂起中过去的。
    var sleepVerifySeconds: Double = 4.0
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
