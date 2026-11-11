import Foundation
import Testing

@testable import PEPELCore
@testable import PEPELEngine
@testable import PEPELPersistence
@testable import PEPELStorage

@Suite("Plan, restore center, presets, summary, PEPEL itself")
struct PlanTests {
    func engine(_ f: Fixture, store: PepelStore) throws -> PepelEngine {
        try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled, analyzers: [],
            processSource: FakeProcessSource(processes: []), telemetry: { SystemTelemetry() })
    }

    @Test("The plan lists what a daily rule would remove; a left-alone item leaves the plan and survives the rule")
    func planAndLeaveAlone() async throws {
        let f = Fixture()
        let downloads = f.dir(f.home + "/Downloads")
        f.file(downloads + "/old.pdf", bytes: 8192); f.age(downloads + "/old.pdf", hours: 24 * 60)
        f.file(downloads + "/kept.pdf", bytes: 8192); f.age(downloads + "/kept.pdf", hours: 24 * 60)
        f.file(downloads + "/new.pdf", bytes: 8192)
        let store = try PepelStore.inMemory()
        let engine = try engine(f, store: store)

        #expect(await engine.actionPlan().actions.isEmpty, "no rule is on by default")
        _ = try await engine.update { $0.tidyDownloads = true; $0.downloadDays = 30 }
        let plan = await engine.actionPlan()
        #expect(Set(plan.actions.map(\.title)) == ["old.pdf", "kept.pdf"])
        #expect(plan.actions.allSatisfy { $0.rule == .downloads && $0.verb == "move to the Trash" })

        let kept = try #require(plan.actions.first { $0.title == "kept.pdf" })
        try await engine.setLeftAlone([kept.id], true)
        #expect(await engine.actionPlan().actions.map(\.title) == ["old.pdf"])

        _ = await engine.automaticPass()
        #expect(!PathUtil.exists(downloads + "/old.pdf"))
        #expect(PathUtil.exists(downloads + "/kept.pdf"), "left alone")
        #expect(PathUtil.exists(downloads + "/new.pdf"))

        try await engine.setLeftAlone([kept.id], false)
        #expect(await engine.currentSettings().leaveAlone.isEmpty)
    }

    @Test("What a rule moved to the Trash is recorded and can be put back once; what was removed for good is listed")
    func restoreCenter() async throws {
        let f = Fixture()
        let downloads = f.dir(f.home + "/Downloads")
        f.file(downloads + "/report.pdf", bytes: 8192); f.age(downloads + "/report.pdf", hours: 24 * 60)
        let store = try PepelStore.inMemory()
        let engine = try engine(f, store: store)
        _ = try await engine.update { $0.tidyDownloads = true }
        _ = await engine.runTidy(screenshots: false, downloads: true, confirmed: true, initiator: .user)
        store.appendAudit(AuditEntry(kind: .cleanup, initiator: "automatic", subject: "Tool caches: Go 1 GB", outcome: "removed", bytes: Bytes.gb))

        let center = engine.restoreCenter()
        let record = try #require(center.restorable.first)
        #expect(center.restorable.count == 1 && record.originalPath == downloads + "/report.pdf" && record.source == "Downloads")
        #expect(center.removed.map(\.subject) == ["Tool caches: Go 1 GB"])

        #expect(engine.restoreTrashed(id: record.id) == nil)
        #expect(PathUtil.exists(downloads + "/report.pdf"))
        #expect(engine.restoreTrashed(id: record.id) != nil, "only once")
        #expect(engine.restoreCenter().restorable.isEmpty)
    }

    @Test("A trashed item whose place is taken again cannot be put back over it")
    func restoreRefusesOccupiedPlace() async throws {
        let f = Fixture()
        let store = try PepelStore.inMemory()
        let engine = try engine(f, store: store)
        let original = f.file(f.home + "/Downloads/a.txt", bytes: 10)
        let trashed = f.file(f.home + "/.Trash/a.txt", bytes: 10)
        let id = store.recordTrashed(TrashRecord(source: "Downloads", originalPath: original, trashedPath: trashed, bytes: 10))
        #expect(engine.restoreCenter().gone.map(\.id) == [id])
        #expect(engine.restoreTrashed(id: id) != nil)
        #expect(PathUtil.exists(trashed), "nothing was overwritten")
    }

    @Test("Each preset is recognised after it is applied; careful switches every disk rule off")
    func presets() {
        for preset in SettingsPreset.allCases {
            var settings = PepelSettings()
            settings.keepEmulators = ["x"]
            preset.apply(to: &settings)
            #expect(SettingsPreset.matching(settings) == preset)
            #expect(settings.keepEmulators == ["x"], "keep lists are not part of a preset")
        }
        var careful = PepelSettings()
        careful.tidyScreenshots = true
        SettingsPreset.careful.apply(to: &careful)
        #expect(!careful.tidyScreenshots && !careful.dockerAutoClean && !careful.trimCaches && !careful.cleanToolBackups)
        var custom = PepelSettings()
        SettingsPreset.normal.apply(to: &custom)
        custom.logDays = 3
        #expect(SettingsPreset.matching(custom) == nil)
        #expect(SettingsPreset.normal.changes(from: custom) == ["logDays: 3 → 30"])
    }

    @Test("A weekly summary is owed once after its day and hour, also when the Mac was off then")
    func weeklySummaryDue() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
        // 2026-11-09 is a Monday.
        let monday9 = date("2026-11-09T09:00:00Z")
        let weekly = SummaryFrequency.weekly
        #expect(weekly.lastDue(before: date("2026-11-11T12:00:00Z"), weekday: 2, hour: 9, calendar: calendar) == monday9)
        #expect(weekly.isDue(lastPosted: date("2026-11-08T10:00:00Z"), now: date("2026-11-10T08:00:00Z"), weekday: 2, hour: 9, calendar: calendar), "Tuesday, Monday's was missed")
        #expect(!weekly.isDue(lastPosted: date("2026-11-09T09:05:00Z"), now: date("2026-11-12T08:00:00Z"), weekday: 2, hour: 9, calendar: calendar))
        #expect(!weekly.isDue(lastPosted: date("2026-11-08T10:00:00Z"), now: date("2026-11-09T08:59:00Z"), weekday: 2, hour: 9, calendar: calendar), "not before the hour")
        #expect(SummaryFrequency.daily.isDue(lastPosted: date("2026-11-10T09:30:00Z"), now: date("2026-11-11T09:00:00Z"), weekday: 2, hour: 9, calendar: calendar))
        #expect(!SummaryFrequency.off.isDue(lastPosted: nil, now: Date(), weekday: 2, hour: 9, calendar: calendar))
    }

    @Test("PEPEL warns about itself only when it holds too much or a heavy job keeps it busy")
    func selfWarning() {
        let quiet = SelfUsage(processes: [.init(pid: 1, name: "PEPEL", footprintBytes: 200 * Bytes.mb, cpuPercent: 3)], heavyTasks: [])
        #expect(quiet.warning(memoryLimitMB: 1024) == nil)
        let mapping = SelfUsage(processes: [.init(pid: 1, name: "PEPEL", footprintBytes: 200 * Bytes.mb, cpuPercent: 140)], heavyTasks: ["Disk map"])
        #expect(mapping.warning(memoryLimitMB: 1024)?.contains("Disk map") == true)
        let heavy = SelfUsage(processes: [.init(pid: 1, name: "PEPEL", footprintBytes: 2 * Bytes.gb, cpuPercent: 1)], heavyTasks: [])
        #expect(heavy.warning(memoryLimitMB: 1024) != nil)
        #expect(heavy.warning(memoryLimitMB: 0) == nil, "0 switches the memory warning off")
    }
}
