import Foundation

public struct DockerCleanResult: Sendable {
    /// Why nothing was done, when policy refused.
    public var denial: String?
    public var plan: DockerCleanupPlan?
    public var report: DockerCleanupReport?
}

/// Disk cleaning that goes beyond single artifacts: what Docker keeps, with ages.
extension PepelEngine {
    nonisolated func dockerDisk() -> DockerDisk {
        if let run = containerRunner { return DockerDisk(run: run) }
        return DockerDisk(tools: tools, home: paths.home)
    }

    /// Compose projects an agent session is working in right now, and what must be left alone.
    func dockerExclusions() -> (keep: Set<String>, active: Set<String>) {
        let active = Set((live?.containers?.groups ?? []).filter { $0.agentSessions > 0 }.map(\.id))
        return (Set(settings.keepContainers), active)
    }

    /// Asks Docker what it keeps on disk (a few seconds) and what a cleanup would remove.
    public func dockerCleanupPlan(days: Int? = nil) async -> (report: DockerDiskReport, plan: DockerCleanupPlan)? {
        if live == nil { await refreshLive() }
        let disk = dockerDisk()
        guard let report = await Task.detached(priority: .utility, operation: { disk.report() }).value else { return nil }
        lastDockerDisk = report
        let exclusions = dockerExclusions()
        return (report, DockerCleanupPlan.make(report, days: days ?? settings.dockerUnusedDays, keep: exclusions.keep, activeProjects: exclusions.active))
    }

    /// Removes what the plan names for the chosen kinds, then hands the freed space back to the Mac.
    public func cleanDocker(kinds: Set<DockerCleanKind>, days: Int? = nil, confirmed: Bool, initiator: Initiator, compact: Bool = true) async -> DockerCleanResult {
        if let denial = policy.dockerCleanDenial(kinds: kinds, confirmed: confirmed, initiator: initiator, settings: settings) {
            store.appendAudit(AuditEntry(kind: .cleanupDenied, initiator: initiator.rawValue, subject: "Docker cleanup", outcome: denial))
            return DockerCleanResult(denial: denial)
        }
        // Decided again from a reading taken now, not from the one that was shown.
        guard let (_, plan) = await dockerCleanupPlan(days: days) else { return DockerCleanResult(denial: "Docker did not answer.") }
        let disk = dockerDisk()
        let report = await Task.detached(priority: .utility) { disk.clean(plan, kinds: kinds, compact: compact) }.value
        let freed = max(report.freedOnDisk, 0)
        store.appendAudit(
            AuditEntry(
                kind: .cleanup, initiator: initiator.rawValue, subject: "Docker: " + report.steps.map { "\($0.kind.title.lowercased()) \($0.removed)/\($0.attempted)" }.joined(separator: ", "),
                outcome: "removed", bytes: max(freed, report.dockerBytesBefore - report.dockerBytesAfter),
                detail: [
                    "unusedForDays": "\(plan.days)", "dockerBefore": Bytes.format(report.dockerBytesBefore), "dockerAfter": Bytes.format(report.dockerBytesAfter),
                    "diskImageBefore": Bytes.format(report.diskImageBefore), "diskImageAfter": Bytes.format(report.diskImageAfter), "compact": report.compactNote,
                ]))
        lastDockerDisk = nil
        return DockerCleanResult(plan: plan, report: report)
    }

    /// At most once a day: what can be rebuilt or pulled again and has not been used for the configured time.
    func autoCleanDocker(now: Date = Date()) async -> DockerCleanupReport? {
        guard settings.dockerAutoClean, live?.containers != nil || containerRunner != nil else { return nil }
        guard dueDaily("docker.lastAutoClean", now: now) else { return nil }
        guard let (_, plan) = await dockerCleanupPlan(), plan.reproducibleBytes >= Bytes.gb else { return nil }
        return await cleanDocker(kinds: [.containers, .images, .buildCache, .networks], confirmed: false, initiator: .automatic).report
    }

    /// Trims the Docker VM's filesystem so its disk image on the Mac shrinks.
    public nonisolated func dockerDiskCompact() -> (done: Bool, note: String) { dockerDisk().compact() }
}

/// Artifacts of projects nobody has touched for a long time.
extension PepelEngine {
    /// What installing or building again brings back, inside a project.
    static let recreatable: Set<ArtifactCategory> = [.virtualEnvironment, .dependencies, .buildOutput, .dependencyCache, .toolCache]

    /// Records, on each recreatable artifact inside a project, when that project was last worked
    /// on. With the rule switched on, artifacts of projects untouched for the configured time
    /// become safe to remove; otherwise they are only marked, for the list of untouched projects.
    func applyStaleProjectRule(_ items: [StorageItem], now: Date) -> [StorageItem] {
        var byProject: [String: [Int]] = [:]
        for (index, item) in items.enumerated() {
            guard let projectID = item.projectID, item.projectConfidence == .verified, !item.hasPseudoPath, item.method == .filesystem,
                Self.recreatable.contains(item.category), item.reproducible, PathUtil.isInside(item.path, root: projectID)
            else { continue }
            byProject[projectID, default: []].append(index)
        }
        var result = items
        for (projectID, indices) in byProject {
            // A linked worktree is someone's parallel line of work; it is left out of this rule.
            guard let project = projectIndex.project(id: projectID), project.git?.isLinkedWorktree != true, !projectID.contains("/worktrees/") else { continue }
            var last = ProjectActivityProbe.lastActivity(root: projectID, gitDirectory: project.git?.commonDirectory, skip: Set(indices.map { items[$0].path }))
            // An agent session in the project right now is work, whatever the files say.
            if live?.agentSessions.contains(where: { $0.projectID == projectID }) == true { last = now }
            guard let last else { continue }
            let stale = now.timeIntervalSince(last) >= Double(settings.staleProjectDays) * 86_400
            for index in indices {
                result[index].projectLastActivity = last
                guard stale, settings.cleanStaleProjects, result[index].safety == .review else { continue }
                result[index].safety = .safe
                result[index].safetyReason = "Its project has not been touched for \(TimeFormat.age(now.timeIntervalSince(last))); installing or building again recreates this."
            }
        }
        return result
    }

    /// Untouched projects with what their recreatable artifacts hold, largest first.
    public func staleProjects(days: Int? = nil, now: Date = Date()) -> [StaleProject] {
        let limit = days ?? settings.staleProjectDays
        var groups: [String: StaleProject] = [:]
        for item in storage?.items ?? [] where item.safety != .protected && item.isStale(days: limit, now: now) && storage?.inUse[item.id] == nil {
            guard let projectID = item.projectID, let last = item.projectLastActivity else { continue }
            var entry = groups[projectID] ?? StaleProject(id: projectID, name: projectIndex.project(id: projectID)?.name ?? (projectID as NSString).lastPathComponent, lastActivity: last, bytes: 0, itemIDs: [])
            entry.bytes += item.reclaimableBytes
            entry.itemIDs.append(item.id)
            groups[projectID] = entry
        }
        return groups.values.sorted { $0.bytes > $1.bytes }
    }

    /// Removes the recreatable artifacts of untouched projects. Each one still passes the
    /// ordinary policy: in use, recently written, leased, pinned or excluded means it stays.
    public func cleanStaleProjects(days: Int? = nil, confirmed: Bool, initiator: Initiator, dryRun: Bool = false) async -> CleanupReport? {
        let ids = Set(staleProjects(days: days).flatMap(\.itemIDs))
        guard !ids.isEmpty else { return nil }
        let plan = await cleanupPlan(itemIDs: ids, initiator: initiator)
        return await executeCleanup(plan, confirmed: confirmed ? ids : [], dryRun: dryRun)
    }

    /// At most once a day, when the rule is on.
    func autoCleanStaleProjects(now: Date = Date()) async -> CleanupReport? {
        guard settings.cleanStaleProjects, !settings.paused, storage != nil else { return nil }
        guard dueDaily("stale.lastAutoClean", now: now) else { return nil }
        return await cleanStaleProjects(confirmed: false, initiator: .automatic)
    }
}

/// Tool caches kept in bounds by age.
extension PepelEngine {
    /// Measures every known cache (walks them; tens of seconds for large ones).
    public nonisolated func managedCaches(days: Int) async -> [ManagedCache] {
        let trimmer = CacheTrimmer(home: paths.home)
        return await Task.detached(priority: .utility) { trimmer.measure(days: days) }.value
    }

    public func trimCaches(ids: Set<String>? = nil, days: Int? = nil, limitGB: Int? = nil, confirmed: Bool, initiator: Initiator) async -> (denial: String?, report: CacheTrimReport?) {
        if let denial = policy.cacheTrimDenial(confirmed: confirmed, initiator: initiator, settings: settings) { return (denial, nil) }
        let age = days ?? settings.cacheUnusedDays
        let cap = limitGB ?? settings.cacheSizeLimitGB
        let maxBytes: Int64? = cap > 0 ? Int64(cap) * Bytes.gb : nil
        let trimmer = CacheTrimmer(home: paths.home)
        let wanted = CacheTrimmer.caches.filter { ids?.contains($0.id) ?? true }
        // A cache is left alone while the tool that owns it is running.
        let running = Set(processSource.snapshot().map(\.name))
        let read = readTelemetry
        let before = read().diskAvailableBytes
        let steps = await Task.detached(priority: .utility) {
            wanted.map { definition -> CacheTrimReport.Step in
                let result = trimmer.trim(definition.id, days: age, maxBytes: maxBytes, running: running)
                return CacheTrimReport.Step(id: definition.id, title: definition.title, bytes: result.bytes, removed: result.removed)
            }
            .filter { $0.removed > 0 }
        }.value
        let report = CacheTrimReport(days: age, steps: steps, diskAvailableBefore: before, diskAvailableAfter: read().diskAvailableBytes)
        if !steps.isEmpty {
            store.appendAudit(
                AuditEntry(
                    kind: .cleanup, initiator: initiator.rawValue, subject: "Tool caches: " + steps.map { "\($0.title) \(Bytes.format($0.bytes))" }.joined(separator: ", "),
                    outcome: "removed", bytes: report.bytes, detail: ["unusedForDays": "\(age)", "sizeLimit": cap > 0 ? "\(cap) GB" : "none", "entries": "\(steps.reduce(0) { $0 + $1.removed })"]))
        }
        return (nil, report)
    }

    func autoTrimCaches(now: Date = Date()) async -> CacheTrimReport? {
        guard settings.trimCaches, !settings.paused else { return nil }
        guard dueDaily("caches.lastAutoTrim", now: now) else { return nil }
        return await trimCaches(confirmed: false, initiator: .automatic).report
    }
}

public struct ApplicationDataReport: Codable, Sendable {
    public var kind: ApplicationData.Kind
    public var removed: [String]
    public var kept: [String]
    public var bytes: Int64
}

/// Application caches, and what removed applications left in the Library.
extension PepelEngine {
    func applicationScanner() async -> ApplicationDataScanner {
        let tools = tools, home = paths.home
        let installed: InstalledApplications
        if let fixed = installedApplicationsOverride {
            installed = fixed
        } else {
            installed = await Task.detached(priority: .utility) { InstalledApplications.find(tools: tools, home: home) }.value
        }
        var running = Set<String>()
        for app in applicationControl.running() {
            if let data = FileManager.default.contents(atPath: app.bundlePath + "/Contents/Info.plist"),
                let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any], let id = plist["CFBundleIdentifier"] as? String
            {
                running.insert(id)
            }
        }
        return ApplicationDataScanner(home: home, installed: installed, running: running)
    }

    /// Measures application caches and leftovers (walks the folders; some seconds).
    public func applicationData() async -> (caches: [ApplicationData], leftovers: [ApplicationData]) {
        let scanner = await applicationScanner()
        let days = settings.leftoverDays
        return await Task.detached(priority: .utility) { (scanner.caches(), scanner.leftovers().filter { $0.unused(days: days) }) }.value
    }

    /// Caches the rule would remove: the application is installed but not running, or gone, and
    /// nothing in the cache was used for `days`. Caches PEPEL cannot tie to anything are added only on request.
    static func removableCaches(_ caches: [ApplicationData], days: Int, includeUnknown: Bool, keep: Set<String> = []) -> [ApplicationData] {
        caches.filter { cache in
            guard cache.unused(days: days), !keep.contains(cache.name.lowercased()) else { return false }
            switch cache.owner {
            case .running: return false
            case .installed, .removed: return true
            case .unknown: return includeUnknown
            }
        }
    }

    public func cleanApplicationCaches(days: Int? = nil, includeUnknown: Bool = false, confirmed: Bool, initiator: Initiator) async -> (denial: String?, report: ApplicationDataReport?) {
        if let denial = policy.applicationDataDenial(.cache, confirmed: confirmed, initiator: initiator, settings: settings) { return (denial, nil) }
        let scanner = await applicationScanner()
        let age = days ?? settings.appCacheUnusedDays
        let keep = Set(settings.keepAppCaches.map { $0.lowercased() })
        let report = await Task.detached(priority: .utility) { () -> ApplicationDataReport in
            // Measured now, so that what is removed is what is there now.
            var report = ApplicationDataReport(kind: .cache, removed: [], kept: [], bytes: 0)
            for cache in Self.removableCaches(scanner.caches(), days: age, includeUnknown: includeUnknown, keep: keep) {
                guard scanner.isManageable(cache), (try? FileManager.default.removeItem(atPath: cache.path)) != nil else {
                    report.kept.append(cache.name)
                    continue
                }
                report.removed.append(cache.name)
                report.bytes += cache.bytes
            }
            return report
        }.value
        if !report.removed.isEmpty {
            store.appendAudit(
                AuditEntry(
                    kind: .cleanup, initiator: initiator.rawValue, subject: "Application caches: \(report.removed.count)", outcome: "removed", bytes: report.bytes,
                    detail: ["unusedForDays": "\(age)", "names": report.removed.prefix(40).joined(separator: ", ")]))
        }
        return (nil, report)
    }

    /// Moves what removed applications left behind to the Trash, where it can be taken back.
    public func trashApplicationLeftovers(confirmed: Bool, initiator: Initiator) async -> (denial: String?, report: ApplicationDataReport?) {
        if let denial = policy.applicationDataDenial(.leftover, confirmed: confirmed, initiator: initiator, settings: settings) { return (denial, nil) }
        let scanner = await applicationScanner()
        let days = settings.leftoverDays
        let report = await Task.detached(priority: .utility) { () -> ApplicationDataReport in
            var report = ApplicationDataReport(kind: .leftover, removed: [], kept: [], bytes: 0)
            for item in scanner.leftovers() where item.unused(days: days) {
                guard scanner.isManageable(item), (try? FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)) != nil else {
                    report.kept.append(item.name)
                    continue
                }
                report.removed.append(item.name)
                report.bytes += item.bytes
            }
            return report
        }.value
        if !report.removed.isEmpty {
            store.appendAudit(
                AuditEntry(
                    kind: .cleanup, initiator: initiator.rawValue, subject: "Left by removed applications: \(report.removed.count)", outcome: "trashed", bytes: report.bytes,
                    detail: ["names": report.removed.prefix(40).joined(separator: ", ")]))
        }
        return (nil, report)
    }

    func autoCleanApplicationCaches(now: Date = Date()) async {
        guard settings.cleanAppCaches, !settings.paused else { return }
        guard dueDaily("appcaches.lastAutoClean", now: now) else { return }
        _ = await cleanApplicationCaches(confirmed: false, initiator: .automatic)
    }
}

/// Other large places, old logs, the disk forecast, and when the daily rules run.
extension PepelEngine {
    public nonisolated func otherPlaces() async -> [OtherPlace] {
        let places = OtherPlaces(home: paths.home)
        return await Task.detached(priority: .utility) { places.measure() }.value
    }

    public nonisolated func oldLogs(days: Int) async -> (bytes: Int64, count: Int) {
        let places = OtherPlaces(home: paths.home)
        let found = await Task.detached(priority: .utility) { places.oldLogs(days: days) }.value
        return (found.bytes, found.files.count)
    }

    public func removeOldLogs(days: Int? = nil, confirmed: Bool, initiator: Initiator) async -> (denial: String?, bytes: Int64, removed: Int) {
        switch initiator {
        case .agent: return ("Agents cannot have logs removed.", 0, 0)
        case .automatic: if !settings.cleanOldLogs || settings.paused { return ("Automatic removal of old logs is not enabled.", 0, 0) }
        case .user, .cli: if !confirmed { return ("This needs your confirmation.", 0, 0) }
        }
        let places = OtherPlaces(home: paths.home), age = days ?? settings.logDays
        let result = await Task.detached(priority: .utility) { places.removeOldLogs(days: age) }.value
        if result.removed > 0 {
            store.appendAudit(
                AuditEntry(kind: .cleanup, initiator: initiator.rawValue, subject: "Old logs: \(result.removed) files", outcome: "removed", bytes: result.bytes, detail: ["olderThanDays": "\(age)"]))
        }
        return (nil, result.bytes, result.removed)
    }

    /// From the recorded growth of the last week (or as much as there is, at least two days).
    public nonisolated func diskForecast(now: Date = Date()) -> DiskForecast? {
        guard let growth = store.diskGrowth(window: 7 * 86_400, now: now), let latest = store.telemetryHistory(since: now.addingTimeInterval(-86_400)).last else { return nil }
        return DiskForecast.project(grownBytes: growth.deltaBytes, over: growth.actualSpan, availableBytes: latest.diskAvailable, now: now)
    }

    /// Whether a daily rule is due: once in twenty hours, or once an hour while disk space is low.
    func dueDaily(_ key: String, now: Date) -> Bool {
        let last = store.value(key).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
        let low = (live?.telemetry.diskAvailableBytes ?? .max) < settings.lowDiskThresholdBytes && (live?.telemetry.diskTotalBytes ?? 0) > 0
        guard now.timeIntervalSince(last) >= (low ? 3600 : 20 * 3600) else { return false }
        try? store.setValue(String(now.timeIntervalSince1970), for: key)
        return true
    }

    func autoRemoveOldLogs(now: Date = Date()) async {
        guard settings.cleanOldLogs, !settings.paused, dueDaily("logs.lastAutoClean", now: now) else { return }
        _ = await removeOldLogs(confirmed: false, initiator: .automatic)
    }
}

/// The temporary folder.
extension PepelEngine {
    /// Names of running programs and the paths they work in, so that nothing in use is removed.
    func runningPrograms() -> (names: Set<String>, paths: [String]) {
        let processes = processSource.snapshot()
        var names = Set(processes.map(\.name))
        for app in applicationControl.running() {
            names.insert(app.name)
            if let data = FileManager.default.contents(atPath: app.bundlePath + "/Contents/Info.plist"),
                let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any], let id = plist["CFBundleIdentifier"] as? String
            {
                names.insert(id)
            }
        }
        let paths = processes.flatMap { [$0.workingDirectory].compactMap { $0 } + $0.arguments.filter { $0.hasPrefix("/") } }
        return (names, paths)
    }

    public func tempEntries(days: Int? = nil) async -> [TempEntry] {
        let cleaner = TempCleaner(directory: paths.temporaryDirectory), running = runningPrograms(), age = days ?? settings.tempDays
        return await Task.detached(priority: .utility) { cleaner.entries(days: age, running: running.names, busyPaths: running.paths) }.value
    }

    public func cleanTemp(days: Int? = nil, confirmed: Bool, initiator: Initiator) async -> (denial: String?, bytes: Int64, removed: Int) {
        switch initiator {
        case .agent: return ("Agents cannot have temporary files removed.", 0, 0)
        case .automatic: if !settings.cleanTempFiles || settings.paused { return ("Automatic cleaning of the temporary folder is not enabled.", 0, 0) }
        case .user, .cli: if !confirmed { return ("This needs your confirmation.", 0, 0) }
        }
        let cleaner = TempCleaner(directory: paths.temporaryDirectory), running = runningPrograms(), age = days ?? settings.tempDays
        let result = await Task.detached(priority: .utility) { cleaner.clean(days: age, running: running.names, busyPaths: running.paths) }.value
        if result.removed > 0 {
            store.appendAudit(
                AuditEntry(kind: .cleanup, initiator: initiator.rawValue, subject: "Temporary folder: \(result.removed) entries", outcome: "removed", bytes: result.bytes, detail: ["unusedForDays": "\(age)"]))
        }
        return (nil, result.bytes, result.removed)
    }

    func autoCleanTemp(now: Date = Date()) async {
        guard settings.cleanTempFiles, !settings.paused, dueDaily("temp.lastAutoClean", now: now) else { return }
        _ = await cleanTemp(confirmed: false, initiator: .automatic)
    }
}
