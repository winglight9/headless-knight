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
    @Published public private(set) var completedActions: [String] = []
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
    /// 强力模式：外出期间机器已经连续醒着多少秒。真睡过去一次就归零。
    @Published public private(set) var awakeSeconds: Int = 0
    /// 设置页里如实显示的通知状态。
    @Published public private(set) var notificationStatus: String = "…"
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
    /// 进拔线页那一刻每块屏的厂商/型号。影子屏会沿用 ID，但认不出 EDID。
    private var baselineSnapshots: [DisplayWatcher.DisplaySnapshot] = []
    private var countdownPurpose: CountdownPurpose = .none
    private var didNotifyReturn = false
    private var didMarkDetached = false
    /// 睡眠失败后，必须先把显示器插回来再拔，才允许重新自动倒计时——
    /// 否则用户看着「没睡成」的提示，后台已经在无限重试。
    private var awaitingDisplayReturnForRetry = false
    /// 扫描本身失败时留一条记录，报告里要能看出这次没检查过。
    private var scanIssue: FailedItem?

    // MARK: - 强力模式的状态

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

    /// 强力模式的倒计时还剩几秒。没在倒计时就是 nil。
    public var forceSleepCountdown: Int? {
        countdownPurpose == .forceSleep ? countdown : nil
    }

    private enum CountdownPurpose {
        case none
        case unplug
        /// 强力模式的「N 秒后强制睡眠」。
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

    /// 强力模式那句「机器已经醒着 X 分钟」。只说我们真的在算的事。
    public var awakeMinutesText: String {
        let minutes = max(0, awakeSeconds) / 60
        if minutes < 1 {
            return "\(max(0, awakeSeconds)) 秒"
        }
        return "\(minutes) 分钟"
    }

    public var batteryDropText: String {
        guard let start = session?.batteryStart, let current = batteryNow else {
            return "电量读取中"
        }
        let delta = start - current
        if delta <= 0 {
            return "\(current)% · 没有下降"
        }
        return "\(current)% · 下降 \(delta)%"
    }

    public var batteryFillRatio: Double {
        Double(batteryNow ?? 0) / 100.0
    }

    public var isAwayPhase: Bool {
        session?.phase == .away
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

    public var sleepDelaySeconds: Int { settings.sleepDelaySeconds }

    public var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return version ?? "1.0"
    }

    public var launchAtLoginText: String {
        settings.launchAtLogin ? "已开机自启 · 无 Dock 图标" : "未开机自启 · 无 Dock 图标"
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
        helperInstalled = deps.helper.isInstalled
        displayCount = deps.displays.activeDisplayCount()
        batteryNow = deps.battery.percentage()
        now = deps.clock.now
        refreshSleepDisabled()

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
            // 重启后接着盯：强力模式不该因为重启就失效。
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
        do {
            try deps.helper.install()
            helperInstalled = deps.helper.isInstalled
            needsHelperInstall = !helperInstalled
            if helperInstalled {
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
    }

    /// 通知到底能不能弹。设置页每次打开都重新问一遍系统，不缓存。
    public func refreshNotificationStatus() {
        Task { [weak self] in
            guard let self else { return }
            self.notificationStatus = await self.deps.notifier.authorizationSummary()
        }
    }

    /// 「试一下」：让用户当场看见通知长什么样，而不是等到出门在外才发现没弹。
    public func sendTestNotification() {
        deps.notifier.post(
            title: "通知是通的",
            body: "强力模式到点时会这样提醒你：30 秒后强制睡眠。"
        )
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
        completedActions = []
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
        // 进度清单从零开始：这个流程可能因为装了后台服务而重跑一遍。
        completedActions = []

        // L1 first: without this nothing else matters.
        step("锁定睡眠设置")
        let powerFailures = await deps.power.applyAwaySettings(
            current: snapshot.pmset,
            cancelScheduledWakes: !snapshot.scheduledWake.isEmpty
        )
        failures += powerFailures
        if powerFailures.isEmpty {
            done("锁定了睡眠设置")
        } else {
            done("睡眠设置没写全")
        }
        narrate(describePowerStep(snapshot: snapshot.pmset, failures: powerFailures))

        // TEMP-PREVIEW：本地截图核对时放慢，核对完删掉。
        if FileManager.default.fileExists(atPath: "/tmp/hkm_slow") {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
        }


        // Time Machine 是优化项：没开备份就直接跳过，没关成也不许阻断。
        step("暂停 Time Machine")
        let timeMachineOutcome = await deps.timeMachine.disable()
        snapshot.timeMachineEnabled = timeMachineOutcome.didDisable
        if let failure = timeMachineOutcome.failure {
            failures.append(failure)
            narrate("[3/8] 暂停 Time Machine… ✗ \(failure.detail)")
        } else if timeMachineOutcome.didDisable {
            done("暂停了 Time Machine")
            narrate("[3/8] 暂停 Time Machine… ✓")
        } else {
            narrate("[3/8] 暂停 Time Machine… 跳过（无备份目标）")
        }

        step("关闭共享服务")
        let sharingFailures = await deps.sharing.disableAll()
        failures += sharingFailures
        if !snapshot.sharing.isEmpty, sharingFailures.isEmpty {
            done("关闭了共享服务")
        }
        narrate(
            sharingFailures.isEmpty
                ? "[4/8] 关闭共享服务… \(snapshot.sharing.isEmpty ? "跳过（本来就没开）" : "✓")"
                : "[4/8] 关闭共享服务… ✗ 不影响睡眠"
        )

        step("关闭蓝牙")
        if snapshot.bluetoothPower == 0 {
            done("蓝牙本来就关着")
            narrate("[5/8] 关闭蓝牙… 跳过（本来就关着）")
        } else if let reason = await deps.bluetooth.setPower(false) {
            let detail = FailureText.humanize(reason, severity: .critical)
            failures.append(FailedItem(title: "蓝牙", detail: detail))
            narrate("[5/8] 关闭蓝牙… ✗ \(detail)")
        } else {
            done("关闭了蓝牙")
            narrate("[5/8] 关闭蓝牙… ✓")
        }

        // L2: quit the processes that hold sleep assertions.
        step("退出阻止睡眠的程序")
        let killResult = await killAll()
        killedCount = killResult.count
        failures += killResult.failures
        if !killResult.failures.isEmpty {
            blockers = killResult.remaining
        }
        done(killResult.count > 0 ? "关闭了 \(killResult.count) 个程序" : "没有程序在阻止睡眠")
        narrate(killResult.narration)

        step("关闭网络唤醒")
        let wompFailed = failures.contains { $0.title == "睡眠设置 womp" }
        if snapshot.pmset["womp"] == 0 {
            done("网络唤醒本来就关着")
            narrate("[7/8] 关闭网络唤醒… 跳过（本来就关着）")
        } else if !wompFailed {
            done("关闭了网络唤醒")
            narrate("[7/8] 关闭网络唤醒… ✓")
        } else {
            narrate("[7/8] 关闭网络唤醒… ✗")
        }

        snapshot.failedItems = failures.map(\.summary)
        state.snapshot = snapshot
        session = state
        try? deps.store.saveState(state)

        failedItems = failures
        needsHelperInstall = !deps.helper.isInstalled && failures.contains { $0.detail.contains("后台服务") }

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
                    FailedItem(title: blocker.processName, detail: "退出后又自己起来了，还在阻止睡眠")
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
            if !completedActions.contains("关闭了蓝牙") {
                completedActions.append("关闭了蓝牙")
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
                let summary = "关闭了 \(killedCount) 个程序"
                if let index = completedActions.firstIndex(where: {
                    $0.hasPrefix("关闭了") && $0.hasSuffix("个程序") || $0 == "没有程序在阻止睡眠"
                }) {
                    completedActions[index] = summary
                } else {
                    completedActions.append(summary)
                }
                enterReadyToUnplug()
            } else {
                blockers = left
                failedItems = failedItems.filter { !$0.isCritical } + left.map {
                    FailedItem(title: $0.processName, detail: "无法自动退出，它还在阻止睡眠。请手动退出这个程序。")
                }
            }
        } catch {
            errorMessage = FailureText.humanize(error.localizedDescription, severity: .critical)
        }
    }

    /// 阻塞页上的「安装后台服务」。
    public func installHelperFromBlocked() {
        guard !isBusy else { return }
        isBusy = true
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
        awaitingDisplayReturnForRetry = false
        displayCount = deps.displays.activeDisplayCount()
        baselineDisplayIDs = deps.displays.onlineDisplayIDs()
        baselineSnapshots = deps.displays.displaySnapshots()
        displaysDetached = isDisplayDetached()
        HKMLog.info("进入拔线页：当前显示器 \(displayCount) 个，基线 \(baselineDisplayIDs)（\(deps.displays.describeDisplays())），主屏 \(deps.displays.mainDisplayID())")
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

    /// 用户让我拔的那块屏，现在还在不在。
    ///
    /// 只看 `online`，不看 `active`：显示器休眠（DPMS）时 active 会变 false 但
    /// online 仍然是 true，那样会把「屏幕自动关了」误判成「线拔了」，把正在用的
    /// 机器弄睡。
    private func isDisplayDetached() -> Bool {
        let now = deps.displays.onlineDisplayIDs()
        if now.isEmpty { return true }
        guard !baselineDisplayIDs.isEmpty else {
            // 进页面时就已经一块屏都没有了，只能退回数量判断。
            return deps.displays.activeDisplayCount() == 0
        }
        if !Set(baselineDisplayIDs).isSubset(of: Set(now)) { return true }
        // 影子屏有可能沿用同一个 ID，这时只能看它的身份有没有变。
        // 真屏的厂商/型号是刻在 EDID 里的，显示器休眠、改分辨率都不会变。
        guard !baselineSnapshots.isEmpty else { return false }
        let current = Dictionary(
            deps.displays.displaySnapshots().map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for base in baselineSnapshots {
            guard base.vendor != 0 || base.model != 0 else { continue }
            guard let now = current[base.id] else { return true }
            if now.vendor != base.vendor || now.model != base.model { return true }
        }
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
                let count = self.deps.displays.activeDisplayCount()
                let detached = self.isDisplayDetached()
                if detached || count != self.displayCount {
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
        let detached = isDisplayDetached()
        displaysDetached = detached
        switch screen {
        case .readyToUnplug:
            if detached {
                if awaitingDisplayReturnForRetry {
                    narrate("[8/8] 显示器又断了，但上次没睡成，等你手动重试")
                } else if unplugCountdown == nil {
                    narrate("[8/8] 等待拔线… 基线里的显示器已断开")
                    markDetachedAndCountdown()
                }
            } else {
                // 显示器回来了（或者只是休眠又醒）：倒计时必须取消，绝不硬睡。
                if unplugCountdown != nil {
                    narrate("[8/8] 显示器插回来了，取消睡眠倒计时")
                    cancelCountdown()
                }
                awaitingDisplayReturnForRetry = false
            }
        case .away:
            if !detached, !didNotifyReturn {
                didNotifyReturn = true
                deps.notifier.post(title: "欢迎回来", body: "别忘了结束外出模式")
            }
        default:
            break
        }
    }

    private func markDetachedAndCountdown() {
        guard unplugCountdown == nil, !awaitingDisplayReturnForRetry else { return }
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
        Task { await performSleepNow() }
    }

    /// 「再试一次睡眠」：用户在拔线页上手动点。
    public func retrySleep() {
        guard !isBusy else { return }
        isBusy = true
        Task {
            await performSleepNow()
            isBusy = false
        }
    }

    func performSleepNow() async {
        await performSleepNow(fromWatchdog: false)
    }

    /// `fromWatchdog`：后台重试自己调进来的时候不要再起一个新的看门狗，
    /// 否则 `startSleepRetryWatchdog()` 会把正在跑的那个（也就是它自己）取消掉，
    /// 结果只重试一次就停了。
    private func performSleepNow(fromWatchdog: Bool) async {
        unplugCountdown = nil
        cancelCountdown()
        guard sleepOutcome != .requesting else { return }
        sleepOutcome = .requesting
        errorMessage = nil

        // 记下「我们叫它睡了」的时刻，回来才知道它到底睡没睡。
        let requestedAt = deps.clock.now
        if var updated = session {
            updated.sleepRequestedAt = requestedAt
            session = updated
            try? deps.store.saveState(updated)
        }
        HKMLog.info("请求系统睡眠（当前显示器 \(displayCount) 个）")

        var lastReason: String?
        var slept = false

        // 显示器还插着的时候，「让系统睡眠」实际发生的是：屏幕黑一下 → WindowServer
        // 立刻抓一个 PreventSystemSleep 把系统拽回来 → 屏幕又亮。连试三次就是连闪
        // 三下，用户的原话是「反复黑屏亮屏」。
        //
        // 所以这种情况下只试一次：成不成一次就看出来了，第二次只是再闪一下。
        // 真拔了线之后（自动流程）没有屏幕可闪，多试几次才有意义。
        let displayStillAttached = !isDisplayDetached()
        let maxAttempts = displayStillAttached ? 1 : 3

        for attempt in 1...maxAttempts {
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

            do {
                try await deps.power.sleepNow()
                narrate("→ 第 \(attempt) 次请求睡眠")
            } catch {
                lastReason = FailureText.humanize(error.localizedDescription, severity: .critical)
                narrate("→ 请求睡眠失败：\(lastReason ?? "")")
            }

            // 真睡了的话，这段等待是在挂起状态下过去的，检查会在唤醒之后才继续，
            // 那时日志里必然已经有 Entering Sleep。
            try? await Task.sleep(nanoseconds: UInt64(max(0, timing.sleepVerifySeconds) * 1_000_000_000))
            if await deps.power.didEnterSleep(since: requestedAt) {
                slept = true
                HKMLog.info("确认已进入睡眠（第 \(attempt) 次请求）")
                break
            }
            let holders = await deps.power.systemSleepBlockers()
            lastReason = holders.isEmpty
                ? "系统没有进入睡眠"
                : "\(holders.joined(separator: "、")) 占着系统睡眠"
            HKMLog.error("第 \(attempt) 次请求后系统仍然醒着：\(lastReason ?? "")")
        }

        if slept {
            sleepOutcome = .slept
            stopUnplugPoll()
            // 这一趟真的睡着了，醒着时长从零开始算；强力模式从这里接手。
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
                deps.notifier.post(title: "欢迎回来", body: "别忘了结束外出模式")
            }
            startTicker()
            return
        }

        // 没睡成：绝不切到「外出中」，也绝不说「系统已进入睡眠」。
        let reason = lastReason ?? "系统拒绝了睡眠请求"
        sleepOutcome = .failed(reason: reason)
        awaitingDisplayReturnForRetry = true
        if screen != .auditing && screen != .report {
            screen = .readyToUnplug
            iconState = .alert
        }
        // 「系统没有进入睡眠」这句是循环论证，用户看完还是不知道为什么。
        // 屏幕还插着的时候原因其实很确定：刚睡下就被屏幕的重新配置拽回来了。
        errorMessage = displayStillAttached
            ? "显示器还插着，系统刚睡下就被叫醒了。拔掉线之后它会自己睡"
            : "没能让电脑睡着：\(reason)"
        narrate("→ 睡眠失败：\(reason)")
        deps.notifier.post(title: "没能进入睡眠", body: "电脑还醒着：\(reason)")
        if !fromWatchdog {
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

    // MARK: - 强力模式

    /// 强力模式开关。只在设置页里改。
    public func toggleStrongMode() {
        settings.strongMode.toggle()
        try? deps.store.saveSettings(settings)
        HKMLog.info("强力模式：\(settings.strongMode ? "开" : "关")")
        if settings.strongMode {
            startStrongModeWatch()
        } else {
            stopStrongModeWatch()
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
                HKMLog.info("强力模式：机器睡过一觉，醒着时长清零")
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
            HKMLog.info("强力模式：显示器插着，说明人回来了，不强制睡眠")
            awakeAccumulated = 0
            awakeSeconds = 0
            return
        }

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
            HKMLog.info("强力模式：有远程登录（\(remote.joined(separator: "；"))），不强制睡眠")
            deps.notifier.post(
                title: "没有强制睡眠",
                body: "有人正在远程登录这台电脑，怕把对方的工作弄断。"
            )
            return
        }
        didWarnRemoteLogin = false

        let seconds = max(1, timing.strongModeCountdownSeconds)
        HKMLog.info("强力模式：机器已连续醒着 \(Int(awakeAccumulated)) 秒，\(seconds) 秒后强制睡眠")
        // 计数先归零：倒计时被别的路径取消掉时，不会因为「还超着阈值」下一拍又立刻重来。
        awakeAccumulated = 0
        awakeSeconds = 0
        deps.notifier.post(
            title: "\(seconds) 秒后强制睡眠",
            body: "外出模式还开着，机器一直醒着。要留在电脑前，就点开无头骑士大师。"
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
        HKMLog.info("强力模式：用户点了「这次不睡」，重新计时")
    }

    private func runForcedSleep() {
        countdown = 0
        countdownPurpose = .none
        guard session?.phase == .away else { return }
        awakeAccumulated = 0
        awakeSeconds = 0
        lastAwakeTick = deps.clock.now
        HKMLog.info("强力模式：倒计时结束，强制睡眠")
        Task { await performSleepNow() }
    }

    /// 从拔线页或阻塞页退出来：把机器恢复原样，回首页。
    ///
    /// 阻塞页必须有这条路，否则用户一旦点了「开始外出模式」就再也回不去——
    /// 设置已经被改了，`beginAway` 又因为 `phase == .away` 拒绝重跑。
    public func abortAway() {
        cancelCountdown()
        unplugCountdown = nil
        stopUnplugPoll()
        stopStrongModeWatch()
        sleepRetryTask?.cancel()
        sleepRetryTask = nil
        baselineDisplayIDs = []
        baselineSnapshots = []
        displaysDetached = false
        deps.displays.stop()
        Task { await restoreAndReturnHome() }
    }

    func restoreAndReturnHome() async {
        stopStrongModeWatch()
        clearPowerLogCache()
        guard let state = session else {
            screen = .home
            iconState = .home
            return
        }
        isBusy = true
        let failures = await restore(snapshot: state.snapshot)
        isBusy = false
        report = nil
        completedActions = []
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
            errorMessage = "有 \(failures.count) 项没能恢复：\(failures.map(\.title).joined(separator: "、"))"
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

    public func finishAway() async {
        guard let state = session, state.phase == .away, !isBusy else { return }
        isBusy = true
        screen = .auditing
        // 人已经回来了，强力模式立刻收手——统计期间再睡过去会把日志截断。
        stopStrongModeWatch()
        await finishAwayNow(state)
    }

    /// 审计 + 出报告。调用方负责置位 `isBusy` 和切到 `auditing`，
    /// 这样「点图标」和「点按钮」两条入口不会各自跑一遍。
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

        var failedItems = state.snapshot.failedItems
        // 叫它睡它没睡，是这次流程最该说清楚的一件事。
        if state.sleepRequestedAt != nil, !result.sleptAtAll {
            failedItems.append("睡眠：请求睡眠后系统没有进入睡眠")
        }

        let report = Report(
            startedAt: state.startedAt,
            endedAt: endedAt,
            durationSeconds: max(0, Int(endedAt.timeIntervalSince(state.startedAt))),
            batteryStart: state.batteryStart,
            batteryEnd: batteryEnd,
            sleptAtAll: result.sleptAtAll,
            darkWakeCount: result.darkWakeCount,
            notificationWakeCount: result.notificationWakeCount,
            realWakeCount: result.realWakeCount,
            realWakes: result.realWakes,
            rebooted: rebooted,
            failedItems: failedItems
        )

        self.report = report
        var updated = state
        updated.phase = .audited
        updated.lastReport = report
        session = updated
        try? deps.store.saveState(updated)
        try? deps.store.appendReport(report)
        lastReport = report
        iconState = report.hasAnomaly ? .alert : .home
        stopTicker()
        // 这一趟的日志已经用完了，下一趟重新读。
        clearPowerLogCache()
        isBusy = false
        showDetail = false
        screen = .report
        narrate("→ 报告：\(report.headline)（\(report.durationText)）")
    }

    /// 「知道了」: put the machine back the way it was.
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
        let snapshot = session?.snapshot ?? Snapshot.safeDefaults
        var failures = await restore(snapshot: snapshot)
        if session == nil {
            failures.append(FailedItem(title: "状态文件", detail: "没找到这次外出的记录，已用安全默认值恢复"))
        }

        // 恢复失败也要能被看到：补进刚生成的那份报告里。
        if !failures.isEmpty, var stored = report ?? lastReport {
            stored.failedItems += failures.map(\.summary)
            try? deps.store.updateLastReport(stored)
            lastReport = stored
            report = stored
        }

        failedItems = failures
        completedActions = []
        screen = .home
        iconState = .home
        showDetail = false

        guard failures.isEmpty else {
            // 同 abortAway：恢复失败时状态文件必须留着，快照只有这一份。
            if var updated = session {
                updated.phase = .needsRestore
                session = updated
                try? deps.store.saveState(updated)
            }
            pendingRestore = true
            report = nil
            errorMessage = "有 \(failures.count) 项没能恢复：\(failures.map(\.title).joined(separator: "、"))"
            return
        }

        pendingRestore = false
        try? deps.store.clearState()
        session = nil
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
        guard session?.phase == .away else { return }
        HKMLog.info("系统唤醒 → 预读唤醒日志")
        warmPowerLog()
        // 机器是被用户叫醒的：把窗口摆出来，让他一眼看到「外出中」和
        // 「结束外出模式」，而不是自己去菜单栏找。
        onSystemWake?()
    }

    /// 系统唤醒时通知界面把窗口叫出来。
    var onSystemWake: (@MainActor () -> Void)?

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
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
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
