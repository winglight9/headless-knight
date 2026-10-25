import CoreGraphics
import Foundation
import HKMKit

/// 一套完全内存化的依赖，给 `--simulate-away` 和端到端测试共用。
///
/// 之所以放在 app target 而不是测试目录：模拟器必须和测试跑同一份替身，
/// 否则「模拟器里能过、测试里过不了」这种事迟早会发生。
@MainActor
final class SimulatedServices: ProcessScanning, ProcessKilling, PowerControlling,
    BluetoothControlling, BatteryReading, SharingControlling, TimeMachineControlling,
    DisplayWatching, StateStoring, Notifying, LoginItemManaging, PowerLogReading,
    HelperManaging, RemoteSessionChecking, SystemClock {

    // MARK: - 可调参数

    var blockers: [SleepBlocker] = []
    var systemBlockerCount: Int = 0
    /// 名字 → 退出结果。没配置的按 .terminated。
    var killOutcomes: [String: KillOutcome] = [:]
    /// 退出之后又被 launchd 拉起来。
    var respawnsAfterKill = false

    var pmsetValues = PmsetSnapshot(values: [
        "disablesleep": 1, "sleep": 0, "displaysleep": 10,
        "womp": 1, "powernap": 1, "tcpkeepalive": 1, "standby": 1
    ])
    /// 这些键写入时失败。
    var failingPmsetKeys: Set<String> = []
    /// 恢复时失败的键。
    var failingRestoreKeys: Set<String> = []

    var bluetoothState: Int? = 1
    var bluetoothSetFailure: String?

    var sharingLabels: [String] = []
    var sharingFailure: String?

    var timeMachineIsOn: Bool? = nil
    var timeMachineDisableFailure: String?
    var timeMachineEnableFailure: String?

    var helperInstalled = true
    var helperInstallSucceeds = true

    var batteryLevel: Int? = 90
    var displayCountValue = 1
    /// 还插着的显示器 ID / 主显示器 ID。拔没拔看这两个，不看数量。
    var onlineIDs: [CGDirectDisplayID] = [1]
    var mainID: CGDirectDisplayID = 1
    /// 这些 ID 是影子屏：还挂在 online 列表里，但厂商/型号是 0。
    var phantomIDs: Set<CGDirectDisplayID> = []
    /// 这些 ID 是**虚拟屏**：MacHead、UU 远程这类软件建的，或者拔线之后系统
    /// 留下的空壳。厂商号/型号是把某个字符串当整数塞进来的乱码。
    /// 真机上抓到的值是 v1970170734/m1986622068/s0。
    var virtualIDs: Set<CGDirectDisplayID> = []
    /// 这些 ID 是内建屏。拔线基线只记外接屏，所以这里必须分得出来。
    var builtinIDs: Set<CGDirectDisplayID> = []
    /// 内建屏亮着（笔记本盖子开着）。默认关着，就是「无头」那台机器。
    var builtinIsOnline = false

    var powerLog = ""
    /// `readPowerLog()` 被调了几次。用来验证「预读过就不再读第二遍」。
    var powerLogReads = 0
    var bootTimeValue: TimeInterval = 1_000
    var currentDate = Date(timeIntervalSince1970: 1_760_000_000)
    /// 谁在远程登录。非空时强力模式必须让路。
    var remoteLoginsValue: [String] = []

    var sleepNowFails: String?
    /// `pmset sleepnow` 调用成功，但系统其实没睡。
    var sleepSucceeds = true
    /// 睡眠验证的答案。默认 `.awake`：`sleepSucceeds = false` 的老测试都靠这个
    /// 表达「叫了但它没睡」。`.unknown` 用来复现「读不到电源日志」。
    var sleepEvidenceValue: PowerSettings.SleepEvidence = .awake
    /// 每次 `sleepnow` 之后时间往前走多少秒。
    ///
    /// 用来复现「机器真的睡了」：进程挂起，醒来时墙上时钟已经跳了几个小时。
    /// 这是 `AppState` 判断「真睡了」的第一依据，也是 2026-10-25 那次误报的
    /// 正解——日志读不出来，但时间确实跳了 96 分钟。
    var advanceClockOnSleepNow: TimeInterval = 0
    /// 持有 PreventSystemSleep 的进程名。
    var sleepBlockers: [String] = []
    var storedSettings = AppSettings(onboardingDone: true, launchAtLogin: false, sleepDelaySeconds: 5)
    var storedState: SessionState?
    var storedReports: [Report] = []
    var loginItemEnabled = false

    // MARK: - 观测点

    private(set) var events: [String] = []
    private(set) var pmsetWrites: [(key: String, value: Int)] = []
    private(set) var sleepNowCalls = 0
    private(set) var savedStates: [SessionState] = []
    private(set) var clearedStateCount = 0
    private(set) var notifications: [String] = []
    private(set) var helperInstallAttempts = 0

    private var displayHandler: (@MainActor @Sendable (Int) -> Void)?
    private(set) var displayWatcherRunning = false

    private func record(_ event: String) {
        events.append(event)
    }

    // MARK: - 测试驱动

    /// 模拟用户拔掉/插回显示器。
    func simulateDisplayCount(_ count: Int) {
        if count == 0 {
            simulateDisplayState(active: 0, online: [], main: 0)
        } else {
            simulateDisplayState(
                active: count,
                online: (0..<count).map { CGDirectDisplayID(1 + $0) },
                main: 1
            )
        }
    }

    /// 直接把「系统现在报告什么」设成任意组合，用来复现真实机器上的怪状态。
    func simulateDisplayState(active: Int, online: [CGDirectDisplayID], main: CGDirectDisplayID) {
        displayCountValue = active
        onlineIDs = online
        mainID = main
        phantomIDs = []
        displayHandler?(active)
    }

    /// 复现 2026-10-24 09:41 那次：显示器确实拔了，但系统留了一块影子屏，
    /// `activeDisplayCount` 仍然是 1，只有 ID 换了。
    func simulatePhantomDisplayAfterUnplug() {
        simulateDisplayState(active: 1, online: [99], main: 99)
    }

    /// 更阴的一种：影子屏沿用了原来那块屏的 ID，只有厂商/型号变成 0。
    /// 只比 ID 的话这种就漏了。
    func simulatePhantomWithSameID() {
        simulateDisplayState(active: 1, online: [1], main: 1)
        phantomIDs = [1]
        // 拔线时系统会连报好几次拓扑变化，影子屏是后面那几次才现形的。
        displayHandler?(1)
    }

    func advanceClock(by seconds: TimeInterval) {
        currentDate = currentDate.addingTimeInterval(seconds)
    }

    // MARK: - ProcessScanning

    func scan() async throws -> BlockerScanResult {
        BlockerScanResult(
            blockers: blockers,
            systemEntries: Array(repeating: systemPlaceholder, count: systemBlockerCount)
        )
    }

    private var systemPlaceholder: SleepBlocker {
        SleepBlocker(pid: 1, processName: "powerd", isSystemProcess: true)
    }

    // MARK: - ProcessKilling

    func kill(_ blocker: SleepBlocker) async -> KillOutcome {
        record("kill \(blocker.processName)")
        let outcome = killOutcomes[blocker.processName] ?? .terminated
        guard outcome.isSuccess else { return outcome }
        // 真被关掉的进程要从扫描结果里消失，否则「退出后重新扫一遍」会误判。
        blockers.removeAll { $0.pid == blocker.pid }
        if respawnsAfterKill {
            // 退出后马上回来，PID 变了但名字没变。
            blockers.append(
                SleepBlocker(
                    pid: blocker.pid + 1,
                    processName: blocker.processName,
                    bundleIdentifier: blocker.bundleIdentifier,
                    assertionTypes: blocker.assertionTypes
                )
            )
        }
        return outcome
    }

    // MARK: - PowerControlling

    func readSnapshot() throws -> PmsetSnapshot {
        pmsetValues
    }

    func readSnapshotAsync() async throws -> PmsetSnapshot {
        pmsetValues
    }

    func scheduledWakes() -> [String] {
        ["wake at 10/24/2026 07:00:00 by 'com.apple.alarm'"]
    }

    func applyAwaySettings(current: PmsetSnapshot?, cancelScheduledWakes: Bool) async -> [FailedItem] {
        // 后台服务没装时真实实现第一次 root 操作就会抛 notInstalled，
        // 而且剩下的键也没必要再试——这里照着真实的短路行为模拟。
        guard helperInstalled else {
            record("pmset ✗ 后台服务没装")
            return [
                FailedItem(
                    title: "睡眠设置",
                    detail: FailureText.humanize(HelperError.notInstalled.localizedDescription, severity: .critical),
                    severity: .critical
                )
            ]
        }
        var failures: [FailedItem] = []
        for target in PowerSettings.awayTargets {
            if let current, current[target.key] == target.value { continue }
            if failingPmsetKeys.contains(target.key) {
                record("pmset \(target.key) ✗")
                failures.append(
                    FailedItem(
                        title: "睡眠设置 \(target.key)",
                        detail: FailureText.humanize("Operation not permitted", severity: .critical),
                        severity: .critical
                    )
                )
                continue
            }
            pmsetValues[target.key] = target.value
            pmsetWrites.append((target.key, target.value))
            record("pmset \(target.key)=\(target.value)")
        }
        return failures
    }

    func restore(_ snapshot: PmsetSnapshot) async -> [FailedItem] {
        var failures: [FailedItem] = []
        for key in PmsetSnapshot.trackedKeys {
            guard let value = snapshot[key] else { continue }
            if failingRestoreKeys.contains(key) {
                record("restore \(key) ✗")
                failures.append(
                    FailedItem(
                        title: "恢复 \(key)",
                        detail: FailureText.humanize("Operation not permitted", severity: .optional),
                        severity: .optional
                    )
                )
                continue
            }
            pmsetValues[key] = value
            record("restore \(key)=\(value)")
        }
        return failures
    }

    func sleepNow() async throws {
        sleepNowCalls += 1
        record("sleepNow")
        // 真机上这段等待是在挂起中过去的，醒来时墙上时钟已经跳过去了。
        if advanceClockOnSleepNow > 0 {
            advanceClock(by: advanceClockOnSleepNow)
        }
        if let sleepNowFails {
            throw SimulatedError(message: sleepNowFails)
        }
    }

    /// 系统到底睡没睡。`sleepSucceeds = false` 用来复现「叫了但没睡」。
    func sleepEvidence(since: Date) async -> PowerSettings.SleepEvidence {
        // 读电源日志本身要几秒，机器可能就在这几秒里睡过去了。2026-10-25 10:47
        // 的误报正是这么发生的：判完「没睡」去读日志，进程被冻了四分半。
        if advanceClockOnSleepEvidence > 0 {
            advanceClock(by: advanceClockOnSleepEvidence)
        }
        onSleepEvidence?()
        return sleepSucceeds ? .slept : sleepEvidenceValue
    }

    /// 读证据这段里时间往前跳多少秒（复现「读日志期间机器睡着了」）。
    var advanceClockOnSleepEvidence: TimeInterval = 0
    /// 读证据这一刻插一脚，用来复现「用户正好在这时点了结束」。
    var onSleepEvidence: (() -> Void)?

    func systemSleepBlockers() async -> [String] {
        sleepBlockers
    }

    // MARK: - BluetoothControlling

    func powerState() async -> Int? {
        bluetoothState
    }

    func setPower(_ on: Bool) async -> String? {
        record("bluetooth \(on ? "on" : "off")")
        if let bluetoothSetFailure {
            return bluetoothSetFailure
        }
        bluetoothState = on ? 1 : 0
        return nil
    }

    // MARK: - BatteryReading

    func percentage() -> Int? {
        batteryLevel
    }

    // MARK: - SharingControlling

    func listeningLabels() async -> [String] {
        sharingLabels
    }

    func disableAll() async -> [FailedItem] {
        guard !sharingLabels.isEmpty else { return [] }
        record("sharing disable")
        if let sharingFailure {
            return [
                FailedItem(
                    title: "共享服务",
                    detail: FailureText.humanize(sharingFailure, severity: .optional),
                    severity: .optional
                )
            ]
        }
        sharingLabels = []
        return []
    }

    func restore(_ labels: [String]) async -> [FailedItem] {
        guard !labels.isEmpty else { return [] }
        record("sharing restore")
        sharingLabels = labels
        return []
    }

    // MARK: - TimeMachineControlling

    func isEnabled() async -> Bool? {
        timeMachineIsOn
    }

    func disable() async -> TimeMachineControl.PauseOutcome {
        guard timeMachineIsOn == true else {
            return TimeMachineControl.PauseOutcome(didDisable: false)
        }
        record("tm disable")
        if let timeMachineDisableFailure {
            return TimeMachineControl.PauseOutcome(
                didDisable: false,
                failure: FailedItem(
                    title: "Time Machine",
                    detail: FailureText.humanize(timeMachineDisableFailure, severity: .optional),
                    severity: .optional
                )
            )
        }
        timeMachineIsOn = false
        return TimeMachineControl.PauseOutcome(didDisable: true)
    }

    func enable() async -> FailedItem? {
        record("tm enable")
        if let timeMachineEnableFailure {
            return FailedItem(
                title: "恢复 Time Machine",
                detail: FailureText.humanize(timeMachineEnableFailure, severity: .optional),
                severity: .optional
            )
        }
        timeMachineIsOn = true
        return nil
    }

    // MARK: - DisplayWatching

    func setHandler(_ handler: (@MainActor @Sendable (Int) -> Void)?) {
        displayHandler = handler
    }

    func start() {
        displayWatcherRunning = true
        record("display watch start")
    }

    func stop() {
        displayWatcherRunning = false
        record("display watch stop")
    }

    func activeDisplayCount() -> Int {
        displayCountValue
    }

    func onlineDisplayIDs() -> [CGDirectDisplayID] {
        onlineIDs
    }

    func mainDisplayID() -> CGDirectDisplayID {
        mainID
    }

    func builtinOnline() -> Bool {
        builtinIsOnline
    }

    func remoteLogins() async -> [String] {
        remoteLoginsValue
    }

    /// 跟真实现一样走 snapshot 的 description，这样「占位」之类的标记在模拟里
    /// 也能被断言到。
    func describeDisplays() -> String {
        let list = displaySnapshots()
        return list.isEmpty ? "无" : list.map(\.description).joined(separator: " / ")
    }

    func displaySnapshots() -> [DisplayWatcher.DisplaySnapshot] {
        onlineIDs.map { id in
            let isVirtual = virtualIDs.contains(id)
            let isPhantom = phantomIDs.contains(id)
            return DisplayWatcher.DisplaySnapshot(
                id: id,
                builtin: builtinIDs.contains(id),
                active: true,
                asleep: false,
                vendor: isVirtual ? 1_970_170_734 : (isPhantom ? 0 : 0x4A8B),
                model: isVirtual ? 1_986_622_068 : (isPhantom ? 0 : 207),
                // DIY 便携屏的 EDID 是厂商自己烧的，序列号经常是 0x01010101 甚至 0。
                serial: isVirtual || isPhantom ? 0 : 0x01010101,
                width: 2560,
                height: 1440
            )
        }
    }

    // MARK: - StateStoring

    func loadState() -> SessionState? { storedState }

    func saveState(_ state: SessionState) throws {
        storedState = state
        savedStates.append(state)
        record("saveState \(state.phase.rawValue)")
    }

    func clearState() throws {
        storedState = nil
        clearedStateCount += 1
        record("clearState")
    }

    func loadSettings() -> AppSettings { storedSettings }

    func saveSettings(_ settings: AppSettings) throws {
        storedSettings = settings
    }

    func lastReport() -> Report? { storedReports.last }

    func appendReport(_ report: Report) throws {
        storedReports.append(report)
        record("appendReport")
    }

    func updateLastReport(_ report: Report) throws {
        guard !storedReports.isEmpty else {
            storedReports = [report]
            return
        }
        storedReports[storedReports.count - 1] = report
        record("updateLastReport")
    }

    // MARK: - Notifying

    func requestAuthorization() {}

    func post(title: String, body: String) {
        notifications.append("\(title)：\(body)")
        record("notify \(title)")
    }

    /// 模拟的授权结果。设成 false 用来复现「用户把通知关掉了」。
    var notificationAuthorized = true
    /// 「试一下」得到的答案。默认 `shown`，设成别的可以复现专注模式/无权限。
    var testResult: NotificationTestResult = .shown
    private(set) var testNotificationCount = 0

    func sendTest(title: String, body: String) async -> NotificationTestResult {
        testNotificationCount += 1
        record("sendTest \(testResult)")
        if testResult == .shown {
            notifications.append("\(title)：\(body)")
        }
        return testResult
    }

    func authorizationSummary() async -> String {
        notificationAuthorized ? "已允许 · 横幅（模拟）" : "被拒绝（模拟）"
    }

    // MARK: - LoginItemManaging

    func isEnabled() -> Bool { loginItemEnabled }

    func enable(executablePath: String) throws {
        loginItemEnabled = true
    }

    func disable() throws {
        loginItemEnabled = false
    }

    func rewriteIfNeeded(executablePath: String) {
        record("login item rewrite")
    }

    // MARK: - PowerLogReading

    func readPowerLog() async -> String {
        powerLogReads += 1
        return powerLog
    }

    // MARK: - HelperManaging

    var isInstalled: Bool { helperInstalled }

    func install() throws {
        helperInstallAttempts += 1
        record("helper install")
        guard helperInstallSucceeds else {
            throw SimulatedError(message: "授权被取消")
        }
        helperInstalled = true
    }

    // MARK: - SystemClock

    var now: Date { currentDate }

    func bootTime() -> TimeInterval { bootTimeValue }
}

struct SimulatedError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
