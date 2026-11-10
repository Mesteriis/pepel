import Foundation
import PEPELCore
import PEPELProcesses

/// Finds agent sessions by observing processes. No agent-internal file is read, so this keeps
/// working when an agent changes its private formats.
public enum AgentDetector {
    public static func sessions(
        processes: [ProcessSnapshot], attributor: (any ProjectAttributing)?, history: [ProcessIdentity: [ProcessObservation]] = [:],
        now: Date = Date(), sleepWindow: TimeInterval = 2 * 3600, leases: [ResourceLease] = []
    ) -> [AgentSession] {
        let tree = ProcessTree(processes)
        var sessions: [AgentSession] = []
        for p in processes {
            guard let kind = RoleClassifier.agentKind(of: p) else { continue }
            // Helper processes of the same agent belong to the session of their topmost ancestor.
            if tree.ancestors(of: p).contains(where: { RoleClassifier.agentKind(of: $0) == kind }) { continue }
            let members = tree.descendants(of: p)
            let all = [p] + members
            let attribution = p.workingDirectory.flatMap { attributor?.attribute(path: $0) }
            let percents = all.compactMap { ActivityAnalyzer.recentPercent(current: $0, history: history[$0.identity] ?? [], now: now) }
            let builds = members.filter {
                let role = RoleClassifier.role(of: $0)
                return role == .buildTool || role == .testRunner
            }.count
            let leased = leases.contains { lease in
                guard lease.isActive(at: now) else { return false }
                return [p.workingDirectory, attribution?.projectID].compactMap { $0 }.contains { lease.covers($0) }
            }
            let verdict = AgentActivity.verdict(
                root: p, members: members, history: history, activeBuildCount: builds, hasActiveLease: leased, now: now,
                sleepWindow: sleepWindow)
            var session =
                AgentSession(
                    kind: kind, root: p.identity, workingDirectory: p.workingDirectory, projectID: attribution?.projectID,
                    projectConfidence: attribution == nil ? .unknown : .verified, processCount: all.count,
                    footprintBytes: all.reduce(0) { $0 + $1.footprintBytes },
                    activeBuildCount: builds,
                    recentlyActive: percents.isEmpty ? nil : percents.contains { $0 >= ActivityAnalyzer.idleThresholdPercent },
                    startedAt: p.identity.startDate)
            session.isService = AgentActivity.isService(p)
            session.state = verdict.state
            session.quietSince = verdict.quietSince
            session.observedFor = verdict.observedFor
            session.evidence = verdict.evidence
            sessions.append(session)
        }
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }
}
