import Foundation
import Testing

@testable import HKMKit

@Suite("SessionStore 持久化")
struct SessionStoreTests {
    private func makeStore() throws -> (SessionStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hkm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (SessionStore(directory: directory), directory)
    }

    @Test("状态文件能原样读回")
    func roundTripsState() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        var snapshot = Snapshot()
        snapshot.bluetoothPower = 1
        snapshot.pmset["disablesleep"] = 1
        snapshot.pmset["sleep"] = 0
        snapshot.timeMachineEnabled = true
        snapshot.sharing = ["com.apple.smbd"]
        snapshot.terminatedApps = ["com.uu.remote"]
        snapshot.scheduledWake = ["[0]  wake at 10/22/2026 18:21:07"]

        let started = ISO8601OffsetFormatter.date(from: "2026-10-23T21:00:00+08:00")!
        let state = SessionState(
            phase: .away,
            startedAt: started,
            timeZoneOffsetMinutes: 480,
            logAnchor: "2026-10-23 21:00:00 +0800",
            batteryStart: 78,
            bootTimeAtStart: 1_234_567,
            displayDetachedAt: ISO8601OffsetFormatter.date(from: "2026-10-23T21:02:11+08:00"),
            snapshot: snapshot
        )

        try store.saveState(state)
        let loaded = store.loadState()
        #expect(loaded?.phase == .away)
        #expect(loaded?.batteryStart == 78)
        #expect(loaded?.logAnchor == "2026-10-23 21:00:00 +0800")
        #expect(loaded?.snapshot.pmset["disablesleep"] == 1)
        #expect(loaded?.snapshot.sharing == ["com.apple.smbd"])
        #expect(loaded?.displayDetachedAt != nil)
    }

    @Test("JSON 字段名与设计文档一致")
    func jsonShapeMatchesDesign() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = ISO8601OffsetFormatter.date(from: "2026-10-23T21:00:00+08:00")!
        var snapshot = Snapshot()
        snapshot.pmset["womp"] = 1
        let state = SessionState(
            phase: .away,
            startedAt: started,
            timeZoneOffsetMinutes: 480,
            logAnchor: "2026-10-23 21:00:00 +0800",
            batteryStart: 78,
            bootTimeAtStart: 1,
            snapshot: snapshot
        )
        try store.saveState(state)

        let data = try Data(contentsOf: store.stateURL)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["phase"] as? String == "away")
        #expect(object?["timeZoneOffsetMinutes"] as? Int == 480)
        #expect(object?["logAnchor"] as? String == "2026-10-23 21:00:00 +0800")
        #expect((object?["startedAt"] as? String)?.contains("+08:00") == true)

        let snapshotObject = object?["snapshot"] as? [String: Any]
        let pmsetObject = snapshotObject?["pmset"] as? [String: Any]
        #expect(pmsetObject?["womp"] as? Int == 1)
    }

    @Test("损坏的状态文件不会让程序崩掉")
    func toleratesCorruptState() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "not json".write(to: store.stateURL, atomically: true, encoding: .utf8)
        #expect(store.loadState() == nil)
    }

    @Test("设置缺省值与默认一致")
    func defaultSettings() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(store.loadSettings() == AppSettings.default)
        var settings = AppSettings.default
        settings.onboardingDone = true
        settings.sleepDelaySeconds = 10
        try store.saveSettings(settings)
        #expect(store.loadSettings().sleepDelaySeconds == 10)
    }

    @Test("报告历史按顺序追加")
    func appendsReports() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let first = Report(
            startedAt: started,
            endedAt: started.addingTimeInterval(600),
            durationSeconds: 600,
            sleptAtAll: true,
            darkWakeCount: 1,
            notificationWakeCount: 0,
            realWakeCount: 0
        )
        let second = Report(
            startedAt: started.addingTimeInterval(3600),
            endedAt: started.addingTimeInterval(7200),
            durationSeconds: 3600,
            sleptAtAll: true,
            darkWakeCount: 2,
            notificationWakeCount: 1,
            realWakeCount: 1
        )
        try store.appendReport(first)
        try store.appendReport(second)
        #expect(store.loadReports().count == 2)
        #expect(store.lastReport()?.realWakeCount == 1)
    }
}
