import Foundation

/// Persists the away session, settings and report history. Everything is plain
/// JSON on disk so a crash, a kill or a reboot never loses the session.
public struct SessionStore: Sendable {
    public let directory: URL
    private let runner: any CommandRunning

    public init(directory: URL = SystemInfo.appSupportDirectory, runner: any CommandRunning = ShellRunner()) {
        self.directory = directory
        self.runner = runner
    }

    public var stateURL: URL { directory.appendingPathComponent("state.json") }
    public var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    public var reportsURL: URL { directory.appendingPathComponent("reports.json") }

    // MARK: - Coders

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601OffsetFormatter.string(from: date))
        }
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = ISO8601OffsetFormatter.date(from: raw) {
                return date
            }
            if let date = PowerLogDateFormatter.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法解析日期 \(raw)")
        }
        return decoder
    }

    // MARK: - State

    public func loadState() -> SessionState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? SessionStore.makeDecoder().decode(SessionState.self, from: data)
    }

    public func saveState(_ state: SessionState) throws {
        try ensureDirectory()
        let data = try SessionStore.makeEncoder().encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    public func clearState() throws {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        try FileManager.default.removeItem(at: stateURL)
    }

    // MARK: - Settings

    public func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? SessionStore.makeDecoder().decode(AppSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    public func saveSettings(_ settings: AppSettings) throws {
        try ensureDirectory()
        let data = try SessionStore.makeEncoder().encode(settings)
        try data.write(to: settingsURL, options: .atomic)
    }

    // MARK: - History

    public func loadReports() -> [Report] {
        guard let data = try? Data(contentsOf: reportsURL),
              let reports = try? SessionStore.makeDecoder().decode([Report].self, from: data) else {
            return []
        }
        // 旧版本把 shell 原文写进了历史，读出来时补一次人话化；
        // 下一次 appendReport 会把清洗后的内容写回磁盘。
        return reports.map(SessionStore.sanitized)
    }

    static func sanitized(_ report: Report) -> Report {
        guard report.failedItems.contains(where: FailureText.isShellOutput) else { return report }
        var copy = report
        copy.failedItems = report.failedItems.map(FailureText.sanitizeLegacySummary)
        return copy
    }

    public func appendReport(_ report: Report) throws {
        try ensureDirectory()
        var reports = loadReports()
        reports.append(report)
        if reports.count > 50 {
            reports = Array(reports.suffix(50))
        }
        let data = try SessionStore.makeEncoder().encode(reports)
        try data.write(to: reportsURL, options: .atomic)
    }

    public func lastReport() -> Report? {
        loadReports().last
    }

    /// 覆盖最后一条报告。用于「恢复失败」这类事后才知道的补充信息。
    public func updateLastReport(_ report: Report) throws {
        try ensureDirectory()
        var reports = loadReports()
        guard !reports.isEmpty else {
            reports = [report]
            let data = try SessionStore.makeEncoder().encode(reports)
            try data.write(to: reportsURL, options: .atomic)
            return
        }
        reports[reports.count - 1] = report
        let data = try SessionStore.makeEncoder().encode(reports)
        try data.write(to: reportsURL, options: .atomic)
    }

    private func ensureDirectory() throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
