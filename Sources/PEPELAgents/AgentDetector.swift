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
            session.hostApp = BBProcesses.isRuntime(p, ancestors: tree.ancestors(of: p)) ? "BB" : nil
            session.state = verdict.state
            session.quietSince = verdict.quietSince
            session.observedFor = verdict.observedFor
            session.evidence = verdict.evidence
            sessions.append(session)
        }
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    /// A command reduced to what identifies the program: the executable name and its first few
    /// arguments, with directories shortened to their last two components and options dropped,
    /// so the same server started from ten sessions reads as one line.
    static func signature(_ p: ProcessSnapshot) -> String {
        var parts: [String] = []
        for (index, raw) in p.arguments.enumerated() {
            if index > 0, raw.hasPrefix("-") { continue }
            var token = raw
            if raw.contains("/") {
                let components = raw.split(separator: "/")
                token = index == 0 ? String(components.last ?? "") : components.suffix(2).joined(separator: "/")
            }
            // Version numbers and hashes differ per install without changing what the program is.
            if token.count > 20, token.allSatisfy({ $0.isHexDigit || $0 == "-" }) { continue }
            if !token.isEmpty { parts.append(token) }
            if parts.count == 4 { break }
        }
        return parts.isEmpty ? p.name : parts.joined(separator: " ")
    }

    /// Helper programs that run in more than one copy across agent sessions, largest first.
    public static func helperGroups(processes: [ProcessSnapshot], sessions: [AgentSession]) -> [AgentHelperGroup] {
        let tree = ProcessTree(processes)
        var groups: [String: (copies: Int, sessions: Set<ProcessIdentity>, bytes: Int64, quietCopies: Int, quietBytes: Int64)] = [:]
        for session in sessions where !session.isService {
            guard let root = tree.process(session.root) else { continue }
            for helper in tree.descendants(of: root) where RoleClassifier.agentKind(of: helper) == nil {
                let key = signature(helper)
                var group = groups[key] ?? (0, [], 0, 0, 0)
                if session.state != .working {
                    group.quietCopies += 1
                    group.quietBytes += helper.footprintBytes
                }
                group.copies += 1
                group.sessions.insert(session.root)
                group.bytes += helper.footprintBytes
                groups[key] = group
            }
        }
        return groups.filter { $0.value.sessions.count > 1 }
            .map { entry -> AgentHelperGroup in
                var group = AgentHelperGroup(id: entry.key, copies: entry.value.copies, sessions: entry.value.sessions.count, footprintBytes: entry.value.bytes)
                group.quietCopies = entry.value.quietCopies
                group.quietBytes = entry.value.quietBytes
                return group
            }
            .sorted { ($0.duplicatedBytes, $0.id) > ($1.duplicatedBytes, $1.id) }
    }
}
