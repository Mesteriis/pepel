import Foundation

/// The single entry point used by the app, the CLI and the agent API. It owns no policy of its
/// own: it gathers current facts and hands them to the guardians and the cleanup policy engine.
public actor PepelEngine {
    public nonisolated let paths: AppPaths
    public nonisolated let store: PepelStore
    public nonisolated let tools: ToolRunner
    public nonisolated let coordinator: ScanCoordinator
    nonisolated let processSource: any ProcessSource
    nonisolated let readTelemetry: @Sendable () -> SystemTelemetry
    nonisolated let policy = CleanupPolicyEngine()

    var settings: PepelSettings
    var projects: [Project] = []
    var projectIndex = ProjectIndex([])
    var history: [ProcessIdentity: [ProcessObservation]] = [:]
    var historyLoaded = false
    var lastObservationWrite = Date.distantPast
    var lastTelemetryWrite = Date.distantPast
    var lastProcesses: [ProcessSnapshot] = []
    /// Per repository group: the last moment an agent session was seen in it (or, for a project
    /// first seen without one, when PEPEL started watching it).
    var projectActivity: [String: Date] = [:]
    var projectActivityWritten = Date.distantPast
    /// Idle sessions the user explicitly chose to end in a "Free memory" pass; empty otherwise.
    var manualSleepOverride: [ProcessIdentity: [String]] = [:]
    var containerReport: ContainerReport?
    var fileCacheFlusher: FileCacheFlusher = .unavailable
    var containerPeaks: [Int: Int64]?
    var applicationControl: ApplicationControl = .unavailable
    /// Shuts one simulator down by UDID; nil when `simctl` is not available.
    var simulatorShutdown: (@Sendable (String) -> Bool)?

    public func setSimulatorShutdown(_ shutdown: (@Sendable (String) -> Bool)?) { simulatorShutdown = shutdown }
    var lastMemoryWrite = Date.distantPast
    var growthCache: [MemoryGrowth] = []

    /// Replaces how applications are asked to quit and opened; tests use a fake.
    public func setApplicationControl(_ control: ApplicationControl) { applicationControl = control }
    var frontmostPID: @Sendable () -> Int32? = { nil }
    /// Settings as adapted to the memory pressure of the latest sample.
    var effectiveSettings: PepelSettings { settings.adapted(to: live?.telemetry.pressure ?? .normal) }

    /// Replaces how the file cache is flushed; tests use it so no administrator prompt appears.
    public func setFileCacheFlusher(_ flusher: FileCacheFlusher) { fileCacheFlusher = flusher }
    var containerRefreshStarted = Date.distantPast
    var appTracker = AppExitTracker()
    var lastTrackerWrite = Date.distantPast
    public private(set) var live: LiveState?
    public private(set) var storage: StorageState?
    public private(set) var scanning = false

    public init(
        paths: AppPaths = AppPaths(), store: PepelStore? = nil, tools: ToolRunner? = nil,
        analyzers: [any StorageAnalyzer]? = nil, processSource: any ProcessSource = ProcessEnumerator(),
        telemetry: (@Sendable () -> SystemTelemetry)? = nil
    ) throws {
        self.paths = paths
        if let store {
            self.store = store
        } else {
            try paths.ensureSupportDirectory()
            self.store = try PepelStore(path: paths.database)
        }
        // A redirected PEPEL may consult git about its fixture repositories and nothing else:
        // docker, go, simctl and friends would report on, and act on, the real machine.
        self.tools = tools ?? ToolRunner(home: paths.home, allowedTools: paths.isRedirected ? ["git"] : nil)
        self.coordinator = ScanCoordinator(analyzers: (analyzers ?? AnalyzerRegistry.all()) + [AgentDisposableAnalyzer(store: self.store)])
        self.processSource = processSource
        let home = paths.home
        self.readTelemetry = telemetry ?? { TelemetryReader().read(volumePath: home) }
        self.fileCacheFlusher = paths.isRedirected ? .unavailable : .system(tools: self.tools)
        self.applicationControl = paths.isRedirected ? .unavailable : .system
        let runner = self.tools
        if runner.locate("xcrun") != nil {
            self.simulatorShutdown = { udid in
                // A UDID and nothing else ever reaches the command line.
                guard UUID(uuidString: udid) != nil else { return false }
                return runner.run("xcrun", ["simctl", "shutdown", udid], timeout: 60)?.status == 0
            }
        }
        self.settings = self.store.loadSettings(home: paths.home)
        let saved = self.store.loadCodable(StorageState.self, key: "storage.state")
        self.storage = saved
        var known = saved?.projects ?? []
        if known.isEmpty, let cache = self.store.loadCodable(ProjectCache.self, key: "projects.cache"),
            cache.roots == self.settings.projectRoots, Date().timeIntervalSince(cache.savedAt) < 86_400
        {
            known = cache.projects
        }
        self.projects = known
        self.projectIndex = ProjectIndex(known)
        self.appTracker = self.store.loadCodable(AppExitTracker.self, key: "apps.tracker") ?? AppExitTracker()
        self.projectActivity = self.store.loadCodable([String: Date].self, key: "projects.activity") ?? [:]
    }

    // MARK: Settings and rules

    public func currentSettings() -> PepelSettings { settings }

    public func update(_ mutate: @Sendable (inout PepelSettings) -> Void) throws -> PepelSettings {
        mutate(&settings)
        try store.saveSettings(settings)
        return settings
    }

    public nonisolated func protections() -> [ProtectionRule] { store.protections() }

    public func protect(_ kind: ProtectionKind, value: String, note: String = "") throws -> ProtectionRule {
        let normalised = kind == .path || kind == .pin || kind == .project ? PathUtil.canonical(value, home: paths.home) : value
        let rule = ProtectionRule(kind: kind, value: normalised, note: note)
        try store.addProtection(rule)
        store.appendAudit(AuditEntry(kind: .protection, initiator: "user", subject: normalised, outcome: "protected (\(kind.rawValue))"))
        return rule
    }

    public func unprotect(id: String) throws {
        try store.removeProtection(id: id)
        store.appendAudit(AuditEntry(kind: .protection, initiator: "user", subject: id, outcome: "protection removed"))
    }

    public func setPinned(_ path: String, _ pinned: Bool) throws {
        if pinned { _ = try protect(.pin, value: path) } else { try store.removeProtection(kind: .pin, value: path) }
    }

    private func adopt(projects: [Project]) {
        self.projects = projects
        projectIndex = ProjectIndex(projects)
    }

    // MARK: Live state

    private nonisolated static func discover(settings: PepelSettings, home: String) async -> [Project] {
        ProjectDiscovery(maxDepth: settings.discoveryDepth, home: home)
            .discover(roots: settings.projectRoots, registered: settings.registeredProjects, excluded: settings.excludedPaths)
    }

    public func refreshProjects() async -> [Project] {
        adopt(projects: await Self.discover(settings: settings, home: paths.home))
        // Kept apart from the scan result so the first commands after install are not slow.
        try? store.saveCodable(ProjectCache(roots: settings.projectRoots, savedAt: Date(), projects: projects), key: "projects.cache")
        return projects
    }

    struct ProjectCache: Codable {
        var roots: [String]
        var savedAt: Date
        var projects: [Project]
    }

    public func knownProjects() -> [Project] { projects }

    func setContainerReport(_ report: ContainerReport?) { containerReport = report }

    /// Adds what PEPEL knows from the host side: what the VM is charged, and for each compose
    /// project whether an agent session is running in its project and since when there has been none.
    func annotate(_ report: ContainerReport, sessions: [AgentSession], vm: MemoryOwner?, now: Date) -> ContainerReport {
        var report = report
        if let vm {
            report.hostFootprintBytes = vm.footprintBytes
            report.hostResidentBytes = vm.residentBytes
        }
        // Measured after the last restart; before any restart was observed, a cautious 6 GiB.
        report.baselineOverheadBytes = store.value("containers.vmOverhead").flatMap(Int64.init) ?? (6 << 30)
        // The busiest reading per day, kept for two weeks: what a memory limit must leave room for.
        let day = Int(now.timeIntervalSince1970 / 86_400)
        if containerPeaks == nil { containerPeaks = store.loadCodable([Int: Int64].self, key: "containers.peaks") ?? [:] }
        var peaks = (containerPeaks ?? [:]).filter { day - $0.key < 14 }
        if report.usedByContainersBytes > peaks[day] ?? 0 {
            peaks[day] = report.usedByContainersBytes
            try? store.saveCodable(peaks, key: "containers.peaks")
        }
        containerPeaks = peaks
        report.peakUsedBytes = peaks.values.max() ?? 0
        func group(of projectID: String) -> String { projectIndex.project(id: projectID)?.groupID ?? projectID }
        var live: [String: Int] = [:]
        for session in sessions where !session.isService {
            guard let projectID = session.projectID else { continue }
            live[group(of: projectID), default: 0] += 1
        }
        for key in live.keys { projectActivity[key] = now }
        for index in report.groups.indices {
            guard let projectID = report.groups[index].projectID else { continue }
            let key = group(of: projectID)
            report.groups[index].agentSessions = live[key] ?? 0
            if live[key] == nil {
                // First time PEPEL sees this project without a session: the clock starts now.
                if projectActivity[key] == nil { projectActivity[key] = now }
                report.groups[index].idleSince = projectActivity[key]
            }
        }
        if now.timeIntervalSince(projectActivityWritten) >= 60 {
            projectActivityWritten = now
            projectActivity = projectActivity.filter { now.timeIntervalSince($0.value) < 30 * 86_400 }
            try? store.saveCodable(projectActivity, key: "projects.activity")
        }
        return report
    }

    /// Asks the container runtime now (blocking for a couple of seconds); used by the command line.
    public func inspectContainers() async -> ContainerReport? {
        let liveState = await refreshLive()
        let tools = tools, index = projectIndex, keep = settings.keepContainers
        guard var report = await Task.detached(priority: .utility, operation: { ContainerInspector(tools: tools).inspect(attributor: index, keep: keep) }).value else { return nil }
        containerReport = report
        report = annotate(report, sessions: liveState.agentSessions, vm: liveState.memoryOwners.first { $0.kind == .virtualMachine }, now: Date())
        return report
    }

    private func loadHistoryIfNeeded(now: Date) {
        guard !historyLoaded else { return }
        historyLoaded = true
        history = store.observations(since: now.addingTimeInterval(-max(3 * 3600, TimeInterval(settings.agentSleepMinutes) * 90)))
    }

    /// Samples telemetry and the process table and re-assesses every developer process.
    @discardableResult
    public func refreshLive(now: Date = Date()) async -> LiveState {
        if projects.isEmpty { _ = await refreshProjects() }
        loadHistoryIfNeeded(now: now)

        var processes = processSource.snapshot()
        for index in processes.indices {
            let role = RoleClassifier.role(of: processes[index], attributor: projectIndex)
            if role == .devServer || role == .projectBinary || role == .testRunner {
                processes[index].listeningPorts = processSource.listeningPorts(of: processes[index].pid)
            }
        }
        lastProcesses = processes

        var sessions = AgentDetector.sessions(
            processes: processes, attributor: projectIndex, history: history, now: now,
            sleepWindow: TimeInterval(effectiveSettings.agentSleepMinutes) * 60, leases: store.leases(now: now))
        let frozenNow = frozenTrees()
        for index in sessions.indices {
            sessions[index].frozenSince = frozenNow.first { $0.root == sessions[index].root }?.frozenAt
        }
        var context = AssessmentContext(
            processes: processes, history: history, protections: store.protections(), attributor: projectIndex, now: now,
            idleWindow: TimeInterval(settings.idleMinutesBeforeAbandoned) * 60)
        for session in sessions where session.state == .sleeping { context.sleepingAgents[session.root] = session.evidence }
        // Never a working session, whatever was asked.
        for session in sessions where session.state == .idle && !session.isService {
            if let asked = manualSleepOverride[session.root] { context.sleepingAgents[session.root] = asked }
        }
        let assessments = ProcessGuardian.assess(context)
        let telemetry = readTelemetry()
        let advice = MemoryGuardian.advise(telemetry: telemetry, processes: processes, assessments: assessments, history: history)

        // One build is many compiler processes: count the topmost active process of each tree.
        let tree = ProcessTree(processes)
        let active = Set(assessments.filter { $0.lifecycle == .activeBuildOrTest }.map(\.process.pid))
        let buildRoots = active.filter { pid in
            guard let p = tree.byPID[pid] else { return false }
            return !tree.ancestors(of: p).contains { active.contains($0.pid) }
        }

        record(processes: processes, developer: Set(assessments.map(\.process.identity)), telemetry: telemetry, now: now)
        let index = projectIndex
        let owners = MemoryAttributor.attribute(processes: processes, assessments: assessments, sessions: sessions) { index.project(id: $0)?.name }
        var state = LiveState(
            telemetry: telemetry, assessments: assessments, agentSessions: sessions, memory: advice,
            activeBuildCount: buildRoots.count, userProcessCount: processes.count, sampledAt: now)
        state.frozen = frozenNow
        // What quit applications left running. Agent sessions keep their own rules.
        let before = appTracker
        appTracker.update(processes: processes, now: now)
        // Saved so a quit is still known after PEPEL restarts and to the command-line tool:
        // at once when an application quits or returns, otherwise at most every 30 seconds.
        func quit(_ tracker: AppExitTracker) -> Set<String> { Set(tracker.apps.values.filter { $0.quitAt != nil }.map(\.bundlePath)) }
        if appTracker != before, quit(appTracker) != quit(before) || now.timeIntervalSince(lastTrackerWrite) >= 30 {
            lastTrackerWrite = now
            try? store.saveCodable(appTracker, key: "apps.tracker")
        }
        state.leftovers = appTracker.leftovers(
            processes: processes, assessments: assessments, protectedRoots: Set(sessions.map(\.root)), attributor: projectIndex, now: now,
            automaticAfter: TimeInterval(effectiveSettings.appLeftoverGraceMinutes) * 60)
        // Container memory needs three Docker calls (about two seconds), so it is refreshed in
        // the background at most every two minutes and only while a virtual machine is running.
        let vm = owners.first { $0.kind == .virtualMachine }
        if vm == nil {
            containerReport = nil
        } else if now.timeIntervalSince(containerRefreshStarted) >= 120 {
            containerRefreshStarted = now
            let tools = tools, index = projectIndex, keep = settings.keepContainers
            Task.detached(priority: .utility) { [weak self] in
                let report = ContainerInspector(tools: tools).inspect(attributor: index, keep: keep)
                await self?.setContainerReport(report)
            }
        }
        if let report = containerReport, let vm {
            state.containers = annotate(report, sessions: sessions, vm: vm, now: now)
        }
        state.agentHelpers = AgentDetector.helperGroups(processes: processes, sessions: sessions)
        state.memoryOwners = owners
        recordMemory(owners: owners, now: now)
        state.growth = growthCache
        state.overBudget = OverBudget.find(owners: owners, budgets: settings.memoryBudgets)
        state.unusedApplications = unusedApplications(owners: owners, now: now)
        // Agent sessions, the virtual machine and PEPEL's own surroundings have rules of their own.
        var excluded = Set<ProcessIdentity>()
        let processTree = ProcessTree(processes)
        for session in sessions {
            excluded.insert(session.root)
            if let root = processTree.process(session.root) { excluded.formUnion(processTree.descendants(of: root).map(\.identity)) }
        }
        for owner in owners where owner.kind == .virtualMachine { excluded.formUnion(owner.largest.map(\.identity)) }
        if let own = processes.first(where: { $0.pid == getpid() }) {
            excluded.insert(own.identity)
            excluded.formUnion(processTree.ancestors(of: own).map(\.identity))
        }
        state.serviceBranches = ServiceBranches.find(
            processes: processes, services: sessions, history: history, idleAfter: TimeInterval(settings.serviceBranchIdleMinutes) * 60, now: now)
        state.staleBranches = state.serviceBranches.filter(\.isStale).compactMap { branch -> ProcessAssessment? in
            guard let root = processTree.process(branch.root) else { return nil }
            var assessment = ProcessAssessment(
                process: root, role: RoleClassifier.role(of: root, attributor: projectIndex), lifecycle: .abandonedSubprocess, confidence: .probable,
                projectID: nil, projectConfidence: .unknown,
                evidence: [
                    "\(branch.serviceName)'s server runs \(branch.copies) copies of this program; this is not the newest.",
                    "The whole branch (\(branch.processCount) process\(branch.processCount == 1 ? "" : "es")) has used almost no CPU for \(TimeFormat.age(branch.idleFor ?? 0)).",
                    "Started \(TimeFormat.ago(branch.startedAt)). PEPEL cannot see conversations: if one still uses it, its tools stop working until the application starts them again.",
                ],
                eligibility: .approvalRequired(warning: "A conversation that is still open may be using it."), descendantCount: branch.processCount - 1,
                subtreeFootprintBytes: branch.footprintBytes)
            assessment.staleServiceBranch = true
            return assessment
        }
        state.orphanedTools = Simulators.orphanedTools(processes: processes, excluded: excluded, attributor: projectIndex, currentUID: getuid(), now: now)
        state.simulators = Simulators.booted(
            processes: processes, home: paths.home, workingSessions: sessions.filter { $0.state == .working && !$0.isService }.count)
        for simulator in state.simulators {
            excluded.insert(simulator.root)
            if let root = processTree.process(simulator.root) { excluded.formUnion(processTree.descendants(of: root).map(\.identity)) }
        }
        excluded.formUnion(state.orphanedTools.map(\.process.identity))
        state.dormant = DormantProcesses.find(
            processes: processes, assessments: assessments, history: history, excluded: excluded, attributor: projectIndex, currentUID: getuid(), now: now)
        state.memoryExplanation = MemoryAttributor.explanation(owners: owners, telemetry: telemetry)
        live = state
        return state
    }

    private func record(processes: [ProcessSnapshot], developer: Set<ProcessIdentity>, telemetry: SystemTelemetry, now: Date) {
        let alive = Set(processes.map(\.identity))
        // Long enough to judge the agent sleep window with some margin.
        let horizon = now.addingTimeInterval(-max(3 * 3600, TimeInterval(settings.agentSleepMinutes) * 90))
        history = history.filter { alive.contains($0.key) }
        for p in processes {
            var series = history[p.identity] ?? []
            // One point per ~20 s is plenty for idle detection and keeps memory flat.
            if let last = series.last, now.timeIntervalSince(last.timestamp) < 20 { continue }
            series.append(ProcessObservation(timestamp: now, cpuTimeNs: p.cpuTimeNs, footprintBytes: p.footprintBytes, diskBytesWritten: p.diskBytesWritten))
            if let first = series.first, first.timestamp < horizon, series.count > 2 { series.removeFirst() }
            history[p.identity] = series
        }
        if now.timeIntervalSince(lastObservationWrite) >= 60 {
            lastObservationWrite = now
            store.recordObservations(processes.filter { developer.contains($0.identity) }, at: now)
        }
        if now.timeIntervalSince(lastTelemetryWrite) >= 300 {
            lastTelemetryWrite = now
            store.recordTelemetry(telemetry, reclaimable: storage?.reclaimableBytes)
        }
    }

    // MARK: Storage scan

    /// Full storage scan. With `changes`, items nothing changed under reuse their previous size.
    @discardableResult
    public func scan(changes: ChangeSet? = nil, progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> StorageState {
        scanning = true
        defer { scanning = false }
        let now = Date()
        progress?(ScanProgress(phase: "Discovering projects"))
        _ = await refreshProjects()
        let discovered = Date()
        progress?(ScanProgress(phase: "Looking inside \(projects.count) projects"))
        let hits = await ProjectArtifactWalker().walk(projectIndex, consultGit: tools.locate("git") != nil)
        let walked = Date()
        let context = ScanContext(
            home: paths.home, temporaryDirectory: paths.temporaryDirectory, sharedTemporaryDirectory: paths.sharedTemporaryDirectory,
            projects: projectIndex, settings: settings, now: now, tools: tools, hits: hits)
        let result = await coordinator.scan(context: context, changes: changes, progress: progress)

        let liveState = await refreshLive()
        let state = buildStorageState(scan: result, live: liveState, now: Date())
        storage = state
        if !result.cancelled {
            try? store.saveCodable(state, key: "storage.state")
            store.recordUsage(scope: "project", entries: state.projectUsage.map { ($0.id, $0.name, $0.artifactBytes) }, at: now)
            var byCategory: [ArtifactCategory: Int64] = [:]
            for item in state.items { byCategory[item.category, default: 0] += item.occupiedBytes }
            store.recordUsage(scope: "category", entries: byCategory.map { ($0.key.rawValue, $0.key.displayName, $0.value) }, at: now)
            store.recordTelemetry(liveState.telemetry, reclaimable: state.reclaimableBytes)
            lastTelemetryWrite = now
            store.appendAudit(
                AuditEntry(
                    kind: .scan, initiator: "engine", subject: "storage scan",
                    outcome: "\(state.items.count) items, \(Bytes.format(state.reclaimableBytes)) reclaimable",
                    bytes: state.reclaimableBytes,
                    detail: [
                        "discoverSeconds": String(format: "%.1f", discovered.timeIntervalSince(now)),
                        "walkSeconds": String(format: "%.1f", walked.timeIntervalSince(discovered)),
                        "measureSeconds": String(format: "%.1f", result.finishedAt.timeIntervalSince(result.startedAt)),
                        "reused": String(result.reusedMeasurements),
                    ]))
        }
        return state
    }

    func runningWrappedBuilds() -> [BuildRecord] {
        store.builds(limit: 50).filter { $0.exitCode == nil && processSource.identity(of: $0.wrapperPID) != nil }
    }

    private func buildStorageState(scan: ScanResult, live: LiveState, now: Date) -> StorageState {
        let records = store.builds()
        let usage = UsageInspector.inspect(
            items: scan.items, processes: lastProcesses, assessments: live.assessments, runningWrappedBuilds: runningWrappedBuilds())
        let pins = Set(store.protections().filter { $0.kind == .pin }.map(\.value))
        let source = processSource
        let report = BuildGuardian.report(
            items: scan.items, projects: projectIndex, groupName: { [projectIndex] in projectIndex.groupName($0) }, records: records,
            pinned: pins, activity: usage, settings: settings, now: now, isAlive: { source.identity(of: $0) != nil })
        var adjusted = scan
        adjusted.items = report.items

        let dayAgo = store.usage(scope: "project", atOrBefore: now.addingTimeInterval(-86_400))
        let earliest = dayAgo.isEmpty ? store.usage(scope: "project", atOrBefore: now.addingTimeInterval(-600)) : dayAgo
        var usageByGroup: [String: ProjectUsage] = [:]
        for project in projects {
            var entry = usageByGroup[project.groupID] ?? ProjectUsage(
                id: project.groupID, name: project.groupName, roots: [], branches: [], kinds: [], artifactBytes: 0,
                reclaimableBytes: 0, itemCount: 0, growth: nil, processCount: 0, agentCount: 0)
            entry.roots.append(project.id)
            if let branch = project.git?.branch, !entry.branches.contains(branch) { entry.branches.append(branch) }
            entry.kinds = Array(Set(entry.kinds).union(project.kinds)).sorted { $0.rawValue < $1.rawValue }
            entry.processCount += live.assessments.filter { $0.projectID == project.id }.count
            entry.agentCount += live.agentSessions.filter { $0.projectID == project.id }.count
            usageByGroup[project.groupID] = entry
        }
        for item in adjusted.items {
            guard let projectID = item.projectID, let group = projectIndex.project(id: projectID)?.groupID else { continue }
            usageByGroup[group]?.artifactBytes += item.occupiedBytes
            usageByGroup[group]?.itemCount += 1
            if item.safety != .protected { usageByGroup[group]?.reclaimableBytes += item.reclaimableBytes }
        }
        for (group, entry) in usageByGroup {
            if let before = earliest[group] {
                usageByGroup[group]?.growth = GrowthFigure(
                    requestedWindow: 86_400, actualSpan: min(86_400, now.timeIntervalSince(before.timestamp)),
                    deltaBytes: entry.artifactBytes - before.bytes)
            }
        }
        return StorageState(
            scan: adjusted, builds: report.summaries, buildTotalBytes: report.totalBytes,
            globalBuildBudgetBytes: report.globalBudgetBytes, projects: projects,
            projectUsage: usageByGroup.values.sorted { $0.artifactBytes > $1.artifactBytes }, inUse: usage)
    }

    /// Re-applies retention and usage to the last scan without touching the disk (after a
    /// settings change, a pin, or a cleanup).
    public func reevaluateStorage() async {
        guard let storage else { return }
        let liveState = await refreshLive()
        self.storage = buildStorageState(scan: storage.scan, live: liveState, now: Date())
    }

    func dropItems(_ ids: Set<String>) {
        guard var storage else { return }
        storage.scan.items.removeAll { ids.contains($0.id) }
        self.storage = storage
    }

    // MARK: History

    public nonisolated func growth(now: Date = Date()) -> GrowthState {
        GrowthState(
            hour: store.diskGrowth(window: 3600, now: now), day: store.diskGrowth(window: 86_400, now: now),
            week: store.diskGrowth(window: 7 * 86_400, now: now),
            spikes: store.storageSpikes(since: now.addingTimeInterval(-7 * 86_400)).map { GrowthState.Spike(at: $0.at, deltaBytes: $0.deltaBytes) })
    }

    public func alerts() -> [PepelAlert] {
        AlertEvaluator.alerts(live: live, storage: storage, growth: growth(), settings: settings)
    }
}
