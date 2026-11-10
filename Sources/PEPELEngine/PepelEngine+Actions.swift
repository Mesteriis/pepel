import Foundation

/// Bridges the engine's process source to the terminator.
struct SourceProcessControl: ProcessControl {
    let source: any ProcessSource

    func identity(of pid: Int32) -> ProcessIdentity? { source.identity(of: pid) }
    func send(_ signal: Int32, to pid: Int32) -> Bool { kill(pid, signal) == 0 }
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
        guard !settings.paused else { return (nil, []) }
        if settings.monitoringMode == .automaticSafe, let storage {
            let safe = Set(storage.items.filter { $0.safety == .safe }.map(\.id))
            if !safe.isEmpty {
                let plan = await cleanupPlan(itemIDs: safe, initiator: .automatic)
                if plan.decisions.contains(where: { $0.verdict == .allowed }) {
                    cleanup = await executeCleanup(plan, confirmed: [], dryRun: false)
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
        guard let target = liveState.assessments.first(where: { $0.process.identity == identity }) else { return nil }
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
