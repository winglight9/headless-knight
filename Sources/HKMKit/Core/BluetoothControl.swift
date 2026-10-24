import CoreBluetooth
import Foundation

/// Bluetooth power control.
///
/// 三条路径的现状（macOS 15.8.1 实测，2026-10-24）：
///
/// 1. **私有 API** `IOBluetoothPreferenceSetControllerPowerState` —— 唯一真正能
///    关掉控制器的方式。但它被 CoreBluetooth 的 TCC 门禁挡着：没有蓝牙权限就
///    调用，进程会被 TCC 直接 abort（不是返回错误，是消失）。崩溃报告
///    `HeadlessKnightMaster-2026-10-23-223838.ips` 的
///    `__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__` 就是它。所以调用前必须先用
///    `CBCentralManager.authorization` 查权限——那个查询本身不会崩。
///
/// 2. **后台服务写 plist** —— 老办法（写 `ControllerPowerState` 再 killall
///    bluetoothd）。在 macOS 15 上**已经彻底失效**：实测 plist 写成了 0，
///    `system_profiler` 仍然报 `State: On`。以前拿 plist 回读校验，等于自己给
///    自己打分，于是界面写着「✓ 关闭了蓝牙」，实际上蓝牙还开着、蓝牙鼠标还能
///    把机器叫醒。这是 2026-10-24 早上「拔了显示器却一直不睡」的直接原因之一。
///
/// 3. **校验** —— 现在只认 `system_profiler SPBluetoothDataType`。它走 IOKit，
///    不需要任何权限，读到的才是控制器的真实开关。
///
/// 结论：拿不到蓝牙权限时，自动关蓝牙是做不到的。这时候必须如实报失败、让
/// 用户手动关，绝不谎报成功。
public struct BluetoothControl: Sendable {
    private typealias SetPowerFunction = @convention(c) (Int32) -> Void
    private typealias GetPowerFunction = @convention(c) () -> Int32

    nonisolated(unsafe) private static let frameworkHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth",
        RTLD_NOW
    )

    // 函数指针类型本身满足 Sendable，不需要 nonisolated(unsafe)
    private static let setPowerFunction: SetPowerFunction? = {
        guard let handle = frameworkHandle,
              let symbol = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetPowerFunction.self)
    }()

    private static let getPowerFunction: GetPowerFunction? = {
        guard let handle = frameworkHandle,
              let symbol = dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState") else {
            return nil
        }
        return unsafeBitCast(symbol, to: GetPowerFunction.self)
    }()

    /// 只有拿到蓝牙权限才敢碰私有 API，否则 TCC 会直接杀掉进程。
    public static var hasBluetoothPermission: Bool {
        // `swift run` 没有 bundle，没有 usage description，一律当作没权限。
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return CBCentralManager.authorization == .allowedAlways
    }

    private static var canUsePrivateAPI: Bool {
        setPowerFunction != nil && getPowerFunction != nil && hasBluetoothPermission
    }

    private let runner: any CommandRunning
    private let executor: any PrivilegedExecuting
    private let client: HelperClient

    public init(
        runner: any CommandRunning = ShellRunner(),
        executor: any PrivilegedExecuting = PrivilegedExecutorFactory.make(),
        client: HelperClient = HelperClient()
    ) {
        self.runner = runner
        self.executor = executor
        self.client = client
    }

    /// Whether both private symbols resolved. Reported by `--diagnose`.
    public var hasPrivateAPI: Bool {
        BluetoothControl.setPowerFunction != nil && BluetoothControl.getPowerFunction != nil
    }

    // MARK: - Reading

    /// 1 = on, 0 = off, nil = unknown.
    ///
    /// `system_profiler` 排第一：它是唯一不受我们自己的写入影响的读数。
    public func powerState() -> Int? {
        if let state = powerStateViaSystemProfiler() {
            return state
        }
        if BluetoothControl.canUsePrivateAPI, let getPower = BluetoothControl.getPowerFunction {
            let raw = Int(getPower())
            // 没有权限时这个函数返回 255，不是 0/1。
            if raw == 0 || raw == 1 { return raw }
        }
        if let state = powerStateViaHelper() {
            return state
        }
        return powerStateViaDefaults()
    }

    /// Root reads the preference file; no TCC involvement. 注意：这只是「偏好文件
    /// 里写着什么」，macOS 15 上它和真实状态可以完全不一致。
    public func powerStateViaHelper() -> Int? {
        let request = HelperRequest(operation: .bluetoothReadPower)
        guard let response = try? client.send(request), response.ok else {
            return nil
        }
        return response.intValue
    }

    /// Non-privileged read of the preference file, used when the daemon is absent.
    public func powerStateViaDefaults() -> Int? {
        guard let result = try? runner.run("/usr/bin/defaults", arguments: [
            "read", "/Library/Preferences/com.apple.Bluetooth", "ControllerPowerState"
        ]), result.succeeded else {
            return nil
        }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// macOS 15 不再把 `ControllerPowerState` 写进系统偏好文件，只剩
    /// `system_profiler` 这条不需要任何权限的读取路径。
    public func powerStateViaSystemProfiler() -> Int? {
        guard let result = try? runner.run(
            "/usr/sbin/system_profiler",
            arguments: ["SPBluetoothDataType"],
            timeout: 10
        ), result.succeeded else {
            return nil
        }
        return BluetoothControl.parsePowerState(fromProfiler: result.stdout)
    }

    /// 从 `system_profiler SPBluetoothDataType` 里读控制器开关。
    public static func parsePowerState(fromProfiler output: String) -> Int? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("State:") else { continue }
            let value = trimmed.dropFirst("State:".count).trimmingCharacters(in: .whitespaces)
            if value == "On" { return 1 }
            if value == "Off" { return 0 }
            return nil
        }
        return nil
    }

    // MARK: - Writing

    /// Returns the failure reason, or nil on success.
    public func setPower(_ on: Bool) async -> String? {
        let target = on ? 1 : 0
        let action = on ? "打开" : "关闭"

        if DryRun.isEnabled {
            DryRun.log("不会真的\(action)蓝牙")
            return nil
        }

        let before = powerStateViaSystemProfiler()
        if before == target {
            HKMLog.info("蓝牙已经是\(on ? "开" : "关")的状态，不需要改动")
            return nil
        }

        // 1) 私有 API：只有拿到蓝牙权限才走这条路。
        if BluetoothControl.canUsePrivateAPI, let setPower = BluetoothControl.setPowerFunction {
            HKMLog.info("尝试用私有 API \(action)蓝牙")
            setPower(Int32(target))
            if await waitForState(target) {
                HKMLog.info("私有 API \(action)蓝牙成功")
                return nil
            }
            HKMLog.error("私有 API 未能\(action)蓝牙，降级到后台服务")
        }

        // 2) 后台服务写 plist —— 这是 macOS 12 之前的老办法。15 上写进去根本
        //    没人读，还会顺手 killall bluetoothd，把用户正连着的鼠标打断一下，
        //    没有收益只有代价，所以新系统上直接跳过。
        let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if majorVersion < 15 {
            do {
                _ = try await executor.perform(.bluetoothSetPower, arguments: ["state": "\(target)"])
                if await waitForState(target) {
                    HKMLog.info("后台服务\(action)蓝牙成功")
                    return nil
                }
                HKMLog.error("后台服务写入了偏好文件，但控制器状态没变")
            } catch {
                HKMLog.error("后台服务\(action)蓝牙失败：\(error.localizedDescription)")
            }
        }

        if !BluetoothControl.hasBluetoothPermission {
            return "系统没给蓝牙权限，没法自动\(action)蓝牙"
        }
        return "蓝牙没能\(action)，控制器状态没有变化"
    }

    /// 轮询直到 `system_profiler` 报告目标状态。
    ///
    /// 关键点：只认 `system_profiler`。以前这里读的是 `powerState()`，而它的
    /// 首选来源正是后台服务刚写过的那个 plist —— 写完立刻读回同一个值，永远
    /// 「成功」。
    private func waitForState(_ expected: Int) async -> Bool {
        for attempt in 0..<6 {
            if powerStateViaSystemProfiler() == expected { return true }
            if attempt < 5 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        return powerStateViaSystemProfiler() == expected
    }
}

// MARK: - 蓝牙权限

/// 触发系统蓝牙授权弹窗。
///
/// 没有权限就调私有 API 会被 TCC 直接 abort，所以关蓝牙这条路必须先拿到权限。
/// 用 `CBCentralManager` 初始化来触发弹窗是官方支持的做法；弹窗只出现一次。
@MainActor
public final class BluetoothPermission {
    public static let shared = BluetoothPermission()

    /// 必须持有引用，否则弹窗还没响应对象就没了。
    private var manager: CBCentralManager?

    private init() {}

    public var authorization: CBManagerAuthorization {
        guard Bundle.main.bundleIdentifier != nil else { return .notDetermined }
        return CBCentralManager.authorization
    }

    public var isGranted: Bool { authorization == .allowedAlways }

    /// 只在「还没问过」的时候弹窗，已经拒绝过就不要再骚扰用户。
    public func requestIfNeeded() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        // 命令行路径（--diagnose / --simulate-away）没有 LaunchServices 上下文，
        // 弹不出授权框，TCC 会直接把进程 abort 掉。这类崩溃出现过一次了。
        let arguments = ProcessInfo.processInfo.arguments
        guard !arguments.contains("--diagnose"),
              !arguments.contains("--simulate-away"),
              !arguments.contains("--list-scenarios") else {
            return
        }
        guard authorization == .notDetermined else {
            HKMLog.info("蓝牙权限现状：\(describe(authorization))")
            return
        }
        HKMLog.info("请求蓝牙权限")
        manager = CBCentralManager(delegate: nil, queue: .main, options: [
            CBCentralManagerOptionShowPowerAlertKey: false
        ])
    }

    private func describe(_ authorization: CBManagerAuthorization) -> String {
        switch authorization {
        case .allowedAlways: return "已允许"
        case .denied: return "已拒绝"
        case .restricted: return "受限"
        case .notDetermined: return "未决定"
        @unknown default: return "未知"
        }
    }
}
