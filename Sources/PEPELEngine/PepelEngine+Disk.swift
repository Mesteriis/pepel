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
        let skipped = leftAlone.filter { $0.hasPrefix("container:") }.map { String($0.dropFirst("container:".count)) }
        return (Set(settings.keepContainers).union(skipped), active)
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
        guard let (_, plan) = await dockerCleanupPlan(days: days) else { return DockerCleanResult(denial: L("Docker did not answer.")) }
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
        let kinds = Set<DockerCleanKind>([.containers, .images, .buildCache, .networks]).filter { !leftAlone.contains("docker:" + $0.rawValue) }
        guard !kinds.isEmpty else { return nil }
        return await cleanDocker(kinds: kinds, confirmed: false, initiator: .automatic).report
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
                guard stale, settings.cleanStaleProjects, result[index].safety == .review, !leftAlone.contains(RuleAction.pathKey(projectID)) else { continue }
                result[index].safety = .safe
                result[index].safetyReason = L("Its project has not been touched for \(TimeFormat.age(now.timeIntervalSince(last))); installing or building again recreates this.")
            }
        }
        return result
    }

    /// Untouched projects with what their recreatable artifacts hold, largest first.
    public func staleProjects(days: Int? = nil, now: Date = Date()) -> [StaleProject] {
        let limit = days ?? settings.staleProjectDays
        var groups: [String: StaleProject] = [:]
        for item in storage?.items ?? [] where item.safety != .protected && item.isStale(days: limit, now: now) && storage?.inUse[item.id] == nil {
            guard let projectID = item.projectID, let last = item.projectLastActivity, !leftAlone.contains(RuleAction.pathKey(projectID)) else { continue }
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
        let skip = leftAlone
        let wanted = CacheTrimmer.caches.filter { (ids?.contains($0.id) ?? true) && !skip.contains("cache:" + $0.id) }
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
    /// Where trashed items went, for the restore center.
    public var trashed: [TrashRecord] = []

    enum CodingKeys: String, CodingKey { case kind, removed, kept, bytes }
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
        let keep = Set(settings.keepAppCaches.map { $0.lowercased() }), skip = leftAlone
        let report = await Task.detached(priority: .utility) { () -> ApplicationDataReport in
            // Measured now, so that what is removed is what is there now.
            var report = ApplicationDataReport(kind: .cache, removed: [], kept: [], bytes: 0)
            for cache in Self.removableCaches(scanner.caches(), days: age, includeUnknown: includeUnknown, keep: keep) where !skip.contains(RuleAction.pathKey(cache.path)) {
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
                var resulting: NSURL?
                guard scanner.isManageable(item), (try? FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: &resulting)) != nil else {
                    report.kept.append(item.name)
                    continue
                }
                report.removed.append(item.name)
                report.bytes += item.bytes
                if let to = resulting?.path { report.trashed.append(TrashRecord(source: "Left by removed applications", originalPath: item.path, trashedPath: to, bytes: item.bytes)) }
            }
            return report
        }.value
        for record in report.trashed { store.recordTrashed(record) }
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
        case .agent: return (L("Agents cannot have logs removed."), 0, 0)
        case .automatic: if !settings.cleanOldLogs || settings.paused { return (L("Automatic removal of old logs is not enabled."), 0, 0) }
        case .user, .cli: if !confirmed { return (L("This needs your confirmation."), 0, 0) }
        }
        let places = OtherPlaces(home: paths.home), age = days ?? settings.logDays, skip = leftAlone
        let result = await Task.detached(priority: .utility) { places.removeOldLogs(days: age, skip: skip) }.value
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
        case .agent: return (L("Agents cannot have temporary files removed."), 0, 0)
        case .automatic: if !settings.cleanTempFiles || settings.paused { return (L("Automatic cleaning of the temporary folder is not enabled."), 0, 0) }
        case .user, .cli: if !confirmed { return (L("This needs your confirmation."), 0, 0) }
        }
        let cleaner = TempCleaner(directory: paths.temporaryDirectory), running = runningPrograms(), age = days ?? settings.tempDays
        // What was chosen to be left alone counts as in use.
        let busy = running.paths + leftAlone.filter { $0.hasPrefix("path:") }.map { String($0.dropFirst(5)) }
        let result = await Task.detached(priority: .utility) { cleaner.clean(days: age, running: running.names, busyPaths: busy) }.value
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

/// Large folders that git ignores inside projects and no analyzer recognises.
extension PepelEngine {
    /// Names that hold secrets or the repository itself; never listed, whatever their size.
    static let neverIgnoredCandidates: Set<String> = [".git", ".env", ".envrc", ".ssh", ".gnupg", ".aws", ".kube", "secrets", ".secrets"]
    /// Agents' own working state and worktrees: never offered, per the owner's rules.
    static let agentFolders: Set<String> = [".claude", ".codex", ".hermes", ".opencode", ".superset", "worktrees", ".worktrees"]

    /// Asks git, per project, which folders it ignores, and measures those that no analyzer
    /// accounts for. Linked worktrees are left out: they are someone's parallel line of work.
    public func ignoredFolders(minimumBytes: Int64 = 500 * Bytes.mb) async -> [IgnoredFolder] {
        if projects.isEmpty { _ = await refreshProjects() }
        guard tools.locate("git") != nil else { return [] }
        let known = (storage?.items ?? []).filter { !$0.hasPseudoPath }.map(\.path)
        let candidates = projects.filter { $0.git != nil && $0.git?.isLinkedWorktree != true }
        let tools = tools
        return await Task.detached(priority: .utility) { () -> [IgnoredFolder] in
            var result: [IgnoredFolder] = []
            var seen = Set<String>()
            let sizer = DirectorySizer(), ledger = HardLinkLedger()
            for project in candidates {
                guard let listed = tools.run("git", ["-C", project.id, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory"], timeout: 30), listed.status == 0 else { continue }
                // Outermost folders only: a folder inside another listed one is part of it.
                let relatives = listed.output.split(separator: "\n").filter { $0.hasSuffix("/") }.map { String($0.dropLast()) }.sorted()
                var outermost: [String] = []
                for relative in relatives where !outermost.contains(where: { relative.hasPrefix($0 + "/") }) { outermost.append(relative) }
                for relative in outermost {
                    let path = project.id + "/" + relative
                    let name = (relative as NSString).lastPathComponent
                    let parts = Set(relative.lowercased().split(separator: "/").map(String.init))
                    guard !Self.neverIgnoredCandidates.contains(name.lowercased()), !name.lowercased().hasPrefix(".env"), parts.isDisjoint(with: Self.agentFolders), seen.insert(path).inserted
                    else { continue }
                    // Something PEPEL already knows (node_modules, .venv, build output) has its own rules.
                    guard !known.contains(where: { $0 == path || path.hasPrefix($0 + "/") }) else { continue }
                    var info = stat()
                    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
                    // Files with several names are counted once, as everywhere else in PEPEL.
                    let measured = sizer.measure(path, ledger: ledger)
                    guard measured.allocatedBytes >= minimumBytes else { continue }
                    var folder = IgnoredFolder(path: path, projectID: project.id, projectName: project.groupName, bytes: measured.allocatedBytes, lastUse: measured.newestModification)
                    folder.looksLikeData = IgnoredFolder.looksLikeData(relative)
                    result.append(folder)
                }
            }
            return result.sorted { $0.bytes > $1.bytes }
        }.value
    }

    /// Moves one such folder to the Trash after checking it again. In a redirected PEPEL (tests,
    /// `PEPEL_HOME`) the "Trash" is the redirected home's, never the real one.
    public func trashIgnoredFolder(_ path: String, confirmed: Bool, initiator: Initiator) async -> String? {
        guard initiator == .user || initiator == .cli else { return L("Only you can have this moved to the Trash.") }
        guard confirmed else { return L("This needs your confirmation.") }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return L("It is not a folder any more.") }
        guard projects.contains(where: { path.hasPrefix($0.id + "/") }) else { return L("It is not inside a known project.") }
        let context = await policyContext(for: [])
        if let violation = policy.pathViolation(path, context: context) { return violation }
        if let lease = context.leases.first(where: { $0.isActive(at: Date()) && $0.covers(path) }) { return L("Leased by \(lease.owner).") }
        if lastProcesses.contains(where: { ($0.workingDirectory ?? "") == path || ($0.workingDirectory ?? "").hasPrefix(path + "/") }) { return L("A running program works in it.") }
        let window = TimeInterval(settings.recentWriteProtectionMinutes) * 60
        if CleanupExecutor.hasRecentWrites(path, within: window, now: Date()) { return L("Something was written in it in the last \(settings.recentWriteProtectionMinutes) minutes.") }
        let bytes = ApplicationDataScanner.measure(path).bytes
        let destination: String
        if paths.isRedirected {
            let trash = paths.home + "/.Trash"
            try? FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
            destination = trash + "/" + (path as NSString).lastPathComponent + "-" + UUID().uuidString.prefix(6)
            guard (try? FileManager.default.moveItem(atPath: path, toPath: destination)) != nil else { return L("It could not be moved.") }
        } else {
            var resulting: NSURL?
            guard (try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)) != nil else { return L("It could not be moved to the Trash.") }
            destination = resulting?.path ?? ""
        }
        if !destination.isEmpty { store.recordTrashed(TrashRecord(source: "Ignored folder", originalPath: path, trashedPath: destination, bytes: bytes)) }
        store.appendAudit(AuditEntry(kind: .cleanup, initiator: initiator.rawValue, subject: "Ignored folder \((path as NSString).lastPathComponent)", outcome: "trashed", bytes: bytes, detail: ["path": path]))
        return nil
    }
}

/// Android virtual devices.
extension PepelEngine {
    public func androidEmulators() async -> [AndroidEmulator] {
        let emulators = AndroidEmulators(home: paths.home), running = AndroidEmulators.runningNames(processSource.snapshot())
        return await Task.detached(priority: .utility) { emulators.list(running: running) }.value
    }

    /// Why the daily rule would leave this emulator alone, or nil when it would delete it.
    func emulatorRuleRefusal(_ emulator: AndroidEmulator, now: Date = Date()) -> String? {
        if emulator.running { return L("It is running.") }
        if settings.keepEmulators.contains(where: { $0.caseInsensitiveCompare(emulator.name) == .orderedSame }) { return L("It is on the keep list.") }
        if leftAlone.contains(RuleAction.pathKey(emulator.path)) { return L("It is on the leave-alone list.") }
        guard let last = emulator.lastUse else { return L("PEPEL cannot tell when it was last started.") }
        let unused = now.timeIntervalSince(last)
        if unused < Double(settings.emulatorUnusedDays) * 86_400 {
            return L("Started \(TimeFormat.age(unused)) ago; the rule waits \(settings.emulatorUnusedDays) days.")
        }
        return nil
    }

    /// Deletes one emulator for good. A person can ask for any that is not running; the daily
    /// rule only for one it is switched on for, unused long enough and not kept.
    public func deleteAndroidEmulator(_ name: String, confirmed: Bool, initiator: Initiator) async -> String? {
        switch initiator {
        case .agent: return L("Agents cannot delete emulators.")
        case .automatic:
            guard settings.cleanAndroidEmulators, !settings.paused else { return L("Deleting unused emulators is not enabled.") }
            // Decided again on a fresh reading, right before deleting.
            guard let emulator = await androidEmulators().first(where: { $0.name == name }) else { return L("No such emulator.") }
            if let refusal = emulatorRuleRefusal(emulator) { return refusal }
        case .user, .cli:
            guard confirmed else { return L("This needs your confirmation.") }
        }
        let emulators = AndroidEmulators(home: paths.home), running = AndroidEmulators.runningNames(processSource.snapshot())
        let bytes = emulators.folder(of: name).map { DirectorySizer().measure($0).allocatedBytes } ?? 0
        if let refusal = await Task.detached(priority: .utility, operation: { emulators.delete(name, running: running) }).value { return refusal }
        store.appendAudit(AuditEntry(kind: .cleanup, initiator: initiator.rawValue, subject: "Android emulator \(name)", outcome: "removed", bytes: bytes))
        return nil
    }
}

/// Large old files and duplicates: a report, never an action.
extension PepelEngine {
    public nonisolated func largeFiles(days: Int = 90, includeGuarded: Bool = false) async -> LargeFilesReport {
        let finder = LargeFiles(home: paths.home)
        return await Task.detached(priority: .utility) { finder.report(days: days, includeGuarded: includeGuarded) }.value
    }
}

extension PepelEngine {
    /// Emulators the daily rule would delete now, with what it would free.
    public func emulatorRuleCandidates() async -> [AndroidEmulator] {
        let now = Date()
        return await androidEmulators().filter { emulatorRuleRefusal($0, now: now) == nil }
    }

    func autoCleanEmulators(now: Date = Date()) async {
        guard settings.cleanAndroidEmulators, !settings.paused, dueDaily("emulators.lastAutoClean", now: now) else { return }
        for emulator in await emulatorRuleCandidates() {
            _ = await deleteAndroidEmulator(emulator.name, confirmed: false, initiator: .automatic)
        }
    }
}

/// Android system images no emulator starts from.
extension PepelEngine {
    /// Overrides where the Android SDK is looked for; tests point it at a fixture.
    nonisolated var androidSDKRoots: [String]? { paths.isRedirected ? [paths.home + "/Library/Android/sdk"] : nil }

    public nonisolated func androidSystemImages() async -> [AndroidSystemImage] {
        let images = AndroidSystemImages(home: paths.home, sdkRoots: androidSDKRoots)
        return await Task.detached(priority: .utility) { images.list() }.value
    }

    public func deleteSystemImage(_ id: String, confirmed: Bool, initiator: Initiator) async -> String? {
        switch initiator {
        case .agent: return L("Agents cannot delete system images.")
        case .automatic: guard settings.cleanUnusedSystemImages, !settings.paused else { return L("Deleting unused system images is not enabled.") }
        case .user, .cli: guard confirmed else { return L("This needs your confirmation.") }
        }
        let images = AndroidSystemImages(home: paths.home, sdkRoots: androidSDKRoots)
        let bytes = images.list().first { $0.id == id }?.bytes ?? 0
        if let refusal = await Task.detached(priority: .utility, operation: { images.delete(id) }).value { return refusal }
        store.appendAudit(AuditEntry(kind: .cleanup, initiator: initiator.rawValue, subject: "Android system image \(id)", outcome: "removed", bytes: bytes))
        return nil
    }

    func autoCleanSystemImages(now: Date = Date()) async {
        guard settings.cleanUnusedSystemImages, !settings.paused, dueDaily("sysimages.lastAutoClean", now: now) else { return }
        for image in await androidSystemImages() where image.usedBy.isEmpty && !leftAlone.contains(RuleAction.pathKey(image.path)) {
            _ = await deleteSystemImage(image.id, confirmed: false, initiator: .automatic)
        }
    }
}


extension PepelEngine {
    /// Named volumes no container mounts, with whether their project is still on this Mac.
    public func namedVolumes() async -> [NamedVolumeReport]? {
        guard let (report, _) = await dockerCleanupPlan() else { return nil }
        var folders: [String: String] = [:]
        for project in projects { folders[(project.id as NSString).lastPathComponent.lowercased()] = project.id }
        return NamedVolumeReport.make(report, projectFolders: folders)
    }
}

/// Backups tools make of agents' state (Clausona), kept by count and age.
extension PepelEngine {
    public nonisolated func toolBackups(keep: Int, days: Int) async -> [ToolBackup] {
        let backups = ToolBackups(home: paths.home)
        return await Task.detached(priority: .utility) { backups.list(keep: keep, days: days) }.value
    }

    public func cleanToolBackups(keep: Int? = nil, days: Int? = nil, confirmed: Bool, initiator: Initiator) async -> (denial: String?, bytes: Int64, removed: Int, skipped: [String]) {
        switch initiator {
        case .agent: return (L("Agents cannot remove backups."), 0, 0, [])
        case .automatic: if !settings.cleanToolBackups || settings.paused { return (L("Retention for tool backups is not enabled."), 0, 0, []) }
        case .user, .cli: if !confirmed { return (L("This needs your confirmation."), 0, 0, []) }
        }
        let backups = ToolBackups(home: paths.home), count = max(0, keep ?? settings.toolBackupsKeep), age = max(0, days ?? settings.toolBackupsDays)
        let read = readTelemetry
        let before = read().diskAvailableBytes
        let skip = leftAlone
        let result = await Task.detached(priority: .utility) { backups.clean(keep: count, days: age, skip: skip) }.value
        // Backups are often clones of the live files and share their blocks: removing them frees
        // far less than their size. What is recorded is what the disk measured, not the sum of sizes.
        let freed = max(0, read().diskAvailableBytes - before)
        if result.removed > 0 {
            store.appendAudit(
                AuditEntry(
                    kind: .cleanup, initiator: initiator.rawValue, subject: "Clausona backups: \(result.removed)", outcome: "removed", bytes: freed,
                    detail: ["keepNewest": "\(count)", "olderThanDays": "\(age)", "sizeOfRemoved": Bytes.format(result.bytes), "measuredFree": Bytes.format(freed)]))
        }
        return (nil, freed, result.removed, result.skipped)
    }

    func autoCleanToolBackups(now: Date = Date()) async {
        guard settings.cleanToolBackups, !settings.paused, dueDaily("toolbackups.lastAutoClean", now: now) else { return }
        _ = await cleanToolBackups(confirmed: false, initiator: .automatic)
    }
}

/// Downloads and screenshots.
extension PepelEngine {
    nonisolated func tidy() -> Tidy { Tidy(home: paths.home, screenshotLocation: paths.isRedirected ? nil : Tidy.systemScreenshotLocation()) }

    public func tidyItems(screenshotDays: Int? = nil, downloadDays: Int? = nil) async -> [TidyItem] {
        let tidy = tidy(), shots = screenshotDays ?? settings.screenshotDays, days = downloadDays ?? settings.downloadDays, keep = Set(settings.tidyKeepExtensions)
        return await Task.detached(priority: .utility) { tidy.items(screenshotDays: shots, downloadDays: days, keepExtensions: keep) }.value
    }

    /// - Parameters:
    ///   - screenshots, downloads: which part to tidy; the daily rule uses the settings.
    public func runTidy(screenshots: Bool, downloads: Bool, confirmed: Bool, initiator: Initiator, action: TidyAction? = nil) async -> (denial: String?, bytes: Int64, removed: Int) {
        var shots = screenshots, files = downloads
        switch initiator {
        case .agent: return (L("Agents cannot tidy your files."), 0, 0)
        case .automatic:
            guard !settings.paused else { return (L("PEPEL is paused."), 0, 0) }
            shots = shots && settings.tidyScreenshots
            files = files && settings.tidyDownloads
            if !shots && !files { return (L("Tidying is not enabled."), 0, 0) }
        case .user, .cli: if !confirmed { return (L("This needs your confirmation."), 0, 0) }
        }
        let tidy = tidy(), chosen = action ?? settings.tidyAction, keep = Set(settings.tidyKeepExtensions)
        let shotDays = settings.screenshotDays, days = settings.downloadDays
        let trash: String? = paths.isRedirected ? paths.home + "/.Trash" : nil
        let skip = leftAlone
        let result = await Task.detached(priority: .utility) {
            tidy.clean(screenshotDays: shotDays, downloadDays: days, keepExtensions: keep, includeScreenshots: shots, includeDownloads: files, action: chosen, trashDirectory: trash, skip: skip)
        }.value
        for record in result.trashed { store.recordTrashed(record) }
        if result.removed > 0 {
            store.appendAudit(
                AuditEntry(
                    kind: .cleanup, initiator: initiator.rawValue, subject: "Downloads and screenshots: \(result.removed)", outcome: chosen == .trash ? "trashed" : "removed",
                    bytes: result.bytes, detail: ["screenshotDays": "\(shotDays)", "downloadDays": "\(days)"]))
        }
        return (nil, result.bytes, result.removed)
    }

    func autoTidy(now: Date = Date()) async {
        guard settings.tidyScreenshots || settings.tidyDownloads, !settings.paused, dueDaily("tidy.lastAuto", now: now) else { return }
        _ = await runTidy(screenshots: true, downloads: true, confirmed: false, initiator: .automatic)
    }
}
