import AppKit
import Darwin
import Foundation

public enum KillOutcome: Sendable, Equatable {
    case terminated
    case forceTerminated
    case alreadyGone
    case dryRun
    case failed(String)

    public var isSuccess: Bool {
        switch self {
        case .terminated, .forceTerminated, .alreadyGone, .dryRun:
            return true
        case .failed:
            return false
        }
    }
}

/// Quits a process: `terminate()` → 2s → `forceTerminate()` for GUI apps, and
/// SIGTERM → SIGKILL for everything else (caffeinate, Electron helpers, daemons).
@MainActor
public struct ProcessKiller {
    private let dryRun: Bool
    private let gracefulTimeout: TimeInterval
    private let forceTimeout: TimeInterval

    public init(
        dryRun: Bool = DryRun.isEnabled,
        gracefulTimeout: TimeInterval = 2.0,
        forceTimeout: TimeInterval = 1.0
    ) {
        self.dryRun = dryRun
        self.gracefulTimeout = gracefulTimeout
        self.forceTimeout = forceTimeout
    }

    public func kill(_ blocker: SleepBlocker) async -> KillOutcome {
        if dryRun {
            DryRun.log("不会真的退出 \(blocker.processName)(\(blocker.allPIDs.map(String.init).joined(separator: ",")))")
            return .dryRun
        }
        var failure: String?
        var didTerminate = false
        var didForceTerminate = false
        for pid in blocker.allPIDs {
            switch await killProcess(pid: pid, name: blocker.processName) {
            case .terminated:
                didTerminate = true
            case .forceTerminated:
                didForceTerminate = true
            case .alreadyGone, .dryRun:
                continue
            case let .failed(message):
                failure = failure ?? message
            }
        }
        if let failure {
            return .failed(failure)
        }
        if didForceTerminate { return .forceTerminated }
        if didTerminate { return .terminated }
        return .alreadyGone
    }

    private func killProcess(pid: pid_t, name: String) async -> KillOutcome {
        guard isAlive(pid) else { return .alreadyGone }

        let app = NSRunningApplication(processIdentifier: pid)
        let isGUI = app != nil && app?.activationPolicy != .prohibited

        if isGUI, let app {
            if app.terminate() {
                if await waitForExit(pid: pid, timeout: gracefulTimeout) {
                    HKMLog.info("已退出 \(name)(\(pid))")
                    return .terminated
                }
            }
            if app.forceTerminate(), await waitForExit(pid: pid, timeout: forceTimeout) {
                HKMLog.info("已强制退出 \(name)(\(pid))")
                return .forceTerminated
            }
            return .failed(L("无法自动退出，它还在阻止睡眠。请手动退出这个程序"))
        }

        if Darwin.kill(pid, SIGTERM) == 0 {
            if await waitForExit(pid: pid, timeout: gracefulTimeout) {
                HKMLog.info("已终止 \(name)(\(pid))")
                return .terminated
            }
        }
        if Darwin.kill(pid, SIGKILL) == 0 {
            if await waitForExit(pid: pid, timeout: forceTimeout) {
                HKMLog.info("已强制终止 \(name)(\(pid))")
                return .forceTerminated
            }
        }
        return .failed(L("无法终止这个进程，它还在阻止睡眠"))
    }

    private func waitForExit(pid: pid_t, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isAlive(pid) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return !isAlive(pid)
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
