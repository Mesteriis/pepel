import Foundation
import PEPELCore
import PEPELProcesses

/// Finds agent sessions by observing processes. No agent-internal file is read, so this keeps
/// working when an agent changes its private formats.
public enum AgentDetector {
    public static func sessions(
        processes: [ProcessSnapshot], attributor: (any ProjectAttributing)?, history: [ProcessIdentity: [ProcessObservation]] = [:],
        now: Date = Date()
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
            sessions.append(
                AgentSession(
                    kind: kind, root: p.identity, workingDirectory: p.workingDirectory, projectID: attribution?.projectID,
                    projectConfidence: attribution == nil ? .unknown : .verified, processCount: all.count,
                    footprintBytes: all.reduce(0) { $0 + $1.footprintBytes },
                    activeBuildCount: members.filter {
                        let role = RoleClassifier.role(of: $0)
                        return role == .buildTool || role == .testRunner
                    }.count,
                    recentlyActive: percents.isEmpty ? nil : percents.contains { $0 >= ActivityAnalyzer.idleThresholdPercent },
                    startedAt: p.identity.startDate))
        }
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }
}
