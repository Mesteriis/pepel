import Foundation

/// Bridges the engine's process source to the terminator.
struct SourceProcessControl: ProcessControl {
    let source: any ProcessSource

    func identity(of pid: Int32) -> ProcessIdentity? { source.identity(of: pid) }
    func send(_ signal: Int32, to pid: Int32) -> Bool { source.send(signal, to: pid) }
}

public enum TerminationResult: Sendable {
    case denied(TerminationDecision)
    case needsConfirmation(TerminationDecision)
    case completed(TerminationReport)
    case notFound
}

extension PepelEngine {
    // MARK: Cleanup

    /// Facts the policy engine needs, gathered at this instant.
    public func policyContext(for items: [StorageItem], refresh: Bool = true) async -> PolicyContext {
        let liveState: LiveState
        if !refresh, let live, Date().timeIntervalSince(live.sampledAt) < 2 {
            liveState = live
        } else {
            liveState = await refreshLive()
        }
        let usage = UsageInspector.inspect(
            items: items, processes: lastProcesses, assessments: liveState.assessments, runningWrappedBuilds: runningWrappedBuilds())
        return PolicyContext(
            settings: settings, home: paths.home,
            temporaryRoots: paths.isRedirected
                ? [paths.temporaryDirectory, paths.sharedTemporaryDirectory]
                : [paths.sharedTemporaryDirectory, "/private/var/folders", paths.temporaryDirectory],
            protections: store.protections(), leases: store.leases(), usage: usage,
            agentSessions: liveState.agentSessions, projectRoots: projects.map(\.id), now: Date())
    }

    /// Evaluates items against policy without changing anything.
    /// - Parameter itemIDs: nil selects every non-protected item of the last scan.
    public func cleanupPlan(itemIDs: Set<String>? = nil, initiator: Initiator) async -> CleanupPlan {
        let all = storage?.items ?? []
        let selected = itemIDs.map { ids in all.filter { ids.contains($0.id) } } ?? all.filter { $0.safety != .protected }
        let context = await policyContext(for: selected)
        return policy.plan(items: selected, initiator: initiator, context: context)
    }

    /// Executes a plan. Items needing confirmation run only when listed in `confirmed`.
    public func executeCleanup(_ plan: CleanupPlan, confirmed: Set<String>, dryRun: Bool) async -> CleanupReport {
        let items = plan.decisions.map(\.item)
        let context = await policyContext(for: items)
        let approved = policy.approve(plan, confirmed: confirmed, context: context)
        let executor = CleanupExecutor(engine: policy, store: store, tools: tools)
        let coordinator = coordinator
        let telemetry = readTelemetry
        let report = await executor.execute(
            approved, dryRun: dryRun,
            freshContext: { [weak self] item in
                // Only the item about to be touched is re-checked against the process table.
                await self?.policyContext(for: [item], refresh: false) ?? context
            },
            validate: { item in
                guard let analyzer = coordinator.analyzer(id: item.analyzerID) else { return "Its analyzer is no longer available." }
                return analyzer.validate(item)
            },
            diskAvailable: { telemetry().diskAvailableBytes })
        if !dryRun {
            dropItems(Set(report.outcomes.filter(\.status.succeeded).map(\.itemID)))
            await reevaluateStorage()
            if let storage { try? store.saveCodable(storage, key: "storage.state") }
        }
        return report
    }

    public nonisolated func restore(trashedPath: String, originalPath: String) -> String? {
        CleanupExecutor(engine: policy, store: store, tools: tools).restore(trashedPath: trashedPath, originalPath: originalPath)
    }

    /// One automatic pass: only what the user opted into, only what policy clears.
    public func automaticPass() async -> (cleanup: CleanupReport?, terminations: [TerminationReport]) {
        var cleanup: CleanupReport?
        var terminations: [TerminationReport] = []
        await freezePass()
        await resumeContainersOfActiveProjects()
        guard !settings.paused else { return (nil, []) }
        _ = await stopIdleProjectContainers()
        _ = await nightlyVMRefresh()
        if settings.monitoringMode == .automaticSafe, let storage {
            let safe = Set(storage.items.filter { $0.safety == .safe }.map(\.id))
            if !safe.isEmpty {
                let plan = await cleanupPlan(itemIDs: safe, initiator: .automatic)
                if plan.decisions.contains(where: { $0.verdict == .allowed }) {
                    cleanup = await executeCleanup(plan, confirmed: [], dryRun: false)
                }
            }
        }
        if settings.terminateAppLeftovers, let live {
            for leftover in live.leftovers.flatMap(\.processes) where leftover.eligibility == .automaticEligible {
                if case .completed(let report) = await terminate(leftover.process.identity, confirmed: false, force: false, initiator: .automatic) {
                    terminations.append(report)
                }
            }
        }
        if settings.terminateSleepingAgents, let live {
            // Independent of memory pressure: a session nobody has touched for hours is the user's
            // stated wish to clean up, not an emergency measure.
            for session in live.agentSessions where session.state == .sleeping {
                if case .completed(let report) = await terminate(session.root, confirmed: false, force: false, initiator: .automatic) {
                    terminations.append(report)
                }
            }
        }
        if settings.autoTerminateAbandoned, let live {
            // Certain, whatever the memory pressure: nothing can ever talk to them again.
            for tool in live.orphanedTools {
                if case .completed(let report) = await terminate(tool.process.identity, confirmed: false, force: false, initiator: .automatic) {
                    terminations.append(report)
                }
            }
        }
        if settings.autoTerminateAbandoned, let live, live.telemetry.pressure != .normal {
            for candidate in live.memory.proposals where candidate.eligibility == .automaticEligible {
                if case .completed(let report) = await terminate(candidate.process.identity, confirmed: false, force: false, initiator: .automatic) {
                    terminations.append(report)
                }
            }
        }
        return (cleanup, terminations)
    }

    // MARK: Process termination

    public func terminationDecision(_ identity: ProcessIdentity, initiator: Initiator) async -> TerminationDecision? {
        let liveState = await refreshLive()
        // Lists with rules of their own come first, so a process is judged by the narrowest one.
        let special: [ProcessAssessment] =
            liveState.restartableSystem + liveState.idleTabs + liveState.staleBranches + liveState.orphanedTools + liveState.dormant
        let ordinary: [ProcessAssessment] = liveState.assessments + liveState.leftovers.flatMap(\.processes)
        guard let target = (special + ordinary).first(where: { $0.process.identity == identity }) else { return nil }
        let tree = ProcessTree(lastProcesses)
        let descendants = tree.descendants(of: target.process)
        let ids = Set(descendants.map(\.identity))
        return policy.evaluateTermination(
            target, descendants: descendants, descendantAssessments: liveState.assessments.filter { ids.contains($0.process.identity) },
            initiator: initiator, settings: settings)
    }

    /// Runs the full workflow: identity, ownership, descendants, dependencies and protections are
    /// re-established now; then a graceful signal, a confirmed exit, and before/after measurements.
    public func terminate(_ identity: ProcessIdentity, confirmed: Bool, force: Bool, initiator: Initiator) async -> TerminationResult {
        guard let decision = await terminationDecision(identity, initiator: initiator) else { return .notFound }
        // A suspended process cannot act on SIGTERM: it stays pending until the process continues.
        if decision.verdict != .denied, confirmed || decision.verdict == .allowed {
            for tree in frozenTrees() where tree.root == identity || tree.members.contains(identity) { thaw(tree.root, reason: "it is being terminated") }
        }
        guard let approved = policy.approveTermination(decision, confirmed: confirmed, force: force, initiator: initiator, settings: settings) else {
            if decision.verdict == .needsConfirmation { return .needsConfirmation(decision) }
            store.appendAudit(
                AuditEntry(
                    kind: .terminationDenied, initiator: initiator.rawValue,
                    subject: "\(decision.target.process.name) (PID \(identity.pid))", outcome: decision.reasons.first ?? "denied"))
            return .denied(decision)
        }
        let terminator = ProcessTerminator(control: SourceProcessControl(source: processSource), store: store)
        let report = await terminator.terminate(approved, telemetry: readTelemetry)
        await refreshLive()
        return .completed(report)
    }

    // MARK: Containers

    public func containerStopDecision(groupID: String, initiator: Initiator) async -> ContainerStopDecision? {
        guard let report = await inspectContainers(), let group = report.groups.first(where: { $0.id == groupID }) else { return nil }
        return policy.evaluateContainerStop(group, initiator: initiator, settings: effectiveSettings, protections: store.protections(), leases: store.leases())
    }

    /// Stops the running containers of one compose project, if policy allows it.
    public func stopContainers(
        groupID: String, confirmed: Bool, initiator: Initiator, action: IdleContainerAction = .stop
    ) async -> (decision: ContainerStopDecision, report: ContainerStopReport?)? {
        guard let decision = await containerStopDecision(groupID: groupID, initiator: initiator) else { return nil }
        guard let approved = policy.approveContainerStop(decision, confirmed: confirmed, initiator: initiator) else { return (decision, nil) }
        let stopper = containerStopper()
        let report = await Task.detached(priority: .utility) { action == .pause ? stopper.pause(approved) : stopper.stop(approved) }.value
        if action == .pause {
            // Remembered, so that only what PEPEL paused is ever resumed by PEPEL.
            try? store.saveCodable(Array(Set(pausedByPepel() + report.stopped)).sorted(), key: Self.pausedKey)
        }
        containerRefreshStarted = .distantPast  // read the runtime again on the next sample
        return (decision, report)
    }

    static let pausedKey = "containers.pausedByPepel"
    public nonisolated func pausedByPepel() -> [String] { store.loadCodable([String].self, key: Self.pausedKey) ?? [] }

    nonisolated func containerStopper() -> ContainerStopper {
        if let run = containerRunner { return ContainerStopper(store: store, run: run) }
        return ContainerStopper(tools: tools, store: store)
    }

    /// Lets the paused containers of one compose project continue.
    @discardableResult
    public func resumeContainers(groupID: String, reason: String, onlyPausedByPepel: Bool = false) async -> [String] {
        guard let group = (containerReport ?? live?.containers)?.groups.first(where: { $0.id == groupID }) else { return [] }
        let mine = Set(pausedByPepel())
        let names = group.paused.map(\.name).filter { !onlyPausedByPepel || mine.contains($0) }
        let stopper = containerStopper()
        let resumed = await Task.detached(priority: .utility) { stopper.unpause(names, group: group.name, reason: reason) }.value
        try? store.saveCodable(pausedByPepel().filter { !resumed.contains($0) }, key: Self.pausedKey)
        containerRefreshStarted = .distantPast
        return resumed
    }

    /// An agent came back to a project whose containers PEPEL paused: let them continue at once.
    func resumeContainersOfActiveProjects() async {
        let mine = Set(pausedByPepel())
        guard !mine.isEmpty, let groups = live?.containers?.groups else { return }
        // Containers that are gone, or that someone resumed by hand, are forgotten.
        let stillPaused = Set(groups.flatMap(\.paused).map(\.name))
        if !mine.isSubset(of: stillPaused), containerReport != nil { try? store.saveCodable(mine.intersection(stillPaused).sorted(), key: Self.pausedKey) }
        for group in groups where group.agentSessions > 0 && group.paused.contains(where: { mine.contains($0.name) }) {
            await resumeContainers(groupID: group.id, reason: "an agent session is running in the project again", onlyPausedByPepel: true)
        }
    }

    public nonisolated func lastVMRefresh() -> Date? {
        store.value("containers.lastVMRefresh").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
    }

    public func vmRefreshDecision(initiator: Initiator) async -> (decision: VMRefreshDecision, report: ContainerReport)? {
        guard let report = await inspectContainers() else { return nil }
        let working = live?.agentSessions.filter { $0.state == .working && !$0.isService }.count ?? 0
        let decision = policy.evaluateVMRefresh(
            report, workingSessions: working, initiator: initiator, settings: settings, lastRefresh: lastVMRefresh(),
            userIdleSeconds: TelemetryReader.userIdleSeconds(), pressure: live?.telemetry.pressure ?? .normal)
        return (decision, report)
    }

    /// Restarts the container VM and starts the same containers again, measuring what the Mac
    /// is charged for the VM before and after.
    public func refreshContainerVM(confirmed: Bool, initiator: Initiator, newLimit: ApprovedVMLimit? = nil) async -> (decision: VMRefreshDecision, report: VMRefreshReport?)? {
        guard let (decision, containers) = await vmRefreshDecision(initiator: initiator) else { return nil }
        guard let approved = policy.approveVMRefresh(decision, confirmed: confirmed, initiator: initiator) else { return (decision, nil) }
        let tools = tools, store = store
        let dockerSettings = DockerDesktopSettings(home: paths.home), backups = paths.supportDirectory + "/docker-backups"
        var change: (@Sendable () -> String?)?
        if let limit = newLimit?.bytes {
            change = {
                do {
                    try dockerSettings.setMemoryLimit(limit, backupDirectory: backups)
                    return nil
                } catch DockerDesktopSettings.Failure.unreadable {
                    return "Docker's settings file could not be read."
                } catch {
                    return "Docker's settings file could not be written."
                }
            }
        }
        var report = await ContainerVMRefresher(tools: tools, store: store).refresh(approved, whileStopped: change)
        if report.restarted { try? store.setValue(String(Date().timeIntervalSince1970), for: "containers.lastVMRefresh") }
        report.hostFootprintBefore = containers.hostFootprintBytes
        // Give the new VM a moment to settle before reading what it is charged.
        try? await Task.sleep(for: .seconds(20))
        let after = await refreshLive()
        report.hostFootprintAfter = after.memoryOwners.first { $0.kind == .virtualMachine }?.footprintBytes ?? 0
        // What a fresh VM costs beyond its containers: the floor no restart can go below.
        if report.restarted, report.hostFootprintAfter > 0, let fresh = await inspectContainers() {
            let overhead = max(0, report.hostFootprintAfter - fresh.usedByContainersBytes)
            try? store.setValue(String(overhead), for: "containers.vmOverhead")
        }
        store.appendAudit(
            AuditEntry(
                kind: .container, initiator: initiator.rawValue, subject: "Docker Desktop VM memory", outcome: "measured",
                bytes: max(0, report.returnedBytes),
                detail: ["chargedBefore": Bytes.format(report.hostFootprintBefore), "chargedAfter": Bytes.format(report.hostFootprintAfter)]))
        containerRefreshStarted = .distantPast
        return (decision, report)
    }

    public func vmLimitDecision(_ bytes: Int64, initiator: Initiator) async -> VMLimitDecision? {
        guard let report = await inspectContainers() else { return nil }
        return policy.evaluateVMLimit(report, newLimitBytes: bytes, physicalMemoryBytes: live?.telemetry.memoryTotalBytes ?? 0, initiator: initiator)
    }

    /// Changes the Docker VM's memory limit: stops Docker Desktop, writes the setting, starts it
    /// and the containers that were running.
    public func setContainerVMLimit(_ bytes: Int64, confirmed: Bool, initiator: Initiator) async -> (decision: VMLimitDecision, report: VMRefreshReport?)? {
        guard let decision = await vmLimitDecision(bytes, initiator: initiator) else { return nil }
        guard let approved = policy.approveVMLimit(decision, confirmed: confirmed, initiator: initiator) else { return (decision, nil) }
        let report = await refreshContainerVM(confirmed: confirmed, initiator: initiator, newLimit: approved)?.report
        store.appendAudit(
            AuditEntry(
                kind: .container, initiator: initiator.rawValue, subject: "Docker Desktop VM memory limit",
                outcome: "\(Bytes.format(decision.currentLimitBytes)) → \(Bytes.format(bytes))", detail: ["steps": report?.steps.joined(separator: " ") ?? "not restarted"]))
        return (decision, report)
    }

    /// The nightly restart. Cheap checks first, so Docker is only asked when it could matter.
    func nightlyVMRefresh() async -> VMRefreshReport? {
        guard settings.refreshContainerVMNightly, let cached = live?.containers else { return nil }
        let working = live?.agentSessions.filter { $0.state == .working && !$0.isService }.count ?? 0
        let quick = policy.evaluateVMRefresh(
            cached, workingSessions: working, initiator: .automatic, settings: settings, lastRefresh: lastVMRefresh(),
            userIdleSeconds: TelemetryReader.userIdleSeconds(), pressure: live?.telemetry.pressure ?? .normal)
        guard quick.verdict == .allowed else { return nil }
        return await refreshContainerVM(confirmed: false, initiator: .automatic)?.report
    }

    /// Stops containers of projects no agent session has worked in for the grace period.
    func stopIdleProjectContainers() async -> [ContainerStopReport] {
        guard settings.stopContainersOfIdleProjects, let groups = live?.containers?.groups else { return [] }
        var reports: [ContainerStopReport] = []
        for group in groups where group.projectID != nil && group.agentSessions == 0 {
            let quick = policy.evaluateContainerStop(group, initiator: .automatic, settings: effectiveSettings, protections: store.protections(), leases: store.leases())
            guard quick.verdict == .allowed else { continue }
            // Decided again on a fresh reading of the runtime before anything is stopped.
            // Pausing again what is already paused would do nothing.
            if settings.idleContainerAction == .pause, group.pausable.isEmpty { continue }
            if let result = await stopContainers(groupID: group.id, confirmed: false, initiator: .automatic, action: settings.idleContainerAction), let report = result.report {
                reports.append(report)
            }
        }
        return reports
    }

    // MARK: Agent API

    public nonisolated func makeAgentService() -> AgentAPIService {
        let hooks = AgentAPIHooks(
            requestScan: { [weak self] in _ = await self?.scan() },
            previewCleanup: { [weak self] in
                guard let self else { return Data("{}".utf8) }
                let plan = await self.cleanupPlan(initiator: .agent)
                struct Row: Encodable { var path: String, title: String, safety: String, bytes: Int64, inUseOrBlocked: [String] }
                let rows = plan.decisions.map { decision in
                    // Agents always see "denied" for themselves; show what stands in a user's way instead.
                    Row(
                        path: decision.item.path, title: decision.item.title, safety: decision.item.safety.rawValue,
                        bytes: decision.item.reclaimableBytes,
                        inUseOrBlocked: decision.reasons.filter { !$0.hasPrefix("Agents can preview") })
                }
                return (try? JSONEncoder().encode(rows)) ?? Data("[]".utf8)
            },
            status: { [weak self] in
                guard let self else { return Data("{}".utf8) }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                return (try? encoder.encode(await self.statusSummary())) ?? Data("{}".utf8)
            })
        return AgentAPIService(store: store, hooks: hooks, home: paths.home)
    }

    public struct StatusSummary: Codable, Sendable {
        public var diskAvailableBytes: Int64
        public var diskTotalBytes: Int64
        public var reclaimableBytes: Int64?
        public var reclaimableIsApproximate: Bool
        public var lastScan: Date?
        public var memoryPressure: MemoryPressureLevel
        public var swapUsedBytes: Int64
        public var activeBuilds: Int
        public var abandonedProcesses: Int
        public var agentSessions: Int
        public var growth24hBytes: Int64?
        public var growth24hSpanSeconds: Double?
        public var paused: Bool
    }

    public func statusSummary() async -> StatusSummary {
        let liveState = await refreshLive()
        let day = store.diskGrowth(window: 86_400)
        return StatusSummary(
            diskAvailableBytes: liveState.telemetry.diskAvailableBytes, diskTotalBytes: liveState.telemetry.diskTotalBytes,
            reclaimableBytes: storage?.reclaimableBytes, reclaimableIsApproximate: storage?.reclaimableIsApproximate ?? false,
            lastScan: storage?.scan.finishedAt, memoryPressure: liveState.telemetry.pressure,
            swapUsedBytes: liveState.telemetry.swapUsedBytes, activeBuilds: liveState.activeBuildCount,
            abandonedProcesses: liveState.abandoned.count, agentSessions: liveState.agentSessions.count,
            growth24hBytes: day?.deltaBytes, growth24hSpanSeconds: day?.actualSpan, paused: settings.paused)
    }
}
