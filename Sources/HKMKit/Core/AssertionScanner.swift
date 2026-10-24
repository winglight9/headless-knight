import AppKit
import Foundation

/// One `pid N(name): [...] Type named: "..."` block from `pmset -g assertions`.
public struct AssertionEntry: Sendable, Equatable {
    public let pid: pid_t
    public let ownerName: String
    public let assertionType: String
    public let assertionName: String
    public let durationSeconds: Int
    public let createdForPID: pid_t?
    public let resources: [String]

    public init(
        pid: pid_t,
        ownerName: String,
        assertionType: String,
        assertionName: String,
        durationSeconds: Int,
        createdForPID: pid_t? = nil,
        resources: [String] = []
    ) {
        self.pid = pid
        self.ownerName = ownerName
        self.assertionType = assertionType
        self.assertionName = assertionName
        self.durationSeconds = durationSeconds
        self.createdForPID = createdForPID
        self.resources = resources
    }
}

public struct KernelAssertion: Sendable, Equatable {
    public let name: String
    public let detail: String

    public init(name: String, detail: String) {
        self.name = name
        self.detail = detail
    }
}

public struct AssertionScan: Sendable, Equatable {
    public var entries: [AssertionEntry]
    public var kernelAssertions: [KernelAssertion]

    public init(entries: [AssertionEntry] = [], kernelAssertions: [KernelAssertion] = []) {
        self.entries = entries
        self.kernelAssertions = kernelAssertions
    }
}

public struct BlockerScanResult: Sendable, Equatable {
    /// Processes the user has to quit.
    public var blockers: [SleepBlocker]
    /// Assertions held by system daemons that will clear themselves.
    public var systemEntries: [SleepBlocker]

    public init(blockers: [SleepBlocker] = [], systemEntries: [SleepBlocker] = []) {
        self.blockers = blockers
        self.systemEntries = systemEntries
    }

    public var blockingCount: Int { blockers.count }
    public var systemCount: Int { systemEntries.count }
}

public protocol ProcessResolving: Sendable {
    func name(of pid: pid_t) -> String?
    func bundleIdentifier(of pid: pid_t) -> String?
    func isSystemProcess(_ pid: pid_t) -> Bool
}

public struct AssertionScanner: Sendable {
    /// Assertion types that keep the *system* awake.
    public static let blockingTypes: Set<String> = [
        "PreventUserIdleSystemSleep",
        "PreventSystemSleep",
        "NoIdleSleepAssertion",
        "InternalPreventSleep"
    ]

    /// Assertion types that only keep the display awake.
    public static let displayOnlyTypes: Set<String> = [
        "PreventUserIdleDisplaySleep",
        "NoDisplaySleepAssertion"
    ]

    /// Daemons that hold assertions on behalf of the system itself.
    public static let systemProcessNames: Set<String> = [
        "powerd", "WindowServer", "coreaudiod", "loginwindow", "bluetoothd", "runningboardd",
        "launchd", "kernel_task", "dasd", "mds", "mds_stores", "backboardd", "sharingd",
        "UserEventAgent", "configd", "apsd", "nsurlsessiond", "cloudd", "bird", "photoanalysisd",
        "mediaanalysisd", "syspolicyd", "distnoted", "tccd", "securityd", "coreduetd", "duetexpertd",
        "suggestd", "knowledged", "mdworker", "mdworker_shared", "hidd", "watchdogd",
        "thermalmonitord", "nehelper", "nesessionmanager", "ControlCenter", "NotificationCenter",
        "SystemUIServer", "spotlightknowledged", "contextstored", "biometrickitd", "iconservicesagent",
        "WallpaperAgent", "Dock", "Finder", "universalaccessd", "powerdatad"
    ]

    private let runner: any CommandRunning
    private let resolver: any ProcessResolving

    public init(runner: any CommandRunning = ShellRunner(), resolver: any ProcessResolving = RunningApplicationResolver()) {
        self.runner = runner
        self.resolver = resolver
    }

    // MARK: - Reading

    public func readAssertions() throws -> String {
        let result = try runner.run("/usr/bin/pmset", arguments: ["-g", "assertions"])
        guard result.succeeded else {
            throw HKMError.commandFailed(executable: "pmset -g assertions", status: result.status, message: result.stderr)
        }
        return result.stdout
    }

    public func scan() throws -> BlockerScanResult {
        let text = try readAssertions()
        let scan = AssertionScanner.parse(text)
        return blockers(from: scan)
    }

    // MARK: - Parsing

    public static func parse(_ text: String) -> AssertionScan {
        var entries: [AssertionEntry] = []
        var kernel: [KernelAssertion] = []

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let entry = parseProcessLine(line) {
                // Continuation lines belong to the entry just parsed.
                var createdFor: pid_t?
                var resources: [String] = []
                var lookahead = index + 1
                while lookahead < lines.count {
                    let next = lines[lookahead].trimmingCharacters(in: .whitespaces)
                    if next.isEmpty { break }
                    if let value = value(after: "Created for PID:", in: next) {
                        createdFor = pid_t(value.replacingOccurrences(of: ".", with: ""))
                    } else if next.hasPrefix("Resources:") {
                        resources = next
                            .replacingOccurrences(of: "Resources:", with: "")
                            .split(separator: " ")
                            .map(String.init)
                    } else {
                        // Anything else (Kernel Assertions, a new pid line, a
                        // section header) is not part of this entry.
                        break
                    }
                    lookahead += 1
                }
                entries.append(
                    AssertionEntry(
                        pid: entry.pid,
                        ownerName: entry.ownerName,
                        assertionType: entry.assertionType,
                        assertionName: entry.assertionName,
                        durationSeconds: entry.durationSeconds,
                        createdForPID: createdFor,
                        resources: resources
                    )
                )
                index = lookahead
                continue
            }
            if line.contains("Kernel Assertions:") {
                let detail = line.trimmingCharacters(in: .whitespaces)
                let name = detail.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces) ?? detail
                kernel.append(KernelAssertion(name: name, detail: detail))
            } else if line.contains("MAGICWAKE"), line.trimmingCharacters(in: .whitespaces).hasPrefix("id=") {
                kernel.append(KernelAssertion(name: "MAGICWAKE", detail: line.trimmingCharacters(in: .whitespaces)))
            }
            index += 1
        }

        return AssertionScan(entries: entries, kernelAssertions: kernel)
    }

    private static func isSectionHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasSuffix(":") && !trimmed.contains("named:")
    }

    private static func value(after prefix: String, in string: String) -> String? {
        guard let range = string.range(of: prefix) else { return nil }
        let rest = string[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// `   pid 182(coreaudiod): [0x...] 00:42:17 PreventUserIdleSystemSleep named: "..."  `
    static func parseProcessLine(_ line: String) -> AssertionEntry? {
        guard line.contains("pid "), line.contains("named:") else { return nil }
        guard let regex = try? NSRegularExpression(
            pattern: "^\\s*pid\\s+(\\d+)\\((.+?)\\):\\s+\\[0x[0-9a-fA-F]+\\]\\s+(\\d+):(\\d{2}):(\\d{2})\\s+(\\S+)\\s+named:\\s+\"(.*)\"",
            options: []
        ) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range) else { return nil }

        func group(_ index: Int) -> String? {
            guard match.numberOfRanges > index, let r = Range(match.range(at: index), in: line) else { return nil }
            return String(line[r])
        }

        guard let pidText = group(1), let pid = pid_t(pidText),
              let owner = group(2),
              let hours = Int(group(3) ?? ""), let minutes = Int(group(4) ?? ""), let seconds = Int(group(5) ?? ""),
              let type = group(6), let name = group(7) else {
            return nil
        }

        return AssertionEntry(
            pid: pid,
            ownerName: owner,
            assertionType: type,
            assertionName: name,
            durationSeconds: hours * 3600 + minutes * 60 + seconds
        )
    }

    // MARK: - Resolution

    /// Collapses proxy assertions onto the process the user actually has to quit,
    /// and collapses multiple processes of one app into a single row.
    public func blockers(from scan: AssertionScan) -> BlockerScanResult {
        struct Aggregate {
            var key: String
            var pid: pid_t
            var pids: [pid_t]
            var name: String
            var bundleID: String?
            var types: [String] = []
            var names: [String] = []
            var duration: Int = 0
            var proxyPID: pid_t?
            var proxyName: String?
            var kind: SleepBlocker.Kind = .blocking
        }

        var aggregates: [String: Aggregate] = [:]
        var order: [String] = []

        for entry in scan.entries {
            let isBlocking = AssertionScanner.blockingTypes.contains(entry.assertionType)
            let isDisplayOnly = AssertionScanner.displayOnlyTypes.contains(entry.assertionType)
            guard isBlocking || isDisplayOnly else { continue }

            var realPID = entry.pid
            var proxyPID: pid_t?
            var proxyName: String?
            if let createdFor = entry.createdForPID, createdFor != entry.pid {
                realPID = createdFor
                proxyPID = entry.pid
                proxyName = entry.ownerName
            }
            if realPID == getpid() { continue }

            let resolvedName = resolver.name(of: realPID) ?? (proxyPID == nil ? entry.ownerName : "PID \(realPID)")
            let bundleID = resolver.bundleIdentifier(of: realPID)
            // Bundle id is the app identity; a name-only fallback would merge
            // unrelated helpers that all call themselves "Electron".
            let key = bundleID ?? "name:\(resolvedName)"

            var aggregate = aggregates[key] ?? Aggregate(
                key: key,
                pid: realPID,
                pids: [],
                name: resolvedName,
                bundleID: bundleID
            )
            if !aggregate.pids.contains(realPID) {
                aggregate.pids.append(realPID)
            }
            if !aggregate.types.contains(entry.assertionType) {
                aggregate.types.append(entry.assertionType)
            }
            if !aggregate.names.contains(entry.assertionName) {
                aggregate.names.append(entry.assertionName)
            }
            aggregate.duration = max(aggregate.duration, entry.durationSeconds)
            if let proxyPID, let proxyName {
                aggregate.proxyPID = proxyPID
                aggregate.proxyName = proxyName
            }
            if isBlocking {
                aggregate.kind = .blocking
            }
            aggregates[key] = aggregate
            if !order.contains(key) { order.append(key) }
        }

        var blockers: [SleepBlocker] = []
        var systemEntries: [SleepBlocker] = []
        for key in order {
            guard let aggregate = aggregates[key] else { continue }
            let primaryPID = aggregate.pids.first ?? aggregate.pid
            let isSystem = aggregate.proxyPID == nil
                ? (AssertionScanner.systemProcessNames.contains(aggregate.name) || resolver.isSystemProcess(primaryPID))
                : resolver.isSystemProcess(primaryPID)
            let blocker = SleepBlocker(
                pid: primaryPID,
                processName: aggregate.name,
                bundleIdentifier: aggregate.bundleID,
                assertionTypes: aggregate.types,
                assertionNames: aggregate.names,
                durationSeconds: aggregate.duration,
                proxyOwnerPID: aggregate.proxyPID,
                proxyOwnerName: aggregate.proxyName,
                isSystemProcess: isSystem,
                kind: aggregate.kind,
                groupedPIDs: aggregate.pids
            )
            if isSystem {
                systemEntries.append(blocker)
            } else {
                blockers.append(blocker)
            }
        }

        blockers.sort { lhs, rhs in
            if lhs.durationSeconds == rhs.durationSeconds {
                return lhs.processName < rhs.processName
            }
            return lhs.durationSeconds > rhs.durationSeconds
        }
        return BlockerScanResult(blockers: blockers, systemEntries: systemEntries)
    }
}

/// Default resolver backed by `NSRunningApplication`, with `ps` as fallback for
/// daemons that AppKit does not know about.
public struct RunningApplicationResolver: ProcessResolving {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ShellRunner()) {
        self.runner = runner
    }

    public func name(of pid: pid_t) -> String? {
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            return name
        }
        return psValue(pid: pid, key: "comm")
    }

    public func bundleIdentifier(of pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    public func isSystemProcess(_ pid: pid_t) -> Bool {
        if pid <= 1 { return true }
        if let app = NSRunningApplication(processIdentifier: pid) {
            if app.bundleIdentifier?.hasPrefix("com.apple.") == true, app.activationPolicy == .prohibited {
                return true
            }
            return false
        }
        guard let path = psValue(pid: pid, key: "comm") else { return false }
        return path.hasPrefix("/usr/libexec/")
            || path.hasPrefix("/System/")
            || path.hasPrefix("/sbin/")
            || path.hasPrefix("/usr/sbin/")
    }

    private func psValue(pid: pid_t, key: String) -> String? {
        guard let result = try? runner.run("/bin/ps", arguments: ["-p", "\(pid)", "-o", "\(key)="]),
              result.succeeded else { return nil }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).lastPathComponent
    }
}
