import AppKit
import Combine
import Foundation
import HKMKit

/// Owns the whole away-mode transaction and everything the popover renders.
///
/// 所有外部能力都通过 `AppDependencies` 注入，流程本身不直接碰 `pmset`、
/// `NSRunningApplication` 或 socket —— 这样测试和 `--simulate-away` 才能把
/// 完整状态机跑一遍，而不是只测纯函数。
@MainActor
public final class AppState: ObservableObject {
    public enum Screen: Equatable {
        case onboarding(Int)
        case home
        /// 正在扫「谁在挡睡眠」。`pmset -g assertions` 要几百毫秒，不能同步等。
        case scanning
        case detecting
        /// 正在自动关闭。这一页会一直显示到最后一步，用户能看见进度。
        case closing
        case blocked
        case readyToUnplug
        case away
        case auditing
        case report
        case settings
    }

    /// 检测页上的两种选择。
    ///
    /// 以前这里是一个 20 秒倒计时：数完就自己动手。用户的原话是「20 秒还是有点
    /// 吓人」——一个会自己动手关掉你程序的界面，等多久都吓人。现在改成必须点：
    /// 一键全关，或者自己关。
    public enum IconState: Equatable {
        case home
        case away
        case alert
    }

    /// 「叫它睡」这件事的真实结果。
    ///
    /// 以前没有这个状态：只要 `pmset sleepnow` 没抛异常就直接切到「外出中」，
    /// 界面再硬编码一句「系统已进入睡眠」。可 `pmset sleepnow` 在没有权限、或者
    /// 被 `PreventSystemSleep` 断言挡住时不会报错——它只是什么都不做。于是用户
    /// 拔了线、等半天、键盘灯一直亮着，软件还在说「已进入睡眠」。
    public enum SleepOutcome: Equatable {
        case idle
        case requesting
        case slept
        case failed(reason: String)
        /// 叫了睡，但拿不到证据（读不到电源日志、也没有时钟跳变的旁证）。
        ///
        /// 这一档必须和 `failed` 分开：`failed` 是「确认还醒着」，可以理直气壮地
        /// 提醒用户；`unverified` 是「不知道」，拿它去弹「没能进入睡眠」就是在
        /// 冤枉一台已经睡了一整夜的机器。
        case unverified(reason: String)
    }

    // MARK: - Published state

    @Published public private(set) var screen: Screen = .home
    @Published public private(set) var iconState: IconState = .home
    @Published public private(set) var blockers: [SleepBlocker] = []
    @Published public private(set) var systemBlockerCount: Int = 0
    /// 只挡屏幕、挡不住睡眠的那批。页面上单独说一句「不会动它们」。
    @Published public private(set) var displayOnlyCount: Int = 0
    @Published public private(set) var countdown: Int = 0
    @Published public private(set) var countdownTotal: Int = 0
    /// 正在自动关闭时的当前一步。关完变 nil。
    @Published public private(set) var closingStep: String?
    @Published public private(set) var unplugCountdown: Int?
    @Published public private(set) var failedItems: [FailedItem] = []
    /// 这一趟蓝牙到底怎么了。
    ///
    /// 以前 `AwayView` 是在 `completedActions` 里找「关闭了蓝牙」这句中文来判断的——
    /// 文案一进英文表就再也匹配不上，状态行会凭空少半句。状态就该是枚举。
    public enum BluetoothOutcome: Sendable {
        case untouched
        case turnedOff
        case alreadyOff
    }

    @Published public private(set) var bluetoothOutcome: BluetoothOutcome = .untouched
    @Published public private(set) var completedActions: [String] = []
    /// 「关闭程序」那条在清单里的位置。
    ///
    /// 以前靠 `hasPrefix("关闭了") && hasSuffix("个程序")` 去找它——文案一进英文表，
    /// 这个判断就永远匹配不上，于是同一件事在清单里出现两行。位置记下来最稳。
    private var killSummaryIndex: Int?
    /// 「关闭了蓝牙」是不是已经记过了。同样不能用文案当身份。
    private var bluetoothMarkedDone = false
    @Published public private(set) var killedCount: Int = 0
    @Published public private(set) var session: SessionState?
    @Published public private(set) var report: Report?
    @Published public private(set) var settings: AppSettings = .default
    @Published public private(set) var lastReport: Report?
    @Published public private(set) var helperInstalled: Bool = false
    @Published public private(set) var isBusy: Bool = false
    @Published public private(set) var displayCount: Int = 0
    /// 「你让我拔的那块屏，现在还在不在」。这才是判断依据。
    @Published public private(set) var displaysDetached: Bool = false
    @Published public private(set) var batteryNow: Int?
    @Published public private(set) var now: Date = Date()
    @Published public private(set) var showDetail: Bool = false
    @Published public private(set) var showAuthorizationReason: Bool = false
    @Published public private(set) var bluetoothWasOn: Bool = true
    /// 后台服务没装：阻塞页要给出「安装」按钮，而不是让用户对着「操作失败」发呆。
    @Published public private(set) var needsHelperInstall: Bool = false
    /// 上次「恢复原样」没恢复完。状态文件必须留着，否则下次外出拍到的快照就是
    /// 已经被改过的值，从此永远恢复不回来。
    @Published public private(set) var pendingRestore: Bool = false
    @Published public private(set) var sleepOutcome: SleepOutcome = .idle
    /// `pmset -g` 里的 SleepDisabled。首页那句「系统可以正常睡眠」必须基于它，
    /// 而不是想当然。
    @Published public private(set) var sleepDisabled: Bool = false
    /// 增强模式：外出期间机器已经连续醒着多少秒。真睡过去一次就归零。
    @Published public private(set) var awakeSeconds: Int = 0
    /// 设置页里如实显示的通知状态。
    @Published public private(set) var notificationStatus: String = "…"
    /// 「防止空闲睡眠」此刻是不是真的拿在手里。
    ///
    /// 设置里勾着不等于拿到了：断言可能被系统拒绝。设置页要照这个说话。
    @Published public private(set) var idleSleepHeld = false
    /// 上一次想拿却被系统拒绝的原因。拿着、或者是我们主动放开的，都是 nil。
    @Published public private(set) var idleSleepFailure: String?
    /// 内建屏此刻的真实状态。同样，开关勾着不等于屏断了。
    @Published public private(set) var builtinCutState: BuiltinCutState = .unknown

    /// 内建屏到底断没断。开关是「我想要」，这个是「现在是什么」。
    public enum BuiltinCutState: Equatable, Sendable {
        case unknown
        case disconnected
        case connected
        /// 这台系统上私有接口不可用，做不到。
        case unsupported
        case failed(String)

        /// 设置页那一行的小字。说人话，不解释实现。
        public var summary: String {
            switch self {
            case .unknown: return L("正在检查")
            case .disconnected: return L("内建屏已断开")
            case .connected: return L("内建屏接着")
            case .unsupported: return L("这个系统版本断不了")
            case let .failed(reason): return L("没断开：{0}", reason)
            }
        }
    }

    public var errorMessage: String?

    // MARK: - Dependencies

    private let deps: AppDependencies
    private let timing: Timing

    /// 模拟模式用它把每一步打到终端；正常运行时为 nil。
    var narrator: ((String) -> Void)?

    /// 真正的「退出进程」动作。测试里换成记录用的替身，否则会把测试进程杀掉。
    var terminateApplication: @MainActor () -> Void = { NSApp.terminate(nil) }

    private var countdownTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    /// 检测页上盯着「挡睡眠的程序还在不在」。用户自己去关也行，关干净了自动往下走。
    private var blockerWatchTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var flowTask: Task<Void, Never>?
    private var unplugPollTask: Task<Void, Never>?
    private var sleepRetryTask: Task<Void, Never>?
    /// 「防止空闲睡眠」的看守。见 `startIdleSleepGuard()`。
    private var idleSleepGuardTask: Task<Void, Never>?
    /// 系统明确拒绝过之后，下次再撞门的时间。没拒绝过就是 nil。
    private var idleSleepNextRetryAt: Date?
    /// 「内建屏又被系统装回来了，再摘一次」。同一时刻只跑一个。
    private var maintainCutTask: Task<Void, Never>?
    /// 从哪一页点开设置的。关掉设置要回到那一页，而不是按 phase 猜。
    private var screenBeforeSettings: Screen?
    /// 进「可以拔线了」那一刻还插着的显示器 ID。
    ///
    /// 判断「拔了没有」只能看这个集合，不能看数量：2026-10-24 09:41 实测，
    /// 显示器拔掉之后 `CGGetActiveDisplayList` 仍然返回 1（系统留了一块影子屏），
    /// 于是「数量变 0」这个条件永远不会成立，流程永远走不到睡觉那一步。
    ///
    /// 按 ID 判断对任何机器都成立：
    ///   · Mac mini / Studio：唯一外接屏消失 → 集合变空
    ///   · MacBook + 外接屏：外接屏消失，内建屏还在 → 基线里少了一块
    ///   · 无头 MacBook：外接屏消失，冒出一块影子屏 → 基线里那块不见了
    /// 显示器只是休眠（DPMS）时仍然算 online，所以不会误判。
    private var baselineDisplayIDs: [CGDirectDisplayID] = []
    /// 测试用：基线到底记成了什么。真机上靠日志看，测试里靠它。
    var baselineDisplayIDsForTesting: [CGDirectDisplayID] { baselineDisplayIDs }
    /// 进拔线页的时刻。基线一直空着时，用它来算「等了多久」。
    private var readyPageEnteredAt: Date?
    /// 基线空着多久之后，才允许拿「眼前没有一块真外接屏」当拔线判据。
    ///
    /// 45 秒是有来历的：2026-11-03 12:40 关掉 MacHead 之后，显示器拓扑抖了
    /// 将近 20 秒（外接屏 12:40:07 消失、12:40:28 才回来）。那阵子要是判成
    /// 「已经拔线」，软件会在用户还在收拾东西的时候把机器睡掉。
    private static let emptyBaselineGraceSeconds: TimeInterval = 45
    private var countdownPurpose: CountdownPurpose = .none
    private var didNotifyReturn = false
    private var didMarkDetached = false
    /// 睡眠失败后，必须先把显示器插回来再拔，才允许重新自动倒计时——
    /// 否则用户看着「没睡成」的提示，后台已经在无限重试。
    private var awaitingDisplayReturnForRetry = false
    /// 这一趟里「没能进入睡眠」只弹一次。以前每失败一轮就弹一条，一夜攒了七条，
    /// 用户早上开屏看到的第一条就是它。
    private var didPostSleepFailure = false
    /// 进程被挂起多久才算「机器真的睡了」。
    ///
    /// 请求睡眠之后那段等待，如果机器睡了，进程是冻结着过去的，醒来时墙上时钟
    /// 早就跳过去了。跳了超过这个数就不必再看任何日志——这是最硬的证据，
    /// 而且不依赖 `pmset -g log` 能不能读出来。
    private static let suspendProofSeconds: TimeInterval = 60
    /// 每一趟外出一个编号。用户点「结束外出」就 +1。
    ///
    /// 后台重试睡眠是个长任务：它可能正卡在读日志里，此时用户点了结束、机器已经
    /// 还原好、界面回到首页——然后这个还在跑的验证醒来，把 `screen` 又改成
    /// `readyToUnplug`、`iconState` 改成 alert，**把用户拽回「还没能睡着」那一页**。
    /// 2026-10-25 11:48 就是这样：用户连点六次结束，每次都被拽回来，看着像按钮
    /// 坏了（日志里是六次重复的蓝牙还原）。带回编号，过期的一律收手。
    private var awayGeneration = 0
    /// 「结束外出」正在还原设置。按钮当场变成不可点，不然用户会一直点。
    @Published public private(set) var isEndingAway = false
    /// 扫描本身失败时留一条记录，报告里要能看出这次没检查过。
    private var scanIssue: FailedItem?
    /// 当前这份报告对应的那一趟，设置是不是已经还原过了。
    ///
    /// 正常流程里「结束外出模式」就还原完了，报告页上的「完成」只是关窗口。
    /// 只有旧版本留在磁盘上的 `.audited` 记录会走到「还没还原」这一支。
    private var settingsRestoredForReport = false

    // MARK: - 增强模式的状态

    private var strongModeTask: Task<Void, Never>?
    /// 上一 tick 的时刻。两次之间隔太久说明进程被挂起过（机器睡了）。
    private var lastAwakeTick: Date?
    /// 本次外出里已经连续醒着的时长（秒），只在真的睡过去时清零。
    private var awakeAccumulated: Double = 0
    /// 远程登录的提醒只发一次，别每 10 分钟刷一遍。
    private var didWarnRemoteLogin = false
    /// 正在后台问「有没有人远程登录」。防同一拍重复发起。
    private var forcedSleepCheckInFlight = false

    // MARK: - 唤醒日志的预读

    /// `pmset -g log` 要将近一秒，几十万行。它只在「结束外出」时用得到，而那一下
    /// 用户就盯着转圈圈。所以趁机器刚醒、用户还在插显示器的时候先读好。
    private var cachedPowerLog: String?
    private var cachedPowerLogAt: Date?
    private var warmPowerLogTask: Task<Void, Never>?

    /// 增强模式的倒计时还剩几秒。没在倒计时就是 nil。
    public var forceSleepCountdown: Int? {
        countdownPurpose == .forceSleep ? countdown : nil
    }

    private enum CountdownPurpose {
        case none
        case unplug
        /// 增强模式的「N 秒后强制睡眠」。
        case forceSleep
    }

    public convenience init() {
        self.init(deps: AppDependencies.live(), timing: .real)
    }

    /// `autoAdvanceDetect`：检测页上不等用户点，直接按「一键关闭」往下走。
    ///
    /// 只给测试和 `--simulate-away` 用。真机上这个页面必须停下来等人——这正是
    /// 用户要的「别自己数 20 秒然后动手」。
    init(deps: AppDependencies, timing: Timing = .real, autoAdvanceDetect: Bool = false) {
        self.deps = deps
        self.timing = timing
        self.autoAdvanceDetect = autoAdvanceDetect
    }

    private let autoAdvanceDetect: Bool

    // MARK: - Derived values

    public var iconStatePublisher: AnyPublisher<IconState, Never> {
        $iconState.eraseToAnyPublisher()
    }

    public var awayDurationSeconds: Int {
        guard let startedAt = session?.startedAt else { return 0 }
        return max(0, Int(now.timeIntervalSince(startedAt)))
    }

    public var awayDurationText: String {
        DurationFormatter.humanized(seconds: awayDurationSeconds)
    }

    /// 增强模式那句「机器已经醒着 X 分钟」。只说我们真的在算的事。
    public var awakeMinutesText: String {
        let minutes = max(0, awakeSeconds) / 60
        if minutes < 1 {
            return L("{0} 秒", max(0, awakeSeconds))
        }
        return L("{0} 分钟", minutes)
    }

    public var batteryDropText: String {
        guard let start = session?.batteryStart, let current = batteryNow else {
            return L("电量读取中")
        }
        let delta = start - current
        if delta <= 0 {
            return L("{0}% · 没有下降", current)
        }
        return L("{0}% · 下降 {1}%", current, delta)
    }

    public var batteryFillRatio: Double {
        Double(batteryNow ?? 0) / 100.0
    }

    public var isAwayPhase: Bool {
        session?.phase == .away
    }

    /// 「防止空闲睡眠」现在到底处在哪一档。
    ///
    /// 以前界面只有一个 `idleSleepHeld`，于是「出门时我们主动放开」和「系统拒绝」
    /// 长得一模一样，设置页把前者也写成「系统没允许」——把责任推给了系统。
    /// 这两件事的处置完全不同：前者什么都不用做，后者才需要人管。
    public enum IdleSleepStatus: Equatable {
        /// 开关关着。
        case off
        /// 拿着。
        case held
        /// 出门期间故意放开，回来自己接上。
        case away
        /// 丢了，正在自己补。
        case retrying
        /// 系统明确拒绝，只能反复重试或者去系统设置里关掉自动睡眠。
        case refused(String)
    }

    public var idleSleepStatus: IdleSleepStatus {
        guard settings.preventIdleSleep else { return .off }
        if idleSleepHeld { return .held }
        if isAwayPhase { return .away }
        if let failure = idleSleepFailure { return .refused(failure) }
        return .retrying
    }

    /// 要不要在界面上报出来。只有「系统拒绝」值得打断用户——丢了的自己会补上。
    public var idleSleepNeedsAttention: Bool {
        if case .refused = idleSleepStatus { return true }
        return false
    }

    /// 决定「能不能睡」的失败项——只有这些才进阻塞页。
    public var criticalFailures: [FailedItem] {
        failedItems.filter(\.isCritical)
    }

    /// 只影响「少醒几次」的失败项，在「可以拔掉显示器了」页用小字交代。
    public var optionalFailures: [FailedItem] {
        failedItems.filter { !$0.isCritical }
    }

    /// 蓝牙这一项失败时，阻塞页要给出可操作的出口，而不是只说「失败了」。
    public var bluetoothFailure: FailedItem? {
        failedItems.first { $0.title == "蓝牙" }
    }

    /// 自动关不掉蓝牙时，把用户带到蓝牙隐私设置页；或者他直接在控制中心关掉。
    public func openBluetoothSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// 打开「电池 / 节能」设置。
    ///
    /// 这是「系统不让程序保持清醒」时用户唯一能自己动手的地方：把「电脑进入睡眠」
    /// 设成永不。面板在 macOS 13 之后挪到了「电池」，老系统还在「节能」，
    /// 两个都试，别让按钮点下去没反应。
    public func openEnergySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Battery-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.energysaver",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    public var sleepDelaySeconds: Int { settings.sleepDelaySeconds }

    public var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return version ?? "1.0"
    }

    public var launchAtLoginText: String {
        settings.launchAtLogin ? L("已开机自启 · 无 Dock 图标") : L("未开机自启 · 无 Dock 图标")
    }

    // MARK: - Bootstrap

    public func bootstrap() {
        settings = deps.store.loadSettings()
        // The plist on disk is the truth; the stored flag can drift when the app
        // is moved or the launch agent is removed by hand.
        settings.launchAtLogin = deps.loginItem.isEnabled()
        // 换过名字或目录的话，自启动项里存的还是旧路径，下次登录就起不来了。
        // 这里只把路径改对，不去 bootout —— 那会把正在运行的自己杀掉。
        if settings.launchAtLogin, let path = Bundle.main.executablePath {
            deps.loginItem.rewriteIfNeeded(executablePath: path)
        }
        lastReport = deps.store.lastReport()
        // App 刚起来的时候后台服务可能还在启动（launchd KeepAlive），先给它一点时间，
        // 否则会把「还在起」误判成「没装」。
        deps.helper.waitUntilReady(timeout: 2)
        helperInstalled = deps.helper.isInstalled
        displayCount = deps.displays.activeDisplayCount()
        batteryNow = deps.battery.percentage()
        now = deps.clock.now
        refreshSleepDisabled()
        // 「防止空闲睡眠」默认开：开机第一秒就得按设置拿上，否则从登录到用户点开
        // 设置之间，机器会按系统默认的空闲时间去睡。
        applyIdleSleepSetting()
        // 显示器观察常驻，不只在出门流程里。
        //
        // 以前只有「外出中」才挂着回调，因为只有拔线检测要用它。现在首页也需要：
        // 勾着「没有内建屏」的机器，唤醒之后系统会把内屏装回来，得有人发现并
        // 再摘一次。首页多挂一个回调的代价只是几次日志。
        observeDisplaysForReturn()

        if !settings.onboardingDone {
            screen = .onboarding(1)
            return
        }
        guard let saved = deps.store.loadState() else {
            screen = .home
            iconState = .home
            return
        }
        session = saved
        report = saved.lastReport
        switch saved.phase {
        case .away:
            screen = .away
            iconState = .away
            bluetoothWasOn = saved.snapshot.bluetoothPower != 0
            startTicker()
            observeDisplaysForReturn()
            // 重启后接着盯：增强模式不该因为重启就失效。
            startStrongModeWatch()
            // 重启/重开之后用户第一件事就是点图标结束外出。日志现在就读，
            // 等他点的时候不用再对着转圈圈等一秒。
            warmPowerLog()
        case .audited:
            screen = .report
            iconState = (saved.lastReport?.hasAnomaly ?? false) ? .alert : .home
        case .needsRestore:
            // 上次「恢复原样」没做完。状态文件必须留着，等用户点重试。
            screen = .home
            iconState = .alert
            pendingRestore = true
        case .home:
            screen = .home
            iconState = .home
        }
    }

    /// 启动时该做、但会动系统的那几件事。
    ///
    /// **不能塞进 `bootstrap()`。** bootstrap 是同步的，断屏是异步的；在那里起一个
    /// Task，它可能在「开始外出」刚记完显示器基线之后才执行，把基线里的内屏删掉，
    /// 于是被判成「已经拔线」，机器提前睡。测试里这个竞态必现，真机只是概率低。
    public func startupSystemTasks() {
        // 断言得有人看着。放在最前面：它跟「有没有内建屏」无关，不能跟着一起被跳过。
        startIdleSleepGuard()
        guard settings.noBuiltinDisplay else { return }
        Task { await applyBuiltinCut(true) }
    }

    // MARK: - Onboarding

    public func advanceOnboarding() {
        switch screen {
        case .onboarding(1):
            screen = .onboarding(2)
        case .onboarding(2):
            screen = .onboarding(3)
        default:
            break
        }
    }

    public func toggleAuthorizationReason() {
        showAuthorizationReason.toggle()
    }

    public func installHelper() {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        // 只有从引导流程里点进来才往后翻一页。设置页、阻塞页点安装的，装完就留在
        // 原地——以前不看场景，装完一律跳到引导第 3 页，用户莫名其妙。
        var wasOnboarding = false
        if case .onboarding = screen { wasOnboarding = true }
        do {
            try deps.helper.install()
            helperInstalled = deps.helper.isInstalled
            needsHelperInstall = !helperInstalled
            if helperInstalled, wasOnboarding {
                screen = .onboarding(3)
            }
        } catch {
            errorMessage = FailureText.humanize(error.localizedDescription, severity: .critical)
        }
    }

    public func finishOnboarding() {
        settings.onboardingDone = true
        try? deps.store.saveSettings(settings)
        screen = .home
        iconState = .home
        deps.notifier.requestAuthorization()
        // 蓝牙权限必须在「有屏幕」的时候拿到。没有它，私有 API 一调进程就被
        // TCC 杀掉，自动关蓝牙这条路根本走不通——那时候用户已经拔了线，没有
        // 屏幕可以点授权。
        BluetoothPermission.shared.requestIfNeeded()
    }

    public func replayOnboarding() {
        settings.onboardingDone = false
        try? deps.store.saveSettings(settings)
        screen = .onboarding(1)
    }

    // MARK: - Navigation

    public func showSettings() {
        // 记住从哪一页进来的。以前这里不看来源，只要 phase == .away 就回「外出中」，
        // 结果在「还没睡着」的拔线页上点开设置再关掉，会跳到一个说「已进入睡眠」
        // 的页面去。
        screenBeforeSettings = screen
        screen = .settings
        refreshNotificationStatus()
        refreshSystemChips()
    }

    /// 打开设置页时把「系统说了算」的两件事重新读一遍。
    ///
    /// 这两行的状态不能靠记忆：断言可能被系统收走，内建屏可能被唤醒时的重排
    /// 装回来。设置页显示的必须是此刻的事实，否则又变成软件在替系统说话。
    private func refreshSystemChips() {
        idleSleepHeld = deps.idleSleep.isHolding
        if idleSleepHeld { idleSleepFailure = nil }
        if deps.displayCutter.isAvailable {
            builtinCutState = deps.displayCutter.isBuiltinActive ? .connected : .disconnected
            // 勾着但屏又回来了：交给维持逻辑去重断，界面下一拍就会变。
            maintainBuiltinCutIfNeeded()
        } else {
            builtinCutState = .unsupported
        }
    }

    /// 这个系统上能不能摘内建屏。不能用时设置页要把开关显示成灰的。
    public var isBuiltinCutAvailable: Bool { deps.displayCutter.isAvailable }

    /// 通知到底能不能弹。设置页每次打开都重新问一遍系统，不缓存。
    public func refreshNotificationStatus() {
        Task { [weak self] in
            guard let self else { return }
            self.notificationStatus = await self.deps.notifier.authorizationSummary()
        }
    }

    /// 「试一下」：让用户当场看见通知长什么样，而不是等到出门在外才发现没弹。
    ///
    /// 关键不是「发出去」，是「发完之后去核对」。`add` 对没授权、专注模式、
    /// 通知样式设成「无」这几种情况全都安静地成功——只看它有没有抛错，
    /// 就会重演「点了没反应，界面还说已发送」。
    public func sendTestNotification() {
        Task { [weak self] in
            guard let self else { return }
            let result = await self.deps.notifier.sendTest(
                title: L("通知是通的"),
                body: L("增强模式到点时会这样提醒你：30 秒后强制睡眠")
            )
            self.notificationStatus = result.summary
            HKMLog.info("试一下通知：\(result.summary)")
            // 过一会儿回到常驻的授权状态，免得这行字永远停在结果上。
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            self.notificationStatus = await self.deps.notifier.authorizationSummary()
        }
    }

    public func dismissSettings() {
        if let previous = screenBeforeSettings, previous != .settings {
            screenBeforeSettings = nil
            // 期间状态可能变了（比如睡成了 / 结束了），别回到已经不成立的页面。
            switch previous {
            case .away where session?.phase != .away:
                screen = .home
            case .report where report == nil:
                screen = .home
            default:
                screen = previous
            }
            return
        }
        if session?.phase == .away {
            screen = .away
        } else if session?.phase == .audited, report != nil {
            screen = .report
        } else if screen == .blocked {
            screen = .blocked
        } else {
            screen = .home
        }
    }

    public func toggleDetail() {
        showDetail.toggle()
    }

    public func handleIconTap() {
        // 只有「已经出门、机器睡过了」这一种情况，点图标才是「结束外出」。
        //
        // 之前只判断了 phase == .away，而 phase 在流程一开始就变成 .away 了：
        // 用户在「可以拔掉显示器了」那一页想点开看看，一按就结束了一趟还没开始的
        // 外出，直接生成一份「这次没睡成」的报告——用户那两次 16 秒 / 41 秒的
        // 失败记录就是这么来的。
        guard let state = session, state.phase == .away, screen == .away, !isBusy else { return }
        // 同步置位：图标在菜单栏上，用户很容易连点两下，
        // 以前两次都能进 finishAway，于是同一趟外出写了两份报告。
        isBusy = true
        screen = .auditing
        Task { await finishAwayNow(state) }
    }

    // MARK: - Away mode: entering

    public func beginAway() {
        // 已经在跑流程就不要再开一条：以前 isBusy 是在 Task 里才置位，
        // 快速点两下能同时进两个流程。
        guard !isBusy, session?.phase != .away else { return }

        // 后台服务不是这一版：它会把新参数**静默忽略**（比如按电源类型分开还原），
        // 界面一切正常、实际什么都没做。这比报错糟得多，所以出门前就拦住。
        // 2026-10-25 现场：改了 helper 的参数，跑的却还是旧进程。
        helperInstalled = deps.helper.isInstalled
        guard helperInstalled else {
            failedItems = [
                FailedItem(
                    title: "后台服务",
                    detail: L("装的是旧版本，需要更新一次才能安全地改设置"),
                    severity: .critical
                )
            ]
            needsHelperInstall = true
            errorMessage = nil
            screen = .blocked
            return
        }

        // 上次恢复没做完就先补上：否则这次拍到的「原始设置」是上次改过的值。
        if pendingRestore {
            isBusy = true
            Task {
                await restoreAndReturnHome()
                isBusy = false
                guard !pendingRestore else { return }
                beginAway()
            }
            return
        }

        isBusy = true
        errorMessage = nil
        showDetail = false
        failedItems = []
        resetCompletedActions()
        closingStep = nil
        killedCount = 0
        needsHelperInstall = false
        scanIssue = nil
        // 扫描要几百毫秒（`pmset -g assertions` + 每个进程一次 `ps`），
        // 所以先切到「正在检查」，让界面立刻有反应，再把活干在后台。
        screen = .scanning
        scanTask = Task { await beginAwayNow() }
    }

    /// 扫一遍断言，然后决定是进检测页还是直接往下走。
    private func beginAwayNow() async {
        bluetoothWasOn = (await deps.bluetooth.powerState() ?? 1) != 0

        do {
            let scan = try await deps.scanner.scan()
            blockers = actionableBlockers(from: scan)
            systemBlockerCount = scan.systemCount
        } catch {
            // 扫不出来不等于没有东西在占睡眠。以前这里当成「0 个」继续走，
            // 用户会以为一切正常，报告里也看不出这次根本没检查过。
            blockers = []
            systemBlockerCount = 0
            displayOnlyCount = 0
            scanIssue = FailedItem(title: "扫描", error: error, severity: .optional)
            errorMessage = FailureText.humanize(error.localizedDescription, severity: .optional)
        }
        isBusy = false

        // 没有程序在阻止睡眠就不必让用户对着空列表做选择。
        guard !blockers.isEmpty else {
            narrate("[1/8] 扫描断言… 没有程序在阻止睡眠，跳过检测页")
            startAwaySequence()
            return
        }

        narrate(
            "[1/8] 扫描断言… 发现 \(blockers.count) 个"
                + (displayOnlyCount > 0 ? "（另有 \(displayOnlyCount) 个只挡屏幕，不退出）" : "")
        )
        screen = .detecting
        if autoAdvanceDetect {
            closeImmediately()
            return
        }
        // 用户自己去关程序也行——软件自己看得见关没关干净，不需要他回来点任何按钮。
        watchBlockers()
    }

    /// 在检测页上每隔一会儿重扫一遍。
    ///
    /// 以前这里要用户点「我关好了，继续」再重扫一次。可「关没关掉」这件事机器
    /// 自己就能查，让用户回来汇报一遍纯属多余，而且他忘了点就卡在这一页。
    private func watchBlockers() {
        blockerWatchTask?.cancel()
        blockerWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.timing.detectPollSeconds
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, self.screen == .detecting, !self.isBusy else { return }
                await self.recheckBlockers()
            }
        }
    }

    /// 重扫一遍：少了的从清单上抹掉，全空了就自动往下走。
    private func recheckBlockers() async {
        guard let scan = try? await deps.scanner.scan() else { return }
        let left = actionableBlockers(from: scan)
        systemBlockerCount = scan.systemCount
        blockers = left
        guard left.isEmpty else { return }
        narrate("检测页：挡睡眠的程序都没了，自动往下走")
        startAwaySequence()
    }

    public func cancelDetecting() {
        cancelCountdown()
        blockerWatchTask?.cancel()
        blockerWatchTask = nil
        scanTask?.cancel()
        scanTask = nil
        blockers = []
        systemBlockerCount = 0
        displayOnlyCount = 0
        scanIssue = nil
        isBusy = false
        screen = .home
        iconState = .home
    }

    public func closeImmediately() {
        cancelCountdown()
        blockerWatchTask?.cancel()
        blockerWatchTask = nil
        startAwaySequence()
    }

    public func startAwaySequence() {
        cancelCountdown()
        blockerWatchTask?.cancel()
        blockerWatchTask = nil
        guard !isBusy else { return }
        // 同步置位，别等 Task 起来——否则连点两下会开两条流程。
        isBusy = true
        closingStep = nil
        // 关键：这一页要一直显示着，直到流程结束。以前 popover 会被系统收走，
        // 用户根本看不到「正在自动关闭」，只看到鼠标卡了一下。
        screen = .closing
        flowTask = Task { await performAwaySequence() }
    }

    /// 测试与 `--simulate-away` 用：等当前流程真正跑完。
    func waitForFlow() async {
        await scanTask?.value
        await flowTask?.value
    }

    /// 把当前这一步挂到界面上。关闭页要能看见「正在关什么」，
    /// 而不是盯着一个不动的窗口猜它是不是死了。
    private func step(_ text: String) {
        closingStep = text
    }

    private func done(_ text: String) {
        completedActions.append(text)
        closingStep = nil
    }

    /// 清空完成清单，连同上面两个「这一条记过没有」的标记。
    private func resetCompletedActions() {
        completedActions = []
        killSummaryIndex = nil
        bluetoothMarkedDone = false
        bluetoothOutcome = .untouched
    }

    /// 真正的外出流程。测试和 `--simulate-away` 直接 await 它。
    func performAwaySequence() async {
        isBusy = true
        defer {
            isBusy = false
            closingStep = nil
        }

        // 重跑（比如刚装好后端服务）时不能重新拍快照：那会儿 pmset 已经被改过了，
        // 再拍一张就等于把「外出中」的状态当成用户的原始设置，恢复时会把机器留在
        // 一个睡不着的状态里。第一次进入才拍，其余字段也照抄。
        let resuming = session?.phase == .away
        let startedAt = resuming ? (session?.startedAt ?? deps.clock.now) : deps.clock.now
        var snapshot = resuming ? (session?.snapshot ?? Snapshot()) : await captureSnapshot()

        var state = SessionState(
            phase: .away,
            startedAt: startedAt,
            timeZoneOffsetMinutes: session?.timeZoneOffsetMinutes
                ?? TimeZone.current.secondsFromGMT(for: startedAt) / 60,
            logAnchor: session?.logAnchor ?? PowerLogDateFormatter.string(from: startedAt),
            batteryStart: resuming ? session?.batteryStart : deps.battery.percentage(),
            bootTimeAtStart: resuming ? (session?.bootTimeAtStart ?? deps.clock.bootTime()) : deps.clock.bootTime(),
            displayDetachedAt: session?.displayDetachedAt,
            snapshot: snapshot,
            lastReport: lastReport
        )

        var failures: [FailedItem] = scanIssue.map { [$0] } ?? []
        // 马上要睡了，先把「防止空闲睡眠」放开。
        //
        // 为什么在这里、不是点「开始外出」那一刻：检测页上他还要花时间关程序，
        // 那段时间机器不该先睡过去。为什么干脆放开而不是留着：它只挡空闲睡眠、
        // 不挡 `pmset sleepnow`，所以放开不影响这次睡眠；而万一后面流程挂了，
        // 睡前的 `sleep 1` 还能让机器自己睡回去——留着就等于把这条退路堵死。
        _ = deps.idleSleep.apply(enabled: false)
        idleSleepHeld = false
        // 这是我们自己放开的，不是系统拒绝。不清掉的话，设置页会把「出门期间」
        // 说成「系统没允许」。
        idleSleepFailure = nil
        idleSleepNextRetryAt = nil
        // 进度清单从零开始：这个流程可能因为装了后台服务而重跑一遍。
        resetCompletedActions()

        // L1 first: without this nothing else matters.
        step(L("锁定睡眠设置"))
        let powerFailures = await deps.power.applyAwaySettings(
            current: snapshot.pmset,
            cancelScheduledWakes: !snapshot.scheduledWake.isEmpty
        )
        failures += powerFailures
        if powerFailures.isEmpty {
            done(L("锁定了睡眠设置"))
        } else {
            done(L("睡眠设置没写全"))
        }
        narrate(describePowerStep(snapshot: snapshot.pmset, failures: powerFailures))

        // TEMP-PREVIEW：本地截图核对时放慢，核对完删掉。
        if FileManager.default.fileExists(atPath: "/tmp/hkm_slow") {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
        }


        // Time Machine 是优化项：没开备份就直接跳过，没关成也不许阻断。
        step(L("暂停 Time Machine"))
        let timeMachineOutcome = await deps.timeMachine.disable()
        snapshot.timeMachineEnabled = timeMachineOutcome.didDisable
        if let failure = timeMachineOutcome.failure {
            failures.append(failure)
            narrate("[3/8] 暂停 Time Machine… ✗ \(failure.detail)")
        } else if timeMachineOutcome.didDisable {
            done(L("暂停了 Time Machine"))
            narrate("[3/8] 暂停 Time Machine… ✓")
        } else {
            narrate("[3/8] 暂停 Time Machine… 跳过（无备份目标）")
        }

        step(L("关闭共享服务"))
        let sharingFailures = await deps.sharing.disableAll()
        failures += sharingFailures
        if !snapshot.sharing.isEmpty, sharingFailures.isEmpty {
            done(L("关闭了共享服务"))
        }
        narrate(
            sharingFailures.isEmpty
                ? "[4/8] 关闭共享服务… \(snapshot.sharing.isEmpty ? "跳过（本来就没开）" : "✓")"
                : "[4/8] 关闭共享服务… ✗ 不影响睡眠"
        )

        step(L("关闭蓝牙"))
        if snapshot.bluetoothPower == 0 {
            bluetoothOutcome = .alreadyOff
            done(L("蓝牙本来就关着"))
            narrate("[5/8] 关闭蓝牙… 跳过（本来就关着）")
        } else if let reason = await deps.bluetooth.setPower(false) {
            let detail = FailureText.humanize(reason, severity: .critical)
            failures.append(FailedItem(title: "蓝牙", detail: detail))
            narrate("[5/8] 关闭蓝牙… ✗ \(detail)")
        } else {
            bluetoothOutcome = .turnedOff
            done(L("关闭了蓝牙"))
            bluetoothMarkedDone = true
            narrate("[5/8] 关闭蓝牙… ✓")
        }

        // L2: quit the processes that hold sleep assertions.
        step(L("退出阻止睡眠的程序"))
        let killResult = await killAll()
        killedCount = killResult.count
        failures += killResult.failures
        if !killResult.failures.isEmpty {
            blockers = killResult.remaining
        }
        if killResult.count > 0 {
            killSummaryIndex = completedActions.count
            done(L("关闭了 {0} 个程序", killResult.count))
        } else {
            done(L("没有程序在阻止睡眠"))
        }
        narrate(killResult.narration)

        step(L("关闭网络唤醒"))
        let wompFailed = failures.contains { $0.title == "睡眠设置 womp" }
        if snapshot.pmset["womp"] == 0 {
            done(L("网络唤醒本来就关着"))
            narrate("[7/8] 关闭网络唤醒… 跳过（本来就关着）")
        } else if !wompFailed {
            done(L("关闭了网络唤醒"))
            narrate("[7/8] 关闭网络唤醒… ✓")
        } else {
            narrate("[7/8] 关闭网络唤醒… ✗")
        }

        snapshot.failedItems = failures.map(\.summary)
        state.snapshot = snapshot
        session = state
        try? deps.store.saveState(state)

        failedItems = failures
        needsHelperInstall = !deps.helper.isInstalled && failures.contains { $0.title == "后台服务" }

        // 只有「能不能睡」的项才配打断用户；优化项失败照常出门。
        switch AwayDecision.decide(failures) {
        case .proceed, .proceedWithNotes:
            enterReadyToUnplug()
        case .blocked:
            screen = .blocked
            narrate("→ 状态：blocked（\(criticalFailures.count) 个关键项失败）")
        }
    }

    /// 出门前拍一张「机器现在长什么样」，回来照着它恢复。
    ///
    /// 蓝牙那一步要走 `system_profiler`（0.5～2.5 秒），共享服务要跑 netstat，
    /// 全部放在后台线程读，界面不会跟着卡。
    private func captureSnapshot() async -> Snapshot {
        var snapshot = Snapshot()
        snapshot.pmset = (try? await deps.power.readSnapshotAsync()) ?? PmsetSnapshot()
        snapshot.bluetoothPower = await deps.bluetooth.powerState()
        // timeMachineEnabled 不在这里读：它记录的是「我们到底有没有关掉备份」，
        // 由 disable() 的结果写入，否则没关过也会在恢复时把备份打开。
        snapshot.sharing = await deps.sharing.listeningLabels()
        snapshot.scheduledWake = deps.power.scheduledWakes()
        return snapshot
    }

    private func describePowerStep(snapshot: PmsetSnapshot, failures: [FailedItem]) -> String {
        // 后台服务整条挂了的时候只报一条汇总项，这时每个键都算失败。
        let aggregateFailure = failures.contains { $0.title == "睡眠设置" }
        let parts = PowerSettings.awayTargets.map { target -> String in
            let failed = aggregateFailure || failures.contains { $0.title == "睡眠设置 \(target.key)" }
            if failed { return "\(target.key) ✗" }
            if let current = snapshot[target.key] {
                if current == target.value { return "\(target.key) 已经是 \(target.value)" }
                return "\(target.key) \(current)→\(target.value) ✓"
            }
            return "\(target.key) →\(target.value) ✓"
        }
        return "[2/8] 锁定设置… " + parts.joined(separator: "  ")
    }

    private struct KillResult {
        var count: Int
        var failures: [FailedItem]
        var remaining: [SleepBlocker]
        var narration: String
    }

    /// 需要退出的那批：只留真正挡睡眠的。
    ///
    /// `PreventUserIdleDisplaySleep` 只让屏幕不灭，和「电脑能不能睡」无关；
    /// 显示器都拔了的机器更没有屏幕可挡。为它退掉一个正在放视频的播放器，
    /// 只是白白丢掉用户的进度——这和「恢复时把没开的共享服务打开」是同一类错。
    private func actionableBlockers(from scan: BlockerScanResult) -> [SleepBlocker] {
        let actionable = scan.blockers.filter { $0.kind == .blocking }
        displayOnlyCount = scan.blockers.count - actionable.count
        return actionable
    }

    private func killAll() async -> KillResult {
        var killed = 0
        var failures: [FailedItem] = []
        var remaining: [SleepBlocker] = []
        var names: [String] = []
        var didReallyKill = false

        var targets = blockers
        if targets.isEmpty, let scan = try? await deps.scanner.scan() {
            targets = actionableBlockers(from: scan)
            systemBlockerCount = scan.systemCount
        }

        for blocker in targets {
            let outcome = await deps.killer.kill(blocker)
            switch outcome {
            case .terminated, .forceTerminated:
                killed += 1
                didReallyKill = true
                names.append("\(blocker.processName) ✓")
            case .alreadyGone:
                killed += 1
                names.append("\(blocker.processName) 已退出")
            case .dryRun:
                killed += 1
                names.append("\(blocker.processName) ✓（dry-run）")
            case let .failed(message):
                failures.append(FailedItem(title: blocker.processName, detail: message))
                remaining.append(blocker)
                names.append("\(blocker.processName) ✗")
            }
        }

        // 被 launchd 托管的程序退出后会自己回来。只看 kill() 的返回值会误报成功，
        // 所以真关过之后必须再扫一遍确认。
        if didReallyKill, let rescan = try? await deps.scanner.scan() {
            for blocker in rescan.blockers where targets.contains(where: { $0.sameProcess(as: blocker) }) {
                if remaining.contains(where: { $0.sameProcess(as: blocker) }) { continue }
                failures.append(
                    FailedItem(title: blocker.processName, detail: L("退出后又自己起来了，还在阻止睡眠"))
                )
                remaining.append(blocker)
                names.append("\(blocker.processName) 又起来了 ✗")
            }
        }
        // 成功的那批已经不在了，列表里只留还活着的，别把旧数据留给下一页。
        blockers = remaining

        let narration = names.isEmpty
            ? "[6/8] 关闭程序… 没有需要关闭的"
            : "[6/8] 关闭程序… " + names.joined(separator: "  ")
        return KillResult(count: killed, failures: failures, remaining: remaining, narration: narration)
    }

    /// 「我处理好了」: re-scan and only continue when nothing is left.
    public func retryAfterManualFix() {
        guard !isBusy else { return }
        isBusy = true
        Task { await retryAfterManualFixNow() }
    }

    func retryAfterManualFixNow() async {
        isBusy = true
        defer { isBusy = false }

        // 蓝牙是「关不掉就请用户手动关」的典型。用户在控制中心关掉之后点
        // 「我处理好了」，这里必须重新读一次真实状态，否则他会永远卡在这一页。
        if failedItems.contains(where: { $0.title == "蓝牙" }), await deps.bluetooth.powerState() == 0 {
            failedItems.removeAll { $0.title == "蓝牙" }
            if !bluetoothMarkedDone {
                completedActions.append(L("关闭了蓝牙"))
                bluetoothMarkedDone = true
                bluetoothOutcome = .turnedOff
            }
            narrate("→ 蓝牙已由用户关闭")
        }

        do {
            let scan = try await deps.scanner.scan()
            systemBlockerCount = scan.systemCount
            let left = actionableBlockers(from: scan)
            if left.isEmpty {
                blockers = []
                // 保留优化项的遗漏，别把 Time Machine 那类小字一起清掉。
                failedItems = failedItems.filter { !$0.isCritical }
                needsHelperInstall = false
                killedCount += 1
                // 清单是按发生顺序排的，这一条就跟着追加；别去改别人的位置。
                let summary = L("关闭了 {0} 个程序", killedCount)
                if let index = killSummaryIndex, completedActions.indices.contains(index) {
                    completedActions[index] = summary
                } else {
                    killSummaryIndex = completedActions.count
                    completedActions.append(summary)
                }
                enterReadyToUnplug()
            } else {
                blockers = left
                failedItems = failedItems.filter { !$0.isCritical } + left.map {
                    FailedItem(title: $0.processName, detail: L("无法自动退出，它还在阻止睡眠。请手动退出这个程序。"))
                }
            }
        } catch {
            errorMessage = FailureText.humanize(error.localizedDescription, severity: .critical)
        }
    }

    /// 阻塞页上的「安装后台服务」。
    ///
    /// 这里**不能**先把 `isBusy` 置上：`installHelper()` 开头就是 `guard !isBusy`，
    /// 先置了它会直接 return——这个按钮以前一直是死的，点了毫无反应。
    public func installHelperFromBlocked() {
        guard !isBusy else { return }
        Task { await installHelperFromBlockedNow() }
    }

    /// 同步版本给测试与 `--simulate-away` 用：装完立刻重试，不用等两条 Task。
    func installHelperFromBlockedNow() async {
        installHelper()
        guard helperInstalled else { return }
        // 装完必须把整条流程重跑一遍：刚才失败的 pmset 写入现在才可能成功，
        // 只重扫断言会让用户带着没写进去的设置出门。
        await performAwaySequence()
    }

    /// 「仍然继续」: keep going, the report will say the machine may have not slept.
    public func continueAnyway() {
        guard !isBusy else { return }
        var updated = session
        updated?.snapshot.failedItems = failedItems.map(\.summary)
        session = updated
        if let updated {
            try? deps.store.saveState(updated)
        }
        enterReadyToUnplug()
    }

    private func enterReadyToUnplug() {
        // 关键项到这里已经处理完（要么成功，要么用户点了「仍然继续」），
        // 只留下不影响睡眠的遗漏，在页面上用一行小字交代。
        failedItems = failedItems.filter { !$0.isCritical }
        screen = .readyToUnplug
        unplugCountdown = nil
        didMarkDetached = false
        sleepOutcome = .idle
        didPostSleepFailure = false
        awaitingDisplayReturnForRetry = false
        displayCount = deps.displays.activeDisplayCount()
        // 基线只记**外接**屏。
        //
        // 内建屏会随手合盖、被系统回收、在 clamshell 下时长时消失，把它算进基线，
        // 用户什么都没拔也会被判成「拔线了」：2026-10-25 11:47:17 就是这么来的——
        // 基线 [2, 1] 里那块内建屏一消失，软件立刻倒计时、连叫三次睡眠、然后报
        // 「还没能睡着」，而那一刻用户正坐在电脑前，外接屏好端端插着。
        // 基线只记**外接的真显示器**：内建屏随手合盖，虚拟屏（MacHead、UU 远程
        // 建的，或者拔线后系统留的空壳）根本不是用户眼前的屏，都不该进基线——
        // 它们重建时 ID 会变，进了基线就会误判成「拔线」。
        baselineDisplayIDs = deps.displays.displaySnapshots()
            .filter { $0.isRealDisplay && !$0.builtin }
            .map(\.id)
        readyPageEnteredAt = deps.clock.now
        displaysDetached = isDisplayDetached()
        HKMLog.info("进入拔线页：当前显示器 \(displayCount) 个，基线 \(baselineDisplayIDs)（\(deps.displays.describeDisplays())），主屏 \(deps.displays.mainDisplayID())")
        if baselineDisplayIDs.isEmpty {
            // 这一刻没有真外接屏可记（常见于刚关了 MacHead、或拔线动作本身让拓扑
            // 停摆了一两秒）。等它出现会自动补记，这里先留一行，出事好查。
            HKMLog.info("基线是空的：等真外接屏出现再补记，否则拔线判不出来")
        }
        deps.displays.setHandler { [weak self] count in
            self?.handleDisplayChange(count)
        }
        deps.displays.start()
        startUnplugPoll()
        narrate("[8/8] 等待拔线… 当前显示器 \(displayCount) 个")
        if displaysDetached {
            markDetachedAndCountdown()
        }
    }

    // MARK: - Away mode: unplug & sleep

    /// 基线空了就重新记一次。
    ///
    /// 为什么需要补记：进拔线页那一刻，显示器拓扑很可能正在翻腾——我们刚关了
    /// MacHead、刚拔了线、系统还在重排窗口，外接屏会短暂地从列表里消失。基线
    /// 要是正好记在这个空档里，就成了空数组，于是：
    ///
    ///   · 「基线里那些 ID 不见了」这条判据永远不成立（空集是任何集合的子集）；
    ///   · 只剩 `activeDisplayCount() == 0` 这条兜底，而拆了屏的机器上那个**假内建屏**
    ///     一直算一块活动显示器，于是它永远不成立；
    ///   · 用户拔了线，软件一声不响——键盘灯还亮着，他以为没生效，只好整趟重来。
    ///
    /// 2026-11-03 12:40 就是这样：12:40:07 外接屏短暂消失，12:40:08 进拔线页，
    /// 基线记成 `[]`；12:40:28 外接屏回来了，可基线不会自己补，那次出门从头到尾
    /// 没判出「已拔线」。
    ///
    /// 所以：只要页还没离开、基线还是空的、而眼前又有真外接屏了，就把它记成基线。
    /// 这不是「猜」——用户站在机器前面，他接下来要拔的就是眼前这块屏。
    private func adoptBaselineIfEmpty() {
        guard screen == .readyToUnplug, baselineDisplayIDs.isEmpty else { return }
        let ids = deps.displays.displaySnapshots()
            .filter { $0.isRealDisplay && !$0.builtin }
            .map(\.id)
        guard !ids.isEmpty else { return }
        baselineDisplayIDs = ids
        // 刚看到外接屏，这一刻肯定还没拔。
        displaysDetached = false
        HKMLog.info("补记拔线基线：\(ids)（进拔线页时一块外接屏都没看到）")
        narrate("[8/8] 重新记下要拔的屏：\(ids)")
    }

    /// 用户让我拔的那块屏，现在还在不在。
    ///
    /// 两条判据取「或」，任意一条成立就算拔了：
    ///
    /// 1. **眼前一块真显示器都不剩。** 排除内建屏（随手合盖、clamshell 下时长时
    ///    消失），也排除**虚拟屏**——MacHead、UU 远程这类软件会建，拔线之后系统
    ///    自己也会留一块空壳，它们都读不到真实 EDID。不排除的话日志会写成
    ///    「判定已拔线：基线 [2] → 现在 #26 1920x1080」，明明还有块屏却说拔了。
    /// 2. **基线里那些 ID 不在 online 列表里了。** 这条留着是因为有些机型拔线后
    ///    留下的影子屏会沿用真屏的 ID 和 EDID，第 1 条认不出来。
    ///
    /// 只看 `online`，不看 `active`：显示器休眠（DPMS）时 active 变 false 但
    /// online 仍是 true，那样会把「屏幕自动关了」误判成「线拔了」。
    ///
    /// 已知取舍：双屏只拔一块、或者换一块别的屏，第 2 条仍然会判「拔线」。
    /// 这是「拔了就走」这个产品语义的直接结果——先保证自动睡不会失效。
    private func isDisplayDetached() -> Bool {
        let snapshots = deps.displays.displaySnapshots()
        let now = deps.displays.onlineDisplayIDs()
        guard !baselineDisplayIDs.isEmpty else {
            // 进页面时就已经一块外接屏都没有了，只能退回数量判断。
            //
            // 但数量这条在拆了屏的机器上**永远不成立**：那块假内建屏一直算一块
            // 活动显示器。用户既然在设置里声明过「这台机器没有内建屏」，就按
            // 「眼前还有没有一块真外接屏」来判——只是要等满一段宽限，别把刚关掉
            // MacHead 那阵子的拓扑抖动当成「他已经拔线走了」。
            if settings.noBuiltinDisplay,
               let entered = readyPageEnteredAt,
               deps.clock.now.timeIntervalSince(entered) >= Self.emptyBaselineGraceSeconds {
                return !snapshots.contains { $0.isRealDisplay && !$0.builtin }
            }
            return deps.displays.activeDisplayCount() == 0
        }
        if !snapshots.contains(where: { $0.isRealDisplay && !$0.builtin }) { return true }
        if !Set(baselineDisplayIDs).isSubset(of: Set(now)) { return true }
        return false
    }

    /// 拔线检测的兜底轮询。
    ///
    /// `CGDisplayRegisterReconfigurationCallback` 只在显示器拓扑变化时回调，
    /// 而无头机上拔掉唯一那块屏之后，系统自己也在重新配置，回调漏掉、或者拿不到
    /// 我们要的那个 ID，都发生过。事件驱动 + 每秒对账，两条腿走路。
    private func startUnplugPoll() {
        stopUnplugPoll()
        let interval = max(0.2, timing.unplugPollSeconds)
        unplugPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                guard let self, self.screen == .readyToUnplug else { return }
                // 每拍先看基线要不要补记：进页面那个空档记成空数组的话，
                // 下面两条判据都会失效（见 `adoptBaselineIfEmpty`）。
                self.adoptBaselineIfEmpty()
                let count = self.deps.displays.activeDisplayCount()
                let detached = self.isDisplayDetached()
                // 基线还空着的时候，每一拍都要重新算一遍：宽限期一到，判据会从
                // 「数量」切成「有没有真外接屏」，而那一刻显示器数量并不会变化。
                if detached || count != self.displayCount || self.baselineDisplayIDs.isEmpty {
                    self.handleDisplayChange(count)
                }
            }
        }
    }

    private func stopUnplugPoll() {
        unplugPollTask?.cancel()
        unplugPollTask = nil
    }

    private func handleDisplayChange(_ count: Int) {
        displayCount = count
        // 唤醒、插拔之后系统会把内建屏装回来，勾着「没有内建屏」就得再摘一次。
        maintainBuiltinCutIfNeeded()
        // 显示器回来的这一瞬间，顺手把空基线补上——否则拔线那一刻没判据。
        adoptBaselineIfEmpty()
        let detached = isDisplayDetached()
        // 盖子开着 = 人在电脑前。这是「拔线」之外的第二条线索，以前完全没有：
        // 外接屏拔掉之后基线永远是空的，用户掀开盖子软件也照样认为他还在外面。
        //
        // 但**拆掉内建屏的机器上这个信号是假的**：系统照样报一块 EDID 完全正常的
        // 内建屏（1512x982 / v1552 / m41038）。用户在设置里声明「没有内建屏」之后，
        // 就不能再拿它当证据——否则拔了线也永远不睡。
        let userPresent = !settings.noBuiltinDisplay && deps.displays.builtinOnline()
        displaysDetached = detached
        switch screen {
        case .readyToUnplug:
            if detached, !userPresent {
                if awaitingDisplayReturnForRetry {
                    narrate("[8/8] 显示器又断了，但上次没睡成，等你手动重试")
                } else if unplugCountdown == nil {
                    narrate("[8/8] 等待拔线… 基线里的显示器已断开")
                    markDetachedAndCountdown()
                }
            } else {
                // 显示器回来了（或者只是休眠又醒、盖子打开了）：倒计时必须取消，
                // 绝不硬睡。
                if unplugCountdown != nil {
                    narrate(userPresent ? "[8/8] 盖子开着，人在电脑前，取消睡眠倒计时" : "[8/8] 显示器插回来了，取消睡眠倒计时")
                    cancelCountdown()
                }
                awaitingDisplayReturnForRetry = false
            }
        case .away:
            if !detached || userPresent, !didNotifyReturn {
                didNotifyReturn = true
                deps.notifier.post(title: L("欢迎回来"), body: L("别忘了结束外出模式"))
            }
        default:
            break
        }
    }

    private func markDetachedAndCountdown() {
        guard unplugCountdown == nil, !awaitingDisplayReturnForRetry else { return }
        // 已经在请求睡眠、或者已经睡过了：显示器事件还会连着来好几次（拔线那一瞬
        // 系统会连报三四遍拓扑变化），每来一遍都起一个新倒计时，日志里就刷出一串
        // 「判定已拔线」，界面上还会闪一下倒计时。2026-10-25 12:29 真机上就是这么
        // 连刷了三次——睡眠其实只请求了一次。
        guard sleepOutcome != .requesting, sleepOutcome != .slept else { return }
        // 内建屏亮着 = 笔记本盖子开着 = 人就在电脑前。自动流程在这种时候动手
        // 是灾难：2026-10-25 01:57 用户掀开盖子，软件还在按「拔线了」处理，
        // 连叫了三次睡眠。
        //
        // 例外：用户声明过「这台机器没有内建屏」时，这个信号一律不信——拆了屏的
        // 机器系统照样报内建屏在线，信它就等于拔了线永远不睡。
        guard settings.noBuiltinDisplay || !deps.displays.builtinOnline() else {
            if !didMarkDetached {
                narrate("[8/8] 内建屏亮着（盖子开着），不自动睡眠")
            }
            return
        }
        if !didMarkDetached {
            didMarkDetached = true
            if var updated = session {
                updated.displayDetachedAt = deps.clock.now
                session = updated
                try? deps.store.saveState(updated)
            }
        }
        narrate("→ 状态：readyToUnplug → 睡眠倒计时 \(max(1, settings.sleepDelaySeconds))s")
        HKMLog.info("判定已拔线：基线 \(baselineDisplayIDs) → 现在 \(deps.displays.describeDisplays())，主屏 \(deps.displays.mainDisplayID())")
        startCountdown(seconds: max(1, settings.sleepDelaySeconds), purpose: .unplug) { [weak self] in
            self?.triggerSleepNow()
        }
    }

    private func triggerSleepNow() {
        unplugCountdown = nil
        // 倒计时是几秒前起的，到点的时候局面可能已经变了：机器已经睡下了，
        // 或者用户已经回到拔线页之外的什么地方。以前这里直接往下走，于是
        // 2026-10-25 01:57 在「确认已进入睡眠」之后两秒又叫了一次睡，失败，
        // 弹了一条「没能进入睡眠」。
        guard screen == .readyToUnplug, sleepOutcome != .slept, sleepOutcome != .requesting else {
            HKMLog.info("睡眠倒计时到点，但已经不在拔线页（\(screen)）或已在请求中，不再请求睡眠")
            return
        }
        Task { await performSleepNow() }
    }

    /// 用户手动让电脑睡：拔线页上的「不拔线，现在就睡」，以及失败后的「再睡一次」。
    ///
    /// 这个产品只有两种走法，用户说得很清楚：
    ///   1. 拔线 → 自动睡（用户不需要碰任何东西，事实上他也看不见界面了）
    ///   2. 不拔线 → 手动点一下让它睡
    ///
    /// 以前这里挂的是「我已经拔线了，让它睡」。那句话自相矛盾——真拔了线，
    /// 面板所在的这块屏就没了，没人看得见它。所以它既不可能是模式 1 的入口，
    /// 也没说清自己是模式 2。
    public func retrySleep() {
        guard !isBusy, !isEndingAway else { return }
        isBusy = true
        Task { [weak self] in
            await self?.performSleepNow(fromWatchdog: false, manual: true)
            self?.isBusy = false
        }
    }

    func performSleepNow() async {
        await performSleepNow(fromWatchdog: false)
    }

    /// `fromWatchdog`：后台重试自己调进来的时候不要再起一个新的看门狗，
    /// 否则 `startSleepRetryWatchdog()` 会把正在跑的那个（也就是它自己）取消掉，
    /// 结果只重试一次就停了。
    private func performSleepNow(fromWatchdog: Bool, manual: Bool = false) async {
        unplugCountdown = nil
        cancelCountdown()
        guard sleepOutcome != .requesting else { return }
        sleepOutcome = .requesting
        errorMessage = nil
        // 这一轮属于哪一趟外出。中途用户点了「结束」，编号就变了，下面每一步
        // 回来都要对一遍——过期的验证不许再改 sleepOutcome 和 screen。
        let generation = awayGeneration

        // 记下「我们叫它睡了」的时刻，回来才知道它到底睡没睡。
        let requestedAt = deps.clock.now
        if var updated = session {
            updated.sleepRequestedAt = requestedAt
            session = updated
            try? deps.store.saveState(updated)
        }
        HKMLog.info("请求系统睡眠（当前显示器 \(displayCount) 个）")

        var lastReason: String?
        /// 谁占着系统睡眠。手动睡失败时要用它说清原因。
        var blockedBy: [String] = []
        var slept = false
        var unverified = false

        // 显示器还插着的时候，「让系统睡眠」实际发生的是：屏幕黑一下 → WindowServer
        // 立刻抓一个 PreventSystemSleep 把系统拽回来 → 屏幕又亮。连试三次就是连闪
        // 三下，用户的原话是「反复黑屏亮屏」。
        //
        // 所以这种情况下只试一次：成不成一次就看出来了，第二次只是再闪一下。
        // 真拔了线之后（自动流程）没有屏幕可闪，多试几次才有意义。
        // 手动点的那一次同理——人就在屏幕前，别让屏幕连闪三下。
        let displayStillAttached = !isDisplayDetached()
        let maxAttempts = (manual || displayStillAttached) ? 1 : 3

        for attempt in 1...maxAttempts {
            // 机器睡下去的那几分钟里，用户完全可能已经点了「结束外出」。
            // 醒过来先确认这一趟还算数，不算就别动界面。
            guard generation == awayGeneration else {
                HKMLog.info("这一趟外出已经结束，放弃睡眠验证（第 \(attempt) 次请求后）")
                return
            }
            if attempt > 1 {
                // 拔掉显示器的那一刻 WindowServer 会临时抓一个 PreventSystemSleep，
                // 几秒后自己放掉。第一次叫不醒多半就是它，等一下再叫一次就好。
                let holders = await deps.power.systemSleepBlockers()
                if !holders.isEmpty {
                    narrate("→ 第 \(attempt) 次尝试前，\(holders.joined(separator: "、")) 还占着系统睡眠")
                }
                // 顺便再清一遍断言：这段时间可能有程序重新抓了断言。
                if let scan = try? await deps.scanner.scan() {
                    let again = actionableBlockers(from: scan)
                    if !again.isEmpty {
                        blockers = again
                        let result = await killAll()
                        killedCount += result.count
                        narrate("→ 重试前又关了 \(result.count) 个")
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(max(1, timing.countdownTick) * 1_000_000_000))
            }

            // 这一拍的起点。下面用它来判断「这段等待是不是在挂起中过去的」。
            let attemptStartedAt = deps.clock.now
            do {
                try await deps.power.sleepNow()
                narrate("→ 第 \(attempt) 次请求睡眠")
            } catch {
                lastReason = FailureText.humanize(error.localizedDescription, severity: .critical)
                narrate("→ 请求睡眠失败：\(lastReason ?? "")")
            }

            // 真睡了的话，这段等待是在挂起状态下过去的，检查会在唤醒之后才继续。
            try? await Task.sleep(nanoseconds: UInt64(max(0, timing.sleepVerifySeconds) * 1_000_000_000))

            // 第一证据：墙上时钟跳了多远。跳得比「该等的时间」多出 60 秒以上，
            // 说明进程被冻结过 = 机器真的睡了。这一条不需要读任何日志，
            // 2026-10-25 那次就是靠它才对得上的：日志读不出来，但时间跳了 96 分钟。
            let proofThreshold = max(0, timing.sleepVerifySeconds) + Self.suspendProofSeconds
            let elapsed = deps.clock.now.timeIntervalSince(attemptStartedAt)
            HKMLog.info("验证第 \(attempt) 次：等待窗口过去 \(Int(elapsed)) 秒（判定阈值 \(Int(proofThreshold)) 秒）")
            if elapsed >= proofThreshold {
                slept = true
                HKMLog.info("进程被挂起 \(Int(elapsed)) 秒 → 机器确实睡了（第 \(attempt) 次请求）")
                break
            }

            let evidence = await deps.power.sleepEvidence(since: attemptStartedAt)

            // 时钟要再看一次，而且这一次才是关键。
            //
            // `sleepnow` 之后机器通常要四五秒才真正睡下去，而读电源日志本身就要几秒。
            // 2026-10-25 10:47 那次：请求在 10:47:25，机器 10:47:30 才进睡眠，可
            // 4 秒的等待窗口在 10:47:30 就到点了——elapsed 只有 4 秒，判「没睡」，
            // 接着去读日志，进程在睡眠中被冻了四分半，醒来时把那条已经过期的结论
            // 写进日志，还弹了一条「没能进入睡眠」。真正睡了 271 秒的事实被丢掉了。
            //
            // 所以：读完证据、回到这里，再把时钟对一遍。跳过的这段旅程，只有
            // 挂起能解释。
            let elapsedAfterEvidence = deps.clock.now.timeIntervalSince(attemptStartedAt)
            if elapsedAfterEvidence >= proofThreshold {
                slept = true
                HKMLog.info("进程被挂起 \(Int(elapsedAfterEvidence)) 秒（读取睡眠证据期间）→ 机器确实睡了（第 \(attempt) 次请求）")
                break
            }

            switch evidence {
            case .slept:
                slept = true
                HKMLog.info("确认已进入睡眠（第 \(attempt) 次请求）")
            case .awake:
                unverified = false
                let holders = await deps.power.systemSleepBlockers()
                blockedBy = holders
                lastReason = holders.isEmpty
                    ? L("系统没有进入睡眠")
                    : L("{0} 占着系统睡眠", holders.joined(separator: L("、")))
                HKMLog.error("第 \(attempt) 次请求后系统仍然醒着：\(lastReason ?? "")")
            case .unknown:
                // 读不到日志 ≠ 没睡。以前这里直接算失败，一晚上七条误报。
                unverified = true
                lastReason = L("读不到电源日志，没法确认有没有睡着")
                HKMLog.error("第 \(attempt) 次请求后拿不到睡眠证据（读不到电源日志）")
            }
            if slept { break }
        }

        // 睡了很久才醒的情况：这一趟可能早就被用户结束了。绝不能再把界面
        // 拽回「还没能睡着」，也不能为一份已经作废的外出发通知。
        guard generation == awayGeneration else {
            HKMLog.info("这一趟外出已经结束，睡眠验证结果作废（\(slept ? "其实睡着了" : "没睡着")）")
            return
        }

        if slept {
            sleepOutcome = .slept
            stopUnplugPoll()
            // 这一趟真的睡着了，醒着时长从零开始算；增强模式从这里接手。
            startStrongModeWatch()
            // 验证期间用户可能已经点了「结束外出」，别把界面抢回来。
            if screen == .readyToUnplug || screen == .away {
                screen = .away
                iconState = .away
            }
            // 睡了很久才醒：醒来时显示器可能已经插回来了，那就直接提醒「欢迎回来」。
            // 不能等下一次显示器变化事件——那可能永远不来。
            if isDisplayDetached() {
                didNotifyReturn = false
            } else {
                didNotifyReturn = true
                deps.notifier.post(title: L("欢迎回来"), body: L("别忘了结束外出模式"))
            }
            startTicker()
            return
        }

        // 没睡成：绝不切到「外出中」，也绝不说「系统已进入睡眠」。
        let reason = lastReason ?? L("系统拒绝了睡眠请求")
        sleepOutcome = unverified ? .unverified(reason: reason) : .failed(reason: reason)
        // 手动那次失败不算「等你重试」——用户随时可能拔线走人，那条自动路径
        // 不能被这个标记挡住（挡了的话他拔了线也睡不了，而且看不见界面）。
        if !manual {
            awaitingDisplayReturnForRetry = true
        }
        if screen != .auditing && screen != .report {
            screen = .readyToUnplug
            iconState = .alert
        }
        if unverified {
            // 不知道就别下结论，也别推送。页面上照实说，按钮留着让用户自己决定。
            errorMessage = L("请求了睡眠，但读不到电源日志，没法确认它到底睡没睡")
            narrate("→ 睡眠状态未知：\(reason)")
            return
        }
        // 「系统没有进入睡眠」这句是循环论证，用户看完还是不知道为什么。
        if manual {
            // 手动那次人就在屏幕前：要么有程序挡着，要么刚睡下就被惊醒了。
            // 绝不能让界面去教一个此刻坐在电脑前的人「拔掉线之后它会自己睡」——
            // 他点的就是「不拔线也睡」。
            errorMessage = blockedBy.isEmpty
                ? L("刚睡下就被叫醒了。接着显示器的时候，系统很容易被一点动静弄醒")
                : L("{0} 占着系统睡眠，先退出它", blockedBy.joined(separator: L("、")))
        } else {
            errorMessage = displayStillAttached
                ? L("显示器还插着，系统刚睡下就被叫醒了。拔掉线之后它会自己睡")
                : L("没能让电脑睡着：{0}", reason)
        }
        narrate("→ 睡眠失败：\(reason)")
        // 一趟只提醒一次。以前每失败一轮弹一条，一晚上七条，把真正重要的信息淹了。
        // 手动那次不弹：人就在屏幕前看着结果，再弹一条纯属打扰。
        if !manual, !didPostSleepFailure {
            didPostSleepFailure = true
            deps.notifier.post(title: L("没能进入睡眠"), body: L("电脑还醒着：{0}", reason))
        }
        if !fromWatchdog, !manual {
            startSleepRetryWatchdog()
        }
    }

    /// 睡眠失败后继续盯着。
    ///
    /// 拦住 `pmset sleepnow` 的通常是短暂的（显示器重新配置、某个程序刚退出还没
    /// 释放断言）。只要**显示器始终没插回来**，就说明用户还在包里，继续尝试叫它
    /// 睡才是他要的；一旦插回来就立刻停手，绝不把人正在用的机器弄睡。
    private func startSleepRetryWatchdog() {
        sleepRetryTask?.cancel()
        let interval = max(0.05, timing.sleepRetrySeconds)
        sleepRetryTask = Task { [weak self] in
            var attempts = 0
            while !Task.isCancelled, attempts < 6 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                guard let self else { return }
                guard self.displaysDetached, self.screen == .readyToUnplug,
                      case .failed = self.sleepOutcome else { return }
                // 盖子开着 = 人在电脑前，别再叫它睡了。
                guard !self.deps.displays.builtinOnline() else { return }
                attempts += 1
                self.narrate("→ 后台重试睡眠（第 \(attempts) 次）")
                await self.performSleepNow(fromWatchdog: true)
                if self.sleepOutcome == .slept { return }
            }
        }
    }

    public func cancelReadyToUnplug() {
        abortAway()
    }

    // MARK: - 增强模式

    /// 增强模式开关。只在设置页里改。
    public func toggleStrongMode() {
        settings.strongMode.toggle()
        try? deps.store.saveSettings(settings)
        HKMLog.info("增强模式：\(settings.strongMode ? "开" : "关")")
        if settings.strongMode {
            startStrongModeWatch()
        } else {
            stopStrongModeWatch()
        }
    }

    /// 「防止空闲睡眠」。改完立刻生效，并把真实结果记下来。
    ///
    /// 它挡的是「没人动就自己睡」，不挡 `pmset sleepnow`。所以出门流程照睡，
    /// 不需要用户先去关这个开关；进入外出的那一刻我们会自己放开（见
    /// `performAwaySequence`），回来再按设置接上。
    public func togglePreventIdleSleep() {
        settings.preventIdleSleep.toggle()
        try? deps.store.saveSettings(settings)
        idleSleepNextRetryAt = nil
        applyIdleSleepSetting()
        HKMLog.info("防止空闲睡眠：\(settings.preventIdleSleep ? "开" : "关")，实际\(idleSleepHeld ? "拿到了" : "没拿到")")
    }

    private func applyIdleSleepSetting() {
        idleSleepHeld = deps.idleSleep.apply(enabled: settings.preventIdleSleep)
        if idleSleepHeld || !settings.preventIdleSleep {
            idleSleepFailure = nil
        } else {
            idleSleepFailure = deps.idleSleep.lastFailureText ?? L("系统不允许这个程序保持清醒")
        }
        if settings.preventIdleSleep, !idleSleepHeld {
            HKMLog.error("设置要防止空闲睡眠，但系统没给断言：\(idleSleepFailure ?? "未知")")
        }
    }

    /// 用户点了那条红字。立刻再试一次，不等看守的下一拍。
    public func retryIdleSleepNow() {
        guard settings.preventIdleSleep else { return }
        idleSleepNextRetryAt = nil
        applyIdleSleepSetting()
        HKMLog.info("手动重试防空闲睡眠：\(idleSleepHeld ? "拿到了" : "还是没拿到")")
    }

    /// 「防止空闲睡眠」的看守。
    ///
    /// 这条断言没有谁替我们保管：出门流程会主动放开，系统在唤醒、电源域重建之后
    /// 也可能收回去。以前只在启动、开关、结束外出这三处补一次，中间丢了就一直是
    /// 丢的——2026-11-07 那台机器从 11-04 12:09 一直丢到 15:47，用户只看到设置页
    /// 上一句「系统没允许」，机器则安安静静地自己睡。
    ///
    /// 所以这里自己盯着：按设置该拿着却没拿着，就补上。补不上（系统真拒绝）就退避，
    /// 别每 20 秒往日志里灌一条错误。
    private func startIdleSleepGuard() {
        idleSleepGuardTask?.cancel()
        let interval = max(1, timing.idleSleepGuardSeconds)
        idleSleepGuardTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                self?.guardIdleSleepTick()
            }
        }
    }

    /// 看守的一次心跳。也用于「睡醒之后」和「结束外出」之后的即时核对。
    func guardIdleSleepTick() {
        guard settings.preventIdleSleep, !idleSleepHeld, idleSleepAllowedNow else { return }
        if let next = idleSleepNextRetryAt, deps.clock.now < next { return }
        let wasFailing = idleSleepFailure != nil
        applyIdleSleepSetting()
        if idleSleepHeld {
            idleSleepNextRetryAt = nil
            if wasFailing { HKMLog.info("防止空闲睡眠：补上了，之前系统拒绝过") }
        } else {
            idleSleepNextRetryAt = deps.clock.now.addingTimeInterval(timing.idleSleepRefusedRetrySeconds)
        }
    }

    /// 现在该不该拿着这条断言。
    ///
    /// 只有「在家」才该拿。出门流程从放掉断言到 `session.phase` 变成 away 之间有几秒，
    /// 这几秒里要是看守把它抢回来，后面流程真挂了就连「`sleep 1` 让它自己睡回去」这条
    /// 退路都没有了——那正是 `performAwaySequence` 里放开它的理由。
    private var idleSleepAllowedNow: Bool {
        guard !isAwayPhase else { return false }
        switch screen {
        case .home, .settings, .report, .onboarding:
            return true
        case .scanning, .detecting, .closing, .blocked, .readyToUnplug, .away, .auditing:
            return false
        }
    }

    /// 「没有内建屏」。勾上就真的把内建屏从显示拓扑里摘掉，取消就装回来。
    ///
    /// 以前它只是一句声明：拆掉屏的机器上 macOS 照样报一块 EDID 完全正常的内建屏
    /// （真机抓到 1512x982 / v1552 / m41038），程序分辨不出真假，只能问用户，
    /// 然后绕过这个信号。现在改成照做——他说没有，那就真拿掉，让系统也别再报。
    /// 这样「内建屏在线」这个信号本身就变真了，不用再到处打补丁。
    public func toggleNoBuiltinDisplay() {
        guard !isBusy else { return }
        settings.noBuiltinDisplay.toggle()
        try? deps.store.saveSettings(settings)
        HKMLog.info("没有内建屏：\(settings.noBuiltinDisplay ? "开" : "关")")
        let target = settings.noBuiltinDisplay
        isBusy = true
        Task { [weak self] in
            guard let self else { return }
            await self.applyBuiltinCut(target)
            self.isBusy = false
            // 开关一改，「人在不在」的判断就变了，立刻按当前显示器状态重算一遍——
            // 否则要等下一次显示器变化，而他可能已经拔完线走了。
            self.handleDisplayChange(self.deps.displays.activeDisplayCount())
        }
    }

    /// ⌘H 走的路：按当前状态反过来切。
    ///
    /// 它和设置页那个开关是**同一个状态**，不是两套：按一下接回内屏 = 取消勾选，
    /// 再按一下断开 = 重新勾上。否则会出现「设置说没内屏、屏却亮着」，而维持
    /// 断开的逻辑下一秒又把它断回去，按了跟没按一样。
    public func toggleBuiltinByHotKey() {
        // 出门流程里不响应：那时候系统正在重排显示器，插一脚会让拔线判断和
        // 睡眠验证都乱掉。
        switch screen {
        case .detecting, .closing, .readyToUnplug, .away, .blocked, .auditing:
            HKMLog.info("⌘H：正在出门流程里（\(screen)），不切换内建屏")
            return
        default:
            break
        }
        HKMLog.info("⌘H：切换内建屏")
        toggleNoBuiltinDisplay()
    }

    /// 按目标状态断/接内建屏，把**真实结果**写进 `builtinCutState`。
    ///
    /// 这里不做「失败了自动回滚」之类的小聪明：用户要的是「没有内建屏」，
    /// 做不到就得让他看见「没断开」，而不是假装做完了。
    func applyBuiltinCut(_ cut: Bool) async {
        guard deps.displayCutter.isAvailable else {
            builtinCutState = .unsupported
            HKMLog.error("这个系统上拿不到断屏接口，内建屏摘不掉")
            return
        }
        let outcome = cut
            ? await deps.displayCutter.disconnect()
            : await deps.displayCutter.reconnect()
        switch outcome {
        case .disconnected, .reconnected, .unchanged:
            // `.unchanged` 是「已经是这个状态了」，不是失败。
            builtinCutState = cut ? .disconnected : .connected
        case .builtinNotFound:
            builtinCutState = .failed(L("找不到内建屏"))
        case .apiUnavailable:
            builtinCutState = .unsupported
        case let .failed(reason):
            builtinCutState = .failed(reason)
        }
        HKMLog.info("内建屏\(cut ? "断开" : "接回") → \(builtinCutState.summary)")
    }

    /// 内建屏又回来了（唤醒、插拔、系统自己重排）就再摘一次。
    ///
    /// 没有这一步，「断开」只能管到下一次睡眠——醒过来系统就把屏装回来了，
    /// 开关看着是勾着的，实际早就失效了。
    private func maintainBuiltinCutIfNeeded() {
        guard settings.noBuiltinDisplay,
              deps.displayCutter.isAvailable,
              deps.displayCutter.isBuiltinActive,
              maintainCutTask == nil else { return }
        maintainCutTask = Task { [weak self] in
            // 系统在拓扑变化的过程中不接受新的显示配置，等它静下来。
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            defer { self.maintainCutTask = nil }
            guard self.settings.noBuiltinDisplay, self.deps.displayCutter.isBuiltinActive else { return }
            let outcome = await self.deps.displayCutter.disconnect()
            HKMLog.info("维持断开内建屏：\(outcome)")
            if case let .failed(reason) = outcome {
                self.builtinCutState = .failed(reason)
            } else {
                self.builtinCutState = .disconnected
            }
        }
    }

    /// 盯着「机器是不是一直醒着」。
    ///
    /// 为什么不是「每次唤醒重新计 10 分钟」：包里的抖动可能每几分钟就唤醒一次，
    /// 每次唤醒都把计时清零的话，计时器永远走不到 10 分钟——恰好是最需要它的
    /// 场景失效。所以这里记的是**连续醒着的累计时长**，只有真的睡过去（两次
    /// 检查之间隔了超过 `sleepGapSeconds`，说明进程被挂起过）才清零。
    private func startStrongModeWatch() {
        stopStrongModeWatch()
        guard settings.strongMode else { return }
        awakeAccumulated = 0
        awakeSeconds = 0
        lastAwakeTick = deps.clock.now
        didWarnRemoteLogin = false
        let tick = max(0.05, timing.strongModeTickSeconds)
        strongModeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
                if Task.isCancelled { return }
                guard let self else { return }
                self.runStrongModeTick()
            }
        }
    }

    private func stopStrongModeWatch() {
        strongModeTask?.cancel()
        strongModeTask = nil
        lastAwakeTick = nil
        awakeAccumulated = 0
        awakeSeconds = 0
        didWarnRemoteLogin = false
    }

    /// 走一拍。后台任务每 `strongModeTickSeconds` 调一次；测试里手动调，
    /// 因为测试用的是假时钟，得自己把时间往前拨。
    func runStrongModeTick() {
        guard settings.strongMode, session?.phase == .away else { return }
        let now = deps.clock.now
        let delta = now.timeIntervalSince(lastAwakeTick ?? now)
        lastAwakeTick = now
        if delta > max(1, timing.sleepGapSeconds) {
            // 进程被挂起过 = 机器真的睡了。醒着时长从头开始。
            if awakeAccumulated > 0 {
                HKMLog.info("增强模式：机器睡过一觉，醒着时长清零")
            }
            awakeAccumulated = 0
            awakeSeconds = 0
            return
        }
        awakeAccumulated += max(0, delta)
        awakeSeconds = Int(awakeAccumulated)
        guard awakeAccumulated >= timing.strongModeIntervalSeconds else { return }
        fireForcedSleep()
    }

    /// 醒够了，提醒 + 倒计时 + 准备动手。
    private func fireForcedSleep() {
        guard countdownPurpose != .forceSleep else { return }
        guard !forcedSleepCheckInFlight else { return }
        guard session?.phase == .away else { return }
        guard sleepOutcome != .requesting else { return }

        // 显示器插着 = 人就在电脑前。这时候强制睡眠是灾难，直接放行。
        guard displaysDetached else {
            HKMLog.info("增强模式：显示器插着，说明人回来了，不强制睡眠")
            awakeAccumulated = 0
            awakeSeconds = 0
            return
        }

        // 这里原本还有一道「内建屏在线就放行」（盖子开着 = 人在电脑前）。
        // 2026-10-25 删掉：用户这台是**物理拆掉内建屏**的残骸，内建屏的在线状态
        // 是 MacHead 用软件伪造出来的，会一会儿有一会儿没有，拿它判「人在不在」
        // 只会乱放行。而且这道门跟「连续醒着 5 分钟」是死结——屏幕亮着就意味着
        // 盖子开着，永远不会放行，这个功能等于不存在。
        //
        // 删掉不危险：他没有内建屏，只能用外接屏。外接屏插着上面已经放行了，
        // 真有人用的时候一定插着屏。

        // `who` 是同步子进程，放到后台去问。查的这段时间里可能已经被别的路径
        // 抢先处理掉了，所以回来之后要把状态再验一遍。
        forcedSleepCheckInFlight = true
        Task { [weak self] in
            guard let self else { return }
            let remote = await self.deps.remote.remoteLogins()
            self.forcedSleepCheckInFlight = false
            self.finishForcedSleepCheck(remote: remote)
        }
    }

    private func finishForcedSleepCheck(remote: [String]) {
        guard countdownPurpose != .forceSleep else { return }
        guard session?.phase == .away else { return }
        guard displaysDetached else { return }

        guard remote.isEmpty else {
            guard !didWarnRemoteLogin else { return }
            didWarnRemoteLogin = true
            HKMLog.info("增强模式：有远程登录（\(remote.joined(separator: "；"))），不强制睡眠")
            deps.notifier.post(
                title: L("没有强制睡眠"),
                body: L("有人正在远程登录这台电脑，怕把对方的工作弄断"),
            )
            return
        }
        didWarnRemoteLogin = false

        let seconds = max(1, timing.strongModeCountdownSeconds)
        HKMLog.info("增强模式：机器已连续醒着 \(Int(awakeAccumulated)) 秒，\(seconds) 秒后强制睡眠")
        // 计数先归零：倒计时被别的路径取消掉时，不会因为「还超着阈值」下一拍又立刻重来。
        awakeAccumulated = 0
        awakeSeconds = 0
        deps.notifier.post(
            title: L("{0} 秒后强制睡眠", seconds),
            // 「要留在电脑前」只对「人回来了」成立。这台机器也常被远程连着用，
            // 那时候人不在电脑前，却说「留在电脑前」——他看完不知道该干嘛。
            body: L("外出模式还开着，机器一直醒着。不想让它睡，就点开无头骑士大师")
        )
        startCountdown(seconds: seconds, purpose: .forceSleep) { [weak self] in
            self?.runForcedSleep()
        }
    }

    /// 「这次不睡」：只放过这一轮，醒着时长归零，10 分钟后再来。
    public func skipForcedSleepOnce() {
        guard countdownPurpose == .forceSleep else { return }
        cancelCountdown()
        countdown = 0
        countdownPurpose = .none
        awakeAccumulated = 0
        awakeSeconds = 0
        lastAwakeTick = deps.clock.now
        HKMLog.info("增强模式：用户点了「这次不睡」，重新计时")
    }

    private func runForcedSleep() {
        countdown = 0
        countdownPurpose = .none
        guard session?.phase == .away else { return }
        awakeAccumulated = 0
        awakeSeconds = 0
        lastAwakeTick = deps.clock.now
        HKMLog.info("增强模式：倒计时结束，强制睡眠")
        Task { await performSleepNow() }
    }

    /// 从拔线页或阻塞页退出来：把机器恢复原样，回首页。
    ///
    /// 阻塞页必须有这条路，否则用户一旦点了「开始外出模式」就再也回不去——
    /// 设置已经被改了，`beginAway` 又因为 `phase == .away` 拒绝重跑。
    public func abortAway() {
        // 用户着急的时候会连点。以前每一下都从头开始还原（日志里六次蓝牙还原），
        // 越点越慢，看着就像按钮坏了。
        guard !isEndingAway else {
            HKMLog.info("正在还原设置，忽略重复点击")
            return
        }
        // 编号一变，正在跑的睡眠验证就作废，不许再把界面拽回拔线页。
        awayGeneration &+= 1
        isEndingAway = true
        cancelCountdown()
        unplugCountdown = nil
        stopUnplugPoll()
        stopStrongModeWatch()
        sleepRetryTask?.cancel()
        sleepRetryTask = nil
        baselineDisplayIDs = []
        readyPageEnteredAt = nil
        displaysDetached = false
        // 这一趟到此为止，别让上一轮留下的「没睡着」跟着用户回首页。
        sleepOutcome = .idle
        errorMessage = nil
        deps.displays.stop()
        Task { [weak self] in
            await self?.restoreAndReturnHome()
            self?.isEndingAway = false
        }
    }

    func restoreAndReturnHome() async {
        stopStrongModeWatch()
        clearPowerLogCache()
        // 回来了，把「防止空闲睡眠」按设置接上。放在最前面：不管是正常结束、
        // 中途取消，还是走了「安全默认值」那条兜底，都要接回来。
        applyIdleSleepSetting()
        guard let state = session else {
            // 内存里没有这次外出的记录（状态文件损坏或被删）。快照丢了，只能按
            // 安全方向还原一次：蓝牙打开、睡眠解锁，别把机器留在睡不着的状态。
            if pendingRestore {
                _ = await restore(snapshot: .safeDefaults)
                pendingRestore = false
                refreshSleepDisabled()
            }
            screen = .home
            iconState = .home
            return
        }
        isBusy = true
        let failures = await restore(snapshot: state.snapshot)
        isBusy = false
        report = nil
        resetCompletedActions()
        failedItems = failures
        screen = .home
        iconState = .home

        guard failures.isEmpty else {
            // 恢复失败时**绝不能**删状态文件：里面那份快照是用户原始设置的唯一
            // 副本。删掉之后下次外出再拍快照，拍到的就是已经被我们改过的值，
            // 从此再也恢复不回来——这是一个会自我固化的错误。
            var updated = state
            updated.phase = .needsRestore
            session = updated
            try? deps.store.saveState(updated)
            pendingRestore = true
            errorMessage = L("有 {0} 项没能恢复：{1}", failures.count, failures.map(\.title).joined(separator: L("、")))
            return
        }
        pendingRestore = false
        try? deps.store.clearState()
        session = nil
    }

    /// 首页那条「上次没恢复完」的横幅点进来的。
    public func retryRestore() {
        guard !isBusy else { return }
        isBusy = true
        Task {
            await restoreAndReturnHome()
            isBusy = false
        }
    }

    // MARK: - Away mode: leaving

    /// 快捷键（⌃⌥⌘E）走的路。
    ///
    /// 和点图标、点面板上那个按钮是**同一条**逻辑，区别只在于它不依赖窗口：
    /// 面板摆错屏、被挡住、按键抢不到焦点的时候，这是唯一的出口。
    public func endAwayByShortcut() {
        HKMLog.info("快捷键：结束外出模式（页面 \(screen)，phase \(session.map { String(describing: $0.phase) } ?? "无记录")）")
        switch screen {
        case .away:
            Task { await finishAway() }
        case .readyToUnplug, .blocked:
            abortAway()
        default:
            // 首页、报告页这些地方按了不该有反应：用户没在外出的路上。
            HKMLog.info("快捷键：当前页面没有可结束的流程，忽略")
        }
    }

    /// 现在按 Ctrl+Opt+Cmd+E 会不会有反应。菜单和日志用它。
    public var canEndAway: Bool {
        switch screen {
        case .away, .readyToUnplug, .blocked: return true
        default: return false
        }
    }

    public func finishAway() async {
        // 每一下都记。2026-11-03 下午他说「触摸板点按了好多下都不行」，日志里
        // 却一个字都没有——分不清是「点没送到界面」还是「送到了被 guard 挡掉」。
        // 这两种是完全不同的毛病，不能猜。
        HKMLog.info("点了「结束外出模式」（phase \(session.map { String(describing: $0.phase) } ?? "无记录")，isBusy \(isBusy)，isEndingAway \(isEndingAway)）")
        guard !isBusy else {
            HKMLog.info("结束外出：正在处理别的动作，这次点击先记下不动")
            return
        }
        guard let state = session, state.phase == .away else {
            // 界面停在外出页，内存里却没有这一趟的记录（状态文件被删、或者上一趟
            // 已经结束）。以前这里直接 return，按钮就成了死的：点什么都没反应，
            // 也不说为什么。现在按「这一趟已经不存在」处理——按安全默认值把机器
            // 还原、回首页，至少不会把蓝牙关着、做梦都睡不了的状态留给用户。
            HKMLog.info("结束外出：没有进行中的记录，按安全默认值还原后回首页")
            isBusy = true
            isEndingAway = true
            await restoreAndReturnHome()
            isEndingAway = false
            isBusy = false
            return
        }
        // 同理：这一趟结束了，后台那条重试通道作废。
        awayGeneration &+= 1
        isBusy = true
        isEndingAway = true
        screen = .auditing
        // 人已经回来了，增强模式立刻收手——统计期间再睡过去会把日志截断。
        stopStrongModeWatch()
        await finishAwayNow(state)
        isEndingAway = false
    }

    /// 审计 + 还原设置 + 出报告。调用方负责置位 `isBusy` 和切到 `auditing`，
    /// 这样「点图标」和「点按钮」两条入口不会各自跑一遍。
    ///
    /// 还原放在这里，不放在报告页那个按钮上。用户点了「结束外出模式」，这一趟
    /// 就该结束：机器回到原样、状态文件清掉，报告只是事后看一眼的东西。以前还原
    /// 挂在「知道了」上，用户看完报告直接把窗口关掉，机器就一直留在「蓝牙关着、
    /// 睡不着的」状态里，而他以为已经结束了。
    private func finishAwayNow(_ state: SessionState) async {
        isBusy = true
        let endedAt = deps.clock.now
        let log = await powerLogForAudit()
        let result = deps.auditor.audit(
            log: log,
            startedAt: state.startedAt,
            endedAt: endedAt,
            displayDetachedAt: state.displayDetachedAt
        )
        let batteryEnd = deps.battery.percentage()
        let rebooted = abs(deps.clock.bootTime() - state.bootTimeAtStart) > 1

        // 先把机器还原，再定稿报告：还原失败也是这一趟的结果，得写进同一份里。
        let restoreFailures = await restore(snapshot: state.snapshot)

        var failedItems = state.snapshot.failedItems
        // 叫它睡它没睡，是这次流程最该说清楚的一件事。
        if state.sleepRequestedAt != nil, !result.sleptAtAll {
            failedItems.append(L("睡眠：请求睡眠后系统没有进入睡眠"))
        }
        failedItems += restoreFailures.map(\.summary)

        let report = Report(
            startedAt: state.startedAt,
            endedAt: endedAt,
            durationSeconds: max(0, Int(endedAt.timeIntervalSince(state.startedAt))),
            batteryStart: state.batteryStart,
            batteryEnd: batteryEnd,
            // 用户回来往往先插电源再点「结束」，那时候电量已经充回去了。
            // 这一趟到底掉了多少电，得看期间见过的最低点。
            batteryLow: state.batteryLow,
            sleptAtAll: result.sleptAtAll,
            darkWakeCount: result.darkWakeCount,
            notificationWakeCount: result.notificationWakeCount,
            realWakeCount: result.realWakeCount,
            realWakes: result.realWakes,
            rebooted: rebooted,
            failedItems: failedItems
        )

        self.report = report
        lastReport = report
        try? deps.store.appendReport(report)

        if restoreFailures.isEmpty {
            settingsRestoredForReport = true
            pendingRestore = false
            // 机器还原了、报告也存好了，这次外出的记录到此为止。
            try? deps.store.clearState()
            session = nil
        } else {
            // 还原失败：状态文件绝不能删，里面那份快照是用户原始设置的唯一副本。
            // 删掉之后下次拍快照，拍到的就是已经被我们改过的值，永远回不去。
            settingsRestoredForReport = false
            var updated = state
            updated.phase = .needsRestore
            updated.lastReport = report
            session = updated
            try? deps.store.saveState(updated)
            pendingRestore = true
            errorMessage = L("有 {0} 项没能恢复：{1}", restoreFailures.count, restoreFailures.map(\.title).joined(separator: L("、")))
        }

        iconState = report.hasAnomaly ? .alert : .home
        stopTicker()
        // 这一趟的日志已经用完了，下一趟重新读。
        clearPowerLogCache()
        isBusy = false
        showDetail = false
        screen = .report
        narrate("→ 报告：\(report.headline)（\(report.durationText)）")
    }

    /// 报告页那个按钮：关掉报告，回首页。
    ///
    /// 设置已经在「结束外出模式」时还原完了，这里不碰系统。唯一的例外是旧版本
    /// 留在磁盘上的 `.audited` 记录——那份记录生成时还原还挂在按钮上，升级后
    /// 第一次打开得替它补一次，否则那台机器会一直停在改过的设置上。
    public func acknowledgeReport() {
        guard !isBusy else { return }
        isBusy = true
        Task { await acknowledgeReportNow() }
    }

    /// 状态文件被外部删掉（用户手动清理、磁盘出错）时，内存里那份也必须一起丢：
    /// 否则「知道了」会拿内存里的快照恢复，看起来成功了，磁盘上其实什么都没有。
    /// 测试用它模拟这种情况。
    func discardSession() {
        session = nil
    }

    func acknowledgeReportNow() async {
        isBusy = true
        defer { isBusy = false }

        if !settingsRestoredForReport {
            let snapshot = session?.snapshot ?? Snapshot.safeDefaults
            var failures = await restore(snapshot: snapshot)
            if session == nil {
                failures.append(FailedItem(title: "状态文件", detail: L("没找到这次外出的记录，已用安全默认值恢复")))
            }

            // 恢复失败也要能被看到：补进刚生成的那份报告里。同一条只记一次——
            // 结束外出时已经写进去的，这里不再重复。
            if !failures.isEmpty, var stored = report ?? lastReport {
                for summary in failures.map(\.summary) where !stored.failedItems.contains(summary) {
                    stored.failedItems.append(summary)
                }
                try? deps.store.updateLastReport(stored)
                lastReport = stored
                report = stored
            }

            failedItems = failures
            guard failures.isEmpty else {
                // 同 abortAway：恢复失败时状态文件必须留着，快照只有这一份。
                if var updated = session {
                    updated.phase = .needsRestore
                    session = updated
                    try? deps.store.saveState(updated)
                }
                pendingRestore = true
                resetCompletedActions()
                screen = .home
                iconState = .home
                showDetail = false
                report = nil
                errorMessage = L("有 {0} 项没能恢复：{1}", failures.count, failures.map(\.title).joined(separator: L("、")))
                return
            }
            settingsRestoredForReport = true
            pendingRestore = false
            try? deps.store.clearState()
            session = nil
        }

        resetCompletedActions()
        screen = .home
        iconState = .home
        showDetail = false
        report = nil
        // 「完成」就是把窗口关掉——这是 macOS 上结果窗口的常规做法，
        // 不用用户再去点一下别处让它消失。
        onDismissReport?()
    }

    /// 报告页被收起（点了别处、切到别的 app）。这一趟已经彻底结束，回首页，
    /// 下次点图标看到的是正常的家，而不是一份旧报告。
    ///
    /// `iconState` 必须一起清掉：红点是「有异常」的意思，用户看完了、窗口都关了，
    /// 图标还挂着红点，等于软件在一直提醒他一件已经处理完的事。
    /// 2026-10-25 用户原话：「即使已经结束外出模式，依然一个红点出现在菜单栏图标上」。
    public func dismissReportIfNeeded() {
        guard screen == .report, !isBusy else { return }
        screen = .home
        iconState = .home
        showDetail = false
        report = nil
    }

    private func restore(snapshot: Snapshot) async -> [FailedItem] {
        var failures: [FailedItem] = []
        failures += await deps.power.restore(snapshot.pmset)
        refreshSleepDisabled()
        if snapshot.bluetoothPower != 0 {
            if let reason = await deps.bluetooth.setPower(true) {
                let detail = FailureText.humanize(reason, severity: .optional)
                failures.append(FailedItem(title: "恢复蓝牙", detail: detail, severity: .optional))
            }
        }
        // 只有真的关过才恢复，否则会把用户本来关着的备份打开。
        if snapshot.timeMachineEnabled == true {
            if let failure = await deps.timeMachine.enable() {
                failures.append(failure)
            }
        }
        failures += await deps.sharing.restore(snapshot.sharing)
        return failures
    }

    // MARK: - Settings actions

    public func toggleLaunchAtLogin() {
        settings.launchAtLogin.toggle()
        do {
            if settings.launchAtLogin {
                try deps.loginItem.enable(executablePath: Bundle.main.executablePath ?? "")
            } else {
                try deps.loginItem.disable()
            }
        } catch {
            settings.launchAtLogin.toggle()
            errorMessage = FailureText.humanize(error.localizedDescription, severity: .optional)
        }
        try? deps.store.saveSettings(settings)
    }

    public func cycleSleepDelay() {
        let options = [3, 5, 10, 30]
        let index = options.firstIndex(of: settings.sleepDelaySeconds) ?? 1
        settings.sleepDelaySeconds = options[(index + 1) % options.count]
        try? deps.store.saveSettings(settings)
    }

    /// 退出。
    ///
    /// 菜单栏 + 无 Dock 图标 + 没有主菜单，以前这软件装上去就没有任何退出入口，
    /// 只能 `kill`。现在设置页有按钮，⌘Q 也能用。
    ///
    /// 退出前必须把机器恢复原样：正处在外出中、或者上次没恢复完，直接退就等于
    /// 把电脑留在一个睡不着的状态里，而用户还以为软件已经关了。
    public func quitApp() {
        guard !isBusy else { return }
        isBusy = true
        Task {
            if session != nil {
                await restoreAndReturnHome()
            }
            isBusy = false
            guard !pendingRestore else {
                // 恢复失败就别退：首页的横幅会说明原因，用户还能再试一次。
                screen = .home
                iconState = .alert
                return
            }
            terminateApplication()
        }
    }

    /// 还有没有「不恢复就不该退出」的状态。`applicationShouldTerminate` 用它决定
    /// 是立刻退还是先恢复。⌘Q、菜单、AppleScript、注销、关机都会走那条路。
    public var needsRestoreBeforeQuit: Bool { session != nil }

    /// 供 `applicationShouldTerminate` 调用：恢复完再告诉系统能不能退。
    func prepareForQuit(_ completion: @escaping @MainActor (Bool) -> Void) {
        Task {
            if session != nil {
                await restoreAndReturnHome()
            }
            if pendingRestore {
                screen = .home
                iconState = .alert
                completion(false)
            } else {
                completion(true)
            }
        }
    }

    // MARK: - 唤醒日志预读

    /// 系统刚醒。趁用户还在插显示器，先把 `pmset -g log` 读进内存。
    public func systemDidWake() {
        // 睡醒之后断言常常已经不在手里了（进程被挂起过、电源域重建）。先核一遍，
        // 这一步不花任何代价。出门期间 `guardIdleSleepTick` 自己会让路。
        guardIdleSleepTick()
        guard session?.phase == .away else { return }
        HKMLog.info("系统唤醒 → 预读唤醒日志")
        warmPowerLog()
        // 机器是被用户叫醒的：把窗口摆出来，让他一眼看到「外出中」和
        // 「结束外出模式」，而不是自己去菜单栏找。
        onSystemWake?()
    }

    /// 系统唤醒时通知界面把窗口叫出来。
    var onSystemWake: (@MainActor () -> Void)?

    /// 报告页点了「完成」：把窗口收起来。
    var onDismissReport: (@MainActor () -> Void)?

    /// 后台读一遍唤醒日志。重复调用会复用正在跑的那次，不会叠着读。
    func warmPowerLog() {
        guard warmPowerLogTask == nil else { return }
        let startedAt = deps.clock.now
        warmPowerLogTask = Task { [weak self] in
            guard let self else { return }
            let text = await self.deps.powerLog.readPowerLog()
            guard !text.isEmpty else {
                self.warmPowerLogTask = nil
                return
            }
            self.cachedPowerLog = text
            self.cachedPowerLogAt = startedAt
            self.warmPowerLogTask = nil
            HKMLog.info("唤醒日志已预读（\(text.count) 字符）")
        }
    }

    /// 结束外出时用哪份日志：预读的够新就用，否则老老实实读一遍。
    private func powerLogForAudit() async -> String {
        if let text = cachedPowerLog, let at = cachedPowerLogAt,
           deps.clock.now.timeIntervalSince(at) <= timing.powerLogCacheSeconds {
            HKMLog.info("用预读的唤醒日志，省掉这次等待")
            return text
        }
        return await deps.powerLog.readPowerLog()
    }

    private func clearPowerLogCache() {
        warmPowerLogTask?.cancel()
        warmPowerLogTask = nil
        cachedPowerLog = nil
        cachedPowerLogAt = nil
    }

    // MARK: - Ticker / timers

    private func startTicker() {
        stopTicker()
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.now = self.deps.clock.now
                self.batteryNow = self.deps.battery.percentage()
                self.recordBatteryLow()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// 记下外出期间见过的最低电量。
    ///
    /// 只存首尾是不够的：用户回来第一件事往往是插电源，等他把「结束外出模式」
    /// 点下去，电池早就充回去了，报告就会写「没有掉电」。2026-10-25 那趟
    /// 睡了一夜掉 2%（98%→96%），结束时已经充回 98%。
    ///
    /// 每掉一个百分点才写一次盘，一晚也就几次。
    private func recordBatteryLow() {
        guard var current = session, let battery = batteryNow else { return }
        if let low = current.batteryLow, low <= battery { return }
        current.batteryLow = battery
        session = current
        try? deps.store.saveState(current)
    }

    private func stopTicker() {
        tickerTask?.cancel()
        tickerTask = nil
    }

    private func observeDisplaysForReturn() {
        deps.displays.setHandler { [weak self] count in
            self?.handleDisplayChange(count)
        }
        deps.displays.start()
    }

    private func startCountdown(seconds: Int, purpose: CountdownPurpose, then action: @escaping @MainActor () -> Void) {
        cancelCountdown()
        countdown = seconds
        countdownTotal = seconds
        countdownPurpose = purpose
        if purpose == .unplug {
            unplugCountdown = seconds
        }
        let tick = timing.countdownTick
        countdownTask = Task { [weak self] in
            var remaining = seconds
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(max(0, tick) * 1_000_000_000))
                if Task.isCancelled { return }
                remaining -= 1
                guard let self else { return }
                self.countdown = remaining
                if self.countdownPurpose == .unplug {
                    self.unplugCountdown = remaining
                }
            }
            if Task.isCancelled { return }
            action()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = 0
        if countdownPurpose == .unplug {
            unplugCountdown = nil
        }
        countdownPurpose = .none
    }

    // MARK: - Helpers

    /// 首页那句「系统可以正常睡眠」得是真的：`disablesleep=1` 时它并不真。
    private func refreshSleepDisabled() {
        sleepDisabled = ((try? deps.power.readSnapshot())?["disablesleep"] ?? 0) == 1
    }

    private func narrate(_ line: String) {
        // 以前只往终端打，从 Finder 启动时全丢了——无头机出问题就一点线索都没有。
        // 现在每一步都进日志文件，下次再失败不用靠猜。
        HKMLog.info(line)
        narrator?(line)
    }
}

private extension SleepBlocker {
    /// 同一个 App 的不同进程也要算「还在」：Chrome 有多个 PID。
    func sameProcess(as other: SleepBlocker) -> Bool {
        if let lhs = bundleIdentifier, let rhs = other.bundleIdentifier {
            return lhs == rhs
        }
        return processName == other.processName
    }
}
