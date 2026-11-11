import Foundation

/// The memory journal: a reading every five minutes of memory, its owners, every agent session
/// and browser, and what PEPEL did in between.
extension PepelEngine {
    public nonisolated var journal: MemoryJournal { MemoryJournal(directory: paths.supportDirectory + "/journal") }

    static let journalInterval: TimeInterval = 300

    func writeJournal(_ state: LiveState, now: Date) {
        guard journaling, settings.journalEnabled, now.timeIntervalSince(lastJournalAt) >= Self.journalInterval else { return }
        let since = lastJournalAt == .distantPast ? now.addingTimeInterval(-Self.journalInterval) : lastJournalAt
        lastJournalAt = now
        let sample = journalSample(state, since: since, now: now)
        let journal = journal, keep = settings.journalRetentionDays
        // Off the actor: appending a line must never hold up sampling.
        Task.detached(priority: .utility) {
            journal.append(sample)
            journal.prune(keepDays: keep, now: now)
        }
    }

    func journalSample(_ state: LiveState, since: Date, now: Date) -> JournalSample {
        let t = state.telemetry
        let owners = Dictionary(state.memoryOwners.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let agents = state.agentSessions.map { session -> JournalSample.Agent in
            JournalSample.Agent(
                agent: session.kind.displayName, project: session.projectID.map { ($0 as NSString).lastPathComponent }, pid: session.root.pid,
                state: session.isService ? "server" : session.state.rawValue, suspended: session.frozenSince != nil, bytes: session.footprintBytes,
                resident: owners["agent:\(session.root)"]?.residentBytes ?? 0, procs: session.processCount,
                quietMinutes: session.quietSince.map { Int(now.timeIntervalSince($0) / 60) }, ageMinutes: Int(now.timeIntervalSince(session.startedAt) / 60))
        }
        let browsers = state.memoryOwners.filter { $0.kind == .application && BrowserTabs.browsers.contains($0.name) }.map { owner -> JournalSample.Browser in
            let tabs = state.browserTabs.filter { "app:\($0.bundlePath)" == owner.id }
            let idle = tabs.filter { $0.idleFor != nil }
            return JournalSample.Browser(
                name: owner.name, bytes: owner.footprintBytes, resident: owner.residentBytes, procs: owner.processCount, tabs: tabs.count, idleTabs: idle.count,
                idleBytes: idle.reduce(0) { $0 + $1.footprintBytes }, largestTab: tabs.map(\.footprintBytes).max() ?? 0)
        }
        let actions = store.audit(limit: 300, kinds: [.termination, .container, .cleanup])
            .filter { $0.timestamp > since && $0.timestamp <= now }
            .map { JournalSample.Action(at: $0.timestamp, by: $0.initiator, subject: $0.subject, outcome: $0.outcome, bytes: $0.bytes) }
        return JournalSample(
            ts: now, total: t.memoryTotalBytes, used: t.memoryUsedBytes, app: t.appMemoryBytes, wired: t.wiredBytes, compressed: t.compressedBytes,
            cached: t.cachedFileBytes, free: t.freeBytes, swap: t.swapUsedBytes, pressure: t.pressure.rawValue,
            owners: state.memoryOwners.prefix(25).map { JournalSample.Owner(name: $0.name, kind: $0.kind.rawValue, bytes: $0.footprintBytes, resident: $0.residentBytes, procs: $0.processCount) },
            agents: agents, browsers: browsers,
            counts: [
                "abandoned": state.abandoned.count, "leftovers": state.leftovers.reduce(0) { $0 + $1.processes.count }, "suspended": state.frozen.count,
                "dormant": state.dormant.count, "staleBranches": state.staleBranches.count, "idleTabs": state.idleTabs.count,
                "unusedApps": state.unusedApplications.count, "growing": state.growth.count, "orphanedTools": state.orphanedTools.count,
                "simulators": state.simulators.count, "overBudget": state.overBudget.count, "systemRestartable": state.restartableSystem.count,
            ],
            forecastMinutes: state.forecast.map { Int($0.reachesAt.timeIntervalSince(now) / 60) }, actions: actions)
    }

    /// What the journal of the last `days` says.
    public nonisolated func journalDigest(days: Double, now: Date = Date()) -> JournalDigest {
        JournalDigest.make(journal.read(since: now.addingTimeInterval(-days * 86_400)))
    }
}
