import Foundation

/// Reads and writes the six pmset keys the product cares about. Writes always go
/// through the privileged executor; reads are plain `pmset -g` calls.
public struct PowerSettings: Sendable {
    private let runner: any CommandRunning
    private let executor: any PrivilegedExecuting

    public init(runner: any CommandRunning = ShellRunner(), executor: any PrivilegedExecuting = PrivilegedExecutorFactory.make()) {
        self.runner = runner
        self.executor = executor
    }

    // MARK: - Reading

    /// `pmset -g custom` → ["AC Power": ["sleep": "0", ...], "Battery Power": [...]]
    public static func parseCustom(_ text: String) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        var current = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasSuffix(":") {
                current = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
                sections[current] = sections[current] ?? [:]
                continue
            }
            guard let (key, value) = splitKeyValue(line) else { continue }
            sections[current, default: [:]][key] = value
        }
        return sections
    }

    /// `pmset -g` → ["SleepDisabled": "1", "sleep": "0", ...]
    public static func parseGlobal(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasSuffix(":") { continue }
            guard let (key, value) = splitKeyValue(line) else { continue }
            values[key] = value
        }
        return values
    }

    /// `pmset -g sched` → the raw event lines, kept verbatim for the snapshot.
    public static func parseScheduledWakes(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("[") }
    }

    private static func splitKeyValue(_ line: String) -> (String, String)? {
        // `pmset -g` appends " (sleep prevented by ...)" to numeric values.
        var body = line
        if let parenIndex = body.firstIndex(of: "(") {
            body = String(body[body.startIndex..<parenIndex])
        }
        let parts = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 2, let value = parts.last else { return nil }
        let key = parts.dropLast().joined(separator: " ")
        guard !key.isEmpty else { return nil }
        return (key, value.trimmingCharacters(in: .whitespaces))
    }

    public func readSnapshot() throws -> PmsetSnapshot {
        let customResult = try runner.run("/usr/bin/pmset", arguments: ["-g", "custom"])
        guard customResult.succeeded else {
            throw HKMError.commandFailed(executable: "pmset -g custom", status: customResult.status, message: customResult.stderr)
        }
        let sections = PowerSettings.parseCustom(customResult.stdout)
        let active = sections["AC Power"] ?? sections["Battery Power"] ?? [:]
        let global = (try? runner.run("/usr/bin/pmset", arguments: ["-g"]))
            .map { PowerSettings.parseGlobal($0.stdout) } ?? [:]

        var snapshot = PmsetSnapshot()
        snapshot["sleep"] = intValue(active["sleep"])
        snapshot["womp"] = intValue(active["womp"])
        snapshot["powernap"] = intValue(active["powernap"])
        snapshot["tcpkeepalive"] = intValue(active["tcpkeepalive"])
        snapshot["standby"] = intValue(active["standby"])
        // `disablesleep` only shows up in `pmset -g` as "SleepDisabled".
        snapshot["disablesleep"] = intValue(global["SleepDisabled"]) ?? intValue(active["disablesleep"])
        return snapshot
    }

    /// 两次 `pmset` 调用，加起来一两百毫秒。出门流程里用它，别占着主线程。
    public func readSnapshotAsync() async throws -> PmsetSnapshot {
        try await offMainThrowing { try self.readSnapshot() }
    }

    public func scheduledWakes() -> [String] {
        guard let result = try? runner.run("/usr/bin/pmset", arguments: ["-g", "sched"]), result.succeeded else {
            return []
        }
        return PowerSettings.parseScheduledWakes(result.stdout)
    }

    private func intValue(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Writing

    /// Clears the L1 blockers: allow sleep, disable network wake, Power Nap and
    /// TCP keepalive. `standby` is left alone (it does not wake the machine).
    ///
    /// 每一项都是「能不能睡」的关键项，失败必须阻断。传了 `current` 时，已经是
    /// 目标值的键不再重复写——少一次 root 操作就少一次出错的机会。
    /// 出门时要写入的目标值。`standby` 不在里面：它不影响机器被叫醒。
    public static let awayTargets: [(key: String, value: Int)] = [
        ("disablesleep", 0),
        ("sleep", 1),
        ("womp", 0),
        ("powernap", 0),
        ("tcpkeepalive", 0)
    ]

    public func applyAwaySettings(
        current: PmsetSnapshot? = nil,
        cancelScheduledWakes: Bool = true
    ) async -> [FailedItem] {
        var failures: [FailedItem] = []
        for target in PowerSettings.awayTargets {
            let key = target.key
            let value = target.value
            if let current, current[key] == value { continue }
            do {
                _ = try await executor.perform(.pmsetSet, arguments: ["key": key, "value": "\(value)"])
            } catch {
                HKMLog.error("设置 \(key) 失败：\(error.localizedDescription)")
                // 后台服务挂了的时候，后面四个键只会同样失败，而且每次都要等超时。
                // 这时候直接把剩下的键合并成一条，用户看到一条清楚的话，而不是五条。
                if PowerSettings.isHelperUnavailable(error) {
                    failures.append(FailedItem(title: "睡眠设置", error: error, severity: .critical))
                    return failures
                }
                failures.append(FailedItem(title: "睡眠设置 \(key)", error: error, severity: .critical))
            }
        }
        // 清空定时唤醒只影响「会不会被定时叫醒」，不属于能不能睡，失败不阻断。
        if cancelScheduledWakes {
            do {
                _ = try await executor.perform(.pmsetScheduleCancelAll)
            } catch {
                HKMLog.error("清空定时唤醒失败：\(error.localizedDescription)")
                failures.append(FailedItem(title: "定时唤醒任务", error: error, severity: .optional))
            }
        }
        return failures
    }

    /// 后台服务不可用（没装 / 连不上 / 超时）与「这一项没权限」要区别对待：
    /// 前者是整条链路断了，继续试别的键没有意义。
    static func isHelperUnavailable(_ error: Error) -> Bool {
        guard let error = error as? HelperError else { return false }
        switch error {
        case .notInstalled, .connectionFailed, .timeout:
            return true
        case .protocolViolation, .remote:
            return false
        }
    }

    /// Restores one key at a time so a single failure cannot block the rest.
    /// 恢复阶段不在出门流程里，失败一律按 optional 记，不吓唬用户。
    public func restore(_ snapshot: PmsetSnapshot) async -> [FailedItem] {
        var failures: [FailedItem] = []
        for key in PmsetSnapshot.trackedKeys {
            guard let value = snapshot[key] else { continue }
            do {
                _ = try await executor.perform(.pmsetSet, arguments: ["key": key, "value": "\(value)"])
            } catch {
                HKMLog.error("恢复 \(key) 失败：\(error.localizedDescription)")
                failures.append(FailedItem(title: "恢复 \(key)", error: error, severity: .optional))
            }
        }
        return failures
    }

    public func sleepNow() async throws {
        _ = try await executor.perform(.pmsetSleepNow)
    }

    // MARK: - 睡眠验证

    /// `since` 之后系统到底有没有进入过睡眠。
    ///
    /// 不能靠定时器判断：机器真睡了，进程就挂起了，定时器根本不会走。
    /// 只有 `pmset -g log` 是脱离本进程的旁证——我们被挂起的时候它还在记。
    ///
    /// 所以这里的时序是：请求睡眠 → 等几秒 → 读日志。如果真睡了，这几秒是在
    /// 挂起状态下过去的，读日志发生在唤醒之后，日志里必然有 `Entering Sleep`。
    /// 读日志要几百毫秒，放到后台线程，别卡住菜单栏。
    public func didEnterSleep(since: Date) async -> Bool {
        let runner = self.runner
        let log: String = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = try? runner.run("/usr/bin/pmset", arguments: ["-g", "log"], timeout: 30)
                continuation.resume(returning: result?.stdout ?? "")
            }
        }
        guard !log.isEmpty else {
            HKMLog.error("读不到电源日志，无法确认是否真的睡了")
            return false
        }
        let entries = WakeAuditor.parse(log)
        // 给 3 秒余量：pmset 的时间戳精度是秒，而且日志写入有延迟。
        return entries.contains { $0.kind == .sleepEnter && $0.at >= since.addingTimeInterval(-3) }
    }

    /// 当前持有 `PreventSystemSleep` 的进程名。
    ///
    /// 只有这一类断言会挡住 `pmset sleepnow`；`PreventUserIdleSystemSleep`
    /// （Electron、powerd 那些）只影响「空闲自动睡」，不影响我们主动叫它睡。
    /// 拔掉显示器的那一刻 WindowServer 会临时抓一个，几秒后自己放掉——这正是
    /// 2026-10-24 早上那次「怎么都不睡」的现场。
    public func systemSleepBlockers() async -> [String] {
        let runner = self.runner
        let text: String = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = try? runner.run("/usr/bin/pmset", arguments: ["-g", "assertions"], timeout: 10)
                continuation.resume(returning: result?.stdout ?? "")
            }
        }
        return PowerSettings.parseSystemSleepBlockers(text)
    }

    public static func parseSystemSleepBlockers(_ text: String) -> [String] {
        var names: [String] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("pid "), line.contains("PreventSystemSleep") else { continue }
            // pid 162(WindowServer): [0x...] ...
            guard let open = line.firstIndex(of: "("),
                  let close = line.firstIndex(of: ")"),
                  open < close else { continue }
            let name = String(line[line.index(after: open)..<close])
            if !name.isEmpty, !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }
}
