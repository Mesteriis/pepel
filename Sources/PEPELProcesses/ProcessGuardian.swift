import Foundation
import PEPELCore

public struct AssessmentContext: Sendable {
    public var processes: [ProcessSnapshot]
    public var history: [ProcessIdentity: [ProcessObservation]]
    public var protections: [ProtectionRule]
    public var attributor: (any ProjectAttributing)?
    public var now: Date
    /// How long a process must be observed doing nothing before it can count as abandoned.
    public var idleWindow: TimeInterval
    /// Agent sessions found asleep, with the evidence for it. Everything else about agents stays protected.
    public var sleepingAgents: [ProcessIdentity: [String]] = [:]

    public init(
        processes: [ProcessSnapshot], history: [ProcessIdentity: [ProcessObservation]] = [:],
        protections: [ProtectionRule] = [], attributor: (any ProjectAttributing)? = nil, now: Date = Date(),
        idleWindow: TimeInterval = 30 * 60
    ) {
        self.processes = processes
        self.history = history
        self.protections = protections
        self.attributor = attributor
        self.now = now
        self.idleWindow = idleWindow
    }
}

/// Decides, per developer process, whether it is working, deliberately running, or left behind.
///
/// A dead parent is never enough on its own: `nohup`-style services are orphans by design. A
/// process only counts as abandoned when several independent observations agree.
public enum ProcessGuardian {
    public static func assess(_ context: AssessmentContext) -> [ProcessAssessment] {
        let tree = ProcessTree(context.processes)
        var roles: [Int32: ProcessRole] = [:]
        for p in context.processes { roles[p.pid] = RoleClassifier.role(of: p, attributor: context.attributor) }
        return context.processes.compactMap { p in
            guard let role = roles[p.pid], role.isDeveloperWorkload else { return nil }
            return assess(p, role: role, roles: roles, tree: tree, context: context)
        }
    }

    static func protectionMatch(_ p: ProcessSnapshot, rules: [ProtectionRule]) -> ProtectionRule? {
        let line = p.arguments.joined(separator: " ")
        return rules.first { rule in
            switch rule.kind {
            case .processName: p.name == rule.value
            case .command: !rule.value.isEmpty && line.contains(rule.value)
            case .port: UInt16(rule.value).map { p.listeningPorts.contains($0) } ?? false
            case .path, .pin, .project: false
            }
        }
    }

    private static func assess(
        _ p: ProcessSnapshot, role: ProcessRole, roles: [Int32: ProcessRole], tree: ProcessTree, context: AssessmentContext
    ) -> ProcessAssessment {
        var evidence: [String] = []
        let ancestors = tree.ancestors(of: p)
        let descendants = tree.descendants(of: p)
        let agentAncestor = ancestors.first { roles[$0.pid] == .agent }
        let orphan = tree.isOrphan(p)
        let subtreeFootprint = descendants.reduce(p.footprintBytes) { $0 + $1.footprintBytes }

        // Ownership: the working directory is direct evidence; a path in the command line is a hint.
        var projectID: String?
        var projectConfidence = Confidence.unknown
        let cwdMissing = p.workingDirectory.map { !PathUtil.exists($0) } ?? false
        if let cwd = p.workingDirectory, let hit = context.attributor?.attribute(path: cwd) {
            projectID = hit.projectID
            projectConfidence = .verified
            evidence.append(L("Working directory is inside project \((hit.projectID as NSString).lastPathComponent)."))
        } else if let attributor = context.attributor,
            let hit = ([p.executablePath ?? ""] + p.arguments).lazy.filter({ $0.hasPrefix("/") }).compactMap({ attributor.attribute(path: $0) }).first
        {
            projectID = hit.projectID
            projectConfidence = .probable
            evidence.append(L("Command line references project \((hit.projectID as NSString).lastPathComponent)."))
        } else {
            evidence.append(L("No project could be associated with this process."))
        }
        if cwdMissing { evidence.append(L("Its working directory no longer exists.")) }

        // Activity of the whole subtree: an idle parent with busy workers is not idle.
        let members = [p] + descendants
        var subtreeIdle = true
        var shortestObservation = TimeInterval.greatestFiniteMagnitude
        var busiest = 0.0
        for member in members {
            switch ActivityAnalyzer.verdict(
                current: member, history: context.history[member.identity] ?? [], now: context.now, window: context.idleWindow)
            {
            case .idle(let span):
                shortestObservation = min(shortestObservation, span)
            case .active(let percent):
                subtreeIdle = false
                busiest = max(busiest, percent)
            case .insufficientHistory(let span):
                subtreeIdle = false
                shortestObservation = min(shortestObservation, span)
            }
        }
        let insufficient = !subtreeIdle && busiest == 0
        let cpu = ActivityAnalyzer.recentPercent(current: p, history: context.history[p.identity] ?? [], now: context.now)

        func result(_ lifecycle: LifecycleClass, _ confidence: Confidence, _ eligibility: TerminationEligibility) -> ProcessAssessment {
            ProcessAssessment(
                process: p, role: role, lifecycle: lifecycle, confidence: confidence, projectID: projectID,
                projectConfidence: projectConfidence, evidence: evidence, eligibility: eligibility, cpuPercent: cpu,
                agentAncestor: agentAncestor?.identity, descendantCount: descendants.count, subtreeFootprintBytes: subtreeFootprint)
        }

        if let rule = protectionMatch(p, rules: context.protections) {
            evidence.append(rule.note.isEmpty ? L("Protected by rule “\(rule.value)”.") : L("Protected by rule “\(rule.value)” (\(rule.note))."))
            return result(.backgroundService, .verified, .never(reason: L("Registered as a protected service.")))
        }

        switch role {
        case .agent:
            evidence.append(L("This is an AI coding agent session."))
            if let asleep = context.sleepingAgents[p.identity] {
                evidence += asleep
                evidence.append(L("A session waiting for your reply looks the same as a sleeping one."))
                return result(.agentSession, .verified, .automaticEligible)
            }
            return result(.agentSession, .verified, .never(reason: L("Agent sessions that are working or only briefly idle are never terminated.")))
        case .container:
            evidence.append(L("Container runtime process; containers may hold databases and volumes."))
            return result(.backgroundService, .probable, .never(reason: L("Container runtimes are managed through their own tools.")))
        default:
            break
        }

        if let agentAncestor {
            if let kind = RoleClassifier.agentKind(of: agentAncestor) {
                evidence.append(L("Started by \(kind.displayName) session (PID \(agentAncestor.pid)), which is still running."))
            } else {
                evidence.append(L("Started by an agent session (PID \(agentAncestor.pid)), which is still running."))
            }
        }
        if p.hasControllingTerminal { evidence.append(L("Attached to a terminal.")) }
        if orphan {
            evidence.append(L("Its parent process has exited; it now belongs to launchd."))
        } else if let parent = tree.parent(of: p) {
            evidence.append(L("Parent \(parent.name) (PID \(parent.pid)) is alive."))
        }
        if subtreeIdle {
            evidence.append(L("No CPU activity in its process tree for \(TimeFormat.age(shortestObservation)) of observation."))
        } else if insufficient {
            let seen = shortestObservation == .greatestFiniteMagnitude ? 0 : shortestObservation
            evidence.append(L("Observed for only \(TimeFormat.age(seen)); \(TimeFormat.age(context.idleWindow)) of inactivity is required before calling it idle."))
        } else {
            let share = String(format: "%.1f%%", busiest)
            evidence.append(L("Its process tree is using CPU (\(share) of a core)."))
        }
        if !p.listeningPorts.isEmpty {
            let ports = p.listeningPorts.map(String.init).joined(separator: ", ")
            evidence.append(p.listeningPorts.count > 1 ? L("Listening on ports \(ports).") : L("Listening on port \(ports)."))
        }

        let disposableRole = role == .testRunner || role == .buildTool

        switch role {
        case .buildTool, .testRunner:
            if !orphan {
                if agentAncestor != nil || p.hasControllingTerminal || !subtreeIdle {
                    return result(.activeBuildOrTest, subtreeIdle ? .probable : .verified, .never(reason: L("Active builds and tests are never interrupted.")))
                }
                // Parent alive, no terminal, no agent, and verifiably idle: stuck, but someone may still be waiting on it.
                return result(.unknown, .probable, .approvalRequired(warning: L("Its parent process is still running and may be waiting for it.")))
            }
            if subtreeIdle {
                let verified = projectConfidence == .verified && !p.hasControllingTerminal && p.listeningPorts.isEmpty
                let eligibility: TerminationEligibility =
                    verified && disposableRole && agentAncestor == nil
                    ? .automaticEligible
                    : .approvalRequired(warning: projectConfidence == .verified ? L("It still holds a terminal or a listening port.") : L("Ownership could not be verified."))
                return result(.abandonedSubprocess, cwdMissing || verified ? .verified : .probable, eligibility)
            }
            if insufficient {
                return result(.unknown, .unknown, .approvalRequired(warning: L("Not observed long enough to tell whether it is still working.")))
            }
            evidence.append(L("Orphaned but still working; it may be a long job started with nohup."))
            return result(.suspiciousOrphan, .probable, .approvalRequired(warning: L("It is still using CPU and may be doing real work.")))

        case .devServer:
            if !orphan {
                if agentAncestor != nil {
                    return result(.activeDevService, .verified, .never(reason: L("Owned by a running agent session.")))
                }
                return result(.activeDevService, .probable, .approvalRequired(warning: L("This development server appears to be in use.")))
            }
            if cwdMissing {
                return result(.suspiciousOrphan, .probable, .approvalRequired(warning: L("Clients connected to it would be disconnected.")))
            }
            evidence.append(L("Detached servers are often left running on purpose, so this is not treated as garbage."))
            return result(.backgroundService, .probable, .approvalRequired(warning: L("This looks like a service left running intentionally.")))

        default:
            if agentAncestor != nil {
                // Tool servers and helpers an agent started belong to that session.
                return result(.activeDevService, .verified, .never(reason: L("Owned by a running agent session.")))
            }
            if orphan && subtreeIdle {
                return result(.suspiciousOrphan, .probable, .approvalRequired(warning: L("PEPEL cannot tell what this program is for.")))
            }
            return result(.unknown, .unknown, .approvalRequired(warning: L("PEPEL cannot tell what this program is for.")))
        }
    }
}
