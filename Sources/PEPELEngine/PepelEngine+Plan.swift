import Foundation
import PEPELCleanup
import PEPELCore
import PEPELStorage

/// What the daily rules will do next, what they must leave alone, and taking back what they did.
extension PepelEngine {
    /// Keys of `RuleAction.id` the rules must not act on.
    var leftAlone: Set<String> { Set(settings.leaveAlone) }

    /// When a daily rule runs next, from when it last ran (without marking it as run).
    func nextRun(_ key: String, now: Date) -> Date {
        let last = store.value(key).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
        let low = (live?.telemetry.diskAvailableBytes ?? .max) < settings.lowDiskThresholdBytes && (live?.telemetry.diskTotalBytes ?? 0) > 0
        return max(now, last.addingTimeInterval(low ? 3600 : 20 * 3600))
    }

    /// Everything the switched-on daily rules would act on if they ran now, rule by rule, with
    /// when each runs next. Measures caches and folders, so it takes some seconds.
    public func actionPlan(now: Date = Date()) async -> ActionPlan {
        let s = settings, skip = leftAlone
        var actions: [RuleAction] = [], notes: [String] = []
        if s.paused { return ActionPlan(madeAt: now, actions: [], notes: ["PEPEL is paused: no rule runs until it is resumed."]) }
        func add(_ id: String, _ rule: RuleAction.Rule, _ title: String, _ path: String?, _ bytes: Int64, _ key: String, _ verb: String = "remove") {
            guard !skip.contains(id) else { return }
            actions.append(RuleAction(id: id, rule: rule, title: title, path: path, bytes: bytes, due: nextRun(key, now: now), verb: verb))
        }
        if s.dockerAutoClean {
            if let (_, plan) = await dockerCleanupPlan() {
                if plan.reproducibleBytes < Bytes.gb {
                    notes.append("Docker: less than 1 GB to remove, so the rule will not run.")
                } else {
                    for container in plan.containers { add("container:" + container.name, .docker, "Container " + container.name, nil, container.sizeBytes, "docker.lastAutoClean") }
                    if !plan.images.isEmpty { add("docker:images", .docker, "\(plan.images.count) image\(plan.images.count == 1 ? "" : "s") no container uses", nil, plan.bytes(.images), "docker.lastAutoClean") }
                    if plan.buildCacheBytes > 0 { add("docker:buildCache", .docker, "Build cache, \(plan.buildCacheEntries) entries", nil, plan.buildCacheBytes, "docker.lastAutoClean") }
                }
            } else {
                notes.append("Docker did not answer; its rule is skipped while it is not running.")
            }
        }
        if s.cleanStaleProjects {
            for project in staleProjects(now: now) {
                add(RuleAction.pathKey(project.id), .staleProjects, project.name + ": environments and build output", project.id, project.bytes, "stale.lastAutoClean")
            }
        }
        if s.trimCaches {
            for cache in await managedCaches(days: s.cacheUnusedDays) where cache.staleBytes > 0 {
                add("cache:" + cache.id, .toolCaches, "\(cache.title): \(cache.staleCount) unused entries", cache.path, cache.staleBytes, "caches.lastAutoTrim")
            }
        }
        if s.cleanAppCaches {
            let keep = Set(s.keepAppCaches.map { $0.lowercased() })
            for cache in Self.removableCaches(await applicationData().caches, days: s.appCacheUnusedDays, includeUnknown: false, keep: keep) {
                add(RuleAction.pathKey(cache.path), .appCaches, cache.name, cache.path, cache.bytes, "appcaches.lastAutoClean")
            }
        }
        if s.cleanOldLogs {
            let places = OtherPlaces(home: paths.home), days = s.logDays
            for path in await Task.detached(priority: .utility, operation: { places.oldLogs(days: days).files }).value {
                var info = stat()
                guard lstat(path, &info) == 0 else { continue }
                add(RuleAction.pathKey(path), .logs, (path as NSString).lastPathComponent, path, Int64(info.st_blocks) * 512, "logs.lastAutoClean")
            }
        }
        if s.cleanTempFiles {
            for entry in await tempEntries() where entry.keptBecause == nil {
                add(RuleAction.pathKey(entry.path), .temp, entry.name, entry.path, entry.bytes, "temp.lastAutoClean")
            }
        }
        if s.cleanAndroidEmulators {
            for emulator in await emulatorRuleCandidates() {
                add(RuleAction.pathKey(emulator.path), .emulators, emulator.name, emulator.path, emulator.bytes, "emulators.lastAutoClean")
            }
        }
        if s.cleanUnusedSystemImages {
            for image in await androidSystemImages() where image.usedBy.isEmpty {
                add(RuleAction.pathKey(image.path), .systemImages, image.id, image.path, image.bytes, "sysimages.lastAutoClean")
            }
        }
        if s.cleanToolBackups {
            for backup in await toolBackups(keep: s.toolBackupsKeep, days: s.toolBackupsDays) where !backup.kept {
                add(RuleAction.pathKey(backup.path), .toolBackups, backup.set + " · " + (backup.path as NSString).lastPathComponent, backup.path, backup.bytes, "toolbackups.lastAutoClean")
            }
        }
        if s.tidyScreenshots || s.tidyDownloads {
            let verb = s.tidyAction == .trash ? "move to the Trash" : "remove"
            for item in await tidyItems() where item.keptBecause == nil {
                let screenshot = item.kind == .screenshot
                guard screenshot ? s.tidyScreenshots : s.tidyDownloads else { continue }
                add(RuleAction.pathKey(item.path), screenshot ? .screenshots : .downloads, item.name, item.path, item.bytes, "tidy.lastAuto", verb)
            }
        }
        actions.sort { ($0.due, -$0.bytes) < ($1.due, -$1.bytes) }
        return ActionPlan(madeAt: now, actions: actions, notes: notes)
    }

    /// Puts items on the leave-alone list, or takes them off it.
    @discardableResult
    public func setLeftAlone(_ ids: [String], _ on: Bool) throws -> PepelSettings {
        try update { s in
            if on {
                for id in ids where !s.leaveAlone.contains(id) { s.leaveAlone.append(id) }
            } else {
                s.leaveAlone.removeAll { ids.contains($0) }
            }
        }
    }

    // MARK: Restore center

    /// What PEPEL removed over the last `days`: trashed items that can still be put back, those
    /// that cannot any more, and what was removed for good.
    public nonisolated func restoreCenter(days: Int = 14, now: Date = Date()) -> RestoreCenter {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        let records = store.trashed(since: since).filter { $0.restoredAt == nil }
        let restorable = records.filter { PathUtil.exists($0.trashedPath) && !PathUtil.exists($0.originalPath) }
        let ids = Set(restorable.map(\.id))
        let removed = store.audit(limit: 3000, kinds: [.cleanup]).filter { $0.timestamp >= since && ($0.outcome == "removed" || $0.outcome == "tool ran") }
        return RestoreCenter(restorable: restorable, gone: records.filter { !ids.contains($0.id) }, removed: removed)
    }

    /// Puts one trashed item back where it was.
    public nonisolated func restoreTrashed(id: Int64) -> String? {
        guard let record = store.trashed(since: .distantPast).first(where: { $0.id == id }) else { return "No such item." }
        if record.restoredAt != nil { return "It was already put back." }
        if let problem = restore(trashedPath: record.trashedPath, originalPath: record.originalPath) { return problem }
        store.markRestored(id: id)
        return nil
    }

    // MARK: PEPEL watching itself

    static let heavyTasksKey = "self.heavyTasks"

    /// The app says which heavy jobs it is running, so the command line can tell too.
    public nonisolated func setHeavyTasks(_ tasks: [String]) {
        try? store.saveCodable(tasks, key: Self.heavyTasksKey)
    }

    /// PEPEL's own processes (the app, and a command that is not this one), with their memory
    /// and their CPU share since the previous call.
    public func selfUsage(now: Date = Date()) -> SelfUsage {
        let me = getpid()
        let mine = processSource.snapshot().filter { process in
            guard process.pid != me || journaling else { return false }
            let path = process.executablePath ?? ""
            return path.hasSuffix("/PEPEL.app/Contents/MacOS/PEPEL") || (process.name == "pepel" && process.pid != me)
        }
        var readings: [Int32: (cpuNs: UInt64, at: Date)] = [:]
        let processes = mine.map { process -> SelfUsage.Process in
            readings[process.pid] = (process.cpuTimeNs, now)
            var cpu: Double?
            if let previous = lastSelfReading[process.pid], now.timeIntervalSince(previous.at) > 0.2, process.cpuTimeNs >= previous.cpuNs {
                cpu = Double(process.cpuTimeNs - previous.cpuNs) / 1e9 / now.timeIntervalSince(previous.at) * 100
            }
            return SelfUsage.Process(pid: process.pid, name: process.name, footprintBytes: process.footprintBytes, cpuPercent: cpu)
        }
        lastSelfReading = readings
        let heavy = processes.isEmpty ? [] : (store.loadCodable([String].self, key: Self.heavyTasksKey) ?? [])
        return SelfUsage(processes: processes, heavyTasks: heavy, at: now)
    }
}
