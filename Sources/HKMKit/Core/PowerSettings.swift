import Foundation

/// Reads and writes the six pmset keys the product cares about. Writes always go
/// through the privileged executor; reads are plain `pmset -g` calls.
public struct PowerSettings: Sendable {
    private let runner: any CommandRunning
    private let executor: any PrivilegedExecuting
    /// 内核记的「最后一次进入睡眠」的时刻。测试里换掉，免得跟着真机走。
    private let lastSleepProvider: @Sendable () -> Date?

    public init(
        runner: any CommandRunning = ShellRunner(),
        executor: any PrivilegedExecuting = PrivilegedExecutorFactory.make(),
        lastSleepProvider: @escaping @Sendable () -> Date? = { PowerSettings.lastSleepTime() }
    ) {
        self.runner = runner
        self.executor = executor
        self.lastSleepProvider = lastSleepProvider
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

    /// 「叫它睡之后，到底睡没睡」的三种答案。
    ///
    /// `unknown` 这一档以前不存在：读不到电源日志被当成「没睡」，于是
    /// 2026-10-25 凌晨那趟——机器从 00:21 一直睡到早上、一整夜只掉了 4% 的电
    /// ——被报成「系统没有进入睡眠」，还连发了七条「没能进入睡眠」的通知。
    /// 读不到证据就是读不到，不能替系统认罪。
    public enum SleepEvidence: Sendable, Equatable {
        case slept
        case awake
        /// 拿不到任何旁证。**不等于没睡。**
        case unknown
    }

    /// 内核记的「最后一次进入睡眠」的时刻（`kern.sleeptime`）。
    ///
    /// 一次 sysctl，微秒级；`pmset -g log` 是几兆的文本，要几百毫秒到几十秒。
    /// 这个值只在真的进入睡眠时才会更新，所以「它早于我们请求的时刻」就是
    /// 「这之后没睡过」的硬证据。
    public static func lastSleepTime() -> Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.sleeptime", &value, &size, nil, 0) == 0,
              value.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000)
    }

    /// `since` 之后系统到底有没有进入过睡眠。
    ///
    /// 不能靠定时器判断：机器真睡了，进程就挂起了，定时器根本不会走。
    /// 只有脱离本进程的旁证才算数——内核的 `kern.sleeptime`，以及 `pmset -g log`。
    ///
    /// 给 3 秒余量：两边的时间戳精度都是秒，而且日志写入有延迟。
    public func sleepEvidence(since: Date) async -> SleepEvidence {
        let threshold = since.addingTimeInterval(-3)
        if let last = lastSleepProvider(), last >= threshold {
            return .slept
        }

        // 内核那边说没睡，再读一遍日志复核：万一某个机型不更新 kern.sleeptime，
        // 只信它就会把「睡了」报成「没睡」——这正是要修的那个 bug。
        let log = await readPowerLog()
        guard !log.isEmpty else {
            HKMLog.error("读不到电源日志，无法确认是否真的睡了")
            return .unknown
        }
        let entries = WakeAuditor.parse(log)
        return entries.contains { $0.kind == .sleepEnter && $0.at >= threshold } ? .slept : .awake
    }

    private func readPowerLog() async -> String {
        let runner = self.runner
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = try? runner.run("/usr/bin/pmset", arguments: ["-g", "log"], timeout: 30)
                continuation.resume(returning: result?.stdout ?? "")
            }
        }
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
