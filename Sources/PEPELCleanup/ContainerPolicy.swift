import Foundation
import PEPELCore
import PEPELPersistence

public struct ContainerStopDecision: Codable, Sendable, Hashable {
    public var group: ContainerGroup
    public var verdict: CleanupVerdict
    public var reasons: [String]
    public var warnings: [String]
}

/// A container stop the policy engine cleared. Cannot be built outside this module.
public struct ApprovedContainerStop: Sendable {
    public let group: ContainerGroup
    public let initiator: Initiator

    init(group: ContainerGroup, initiator: Initiator) {
        self.group = group
        self.initiator = initiator
    }
}

extension CleanupPolicyEngine {
    /// Whether the containers of one compose project may be stopped. Stopping keeps containers
    /// and volumes; it is the reversible end of what Docker offers, and the only one PEPEL uses.
    public func evaluateContainerStop(
        _ group: ContainerGroup, initiator: Initiator, settings: PepelSettings, protections: [ProtectionRule], leases: [ResourceLease],
        now: Date = Date()
    ) -> ContainerStopDecision {
        var denials: [String] = []
        var confirmations: [String] = []
        var warnings = ["Containers and their volumes are kept; `docker compose start` brings them back."]

        if group.containers.isEmpty { denials.append("No running containers in this group.") }
        if let projectID = group.projectID {
            if protections.contains(where: { $0.kind == .project && PathUtil.isInsideIgnoringCase(projectID, root: $0.value) }) {
                denials.append("Its project is excluded by one of your protection rules.")
            }
            if let lease = leases.first(where: { $0.isActive(at: now) && $0.covers(projectID) }) {
                denials.append("Leased by \(lease.owner) until \(lease.expiresAt.formatted(date: .omitted, time: .shortened)).")
            }
        }
        if group.agentSessions > 0 {
            let text = "\(group.agentSessions) agent session\(group.agentSessions == 1 ? " is" : "s are") running in this project."
            if initiator == .automatic { denials.append(text) } else { confirmations.append(text) }
        }

        switch initiator {
        case .agent:
            denials.append("Agents cannot have containers stopped.")
        case .automatic:
            if !settings.stopContainersOfIdleProjects { denials.append("Stopping containers of idle projects is not enabled.") }
            if group.projectID == nil {
                // Without a project there is nothing to tie the containers to an agent's work.
                denials.append("These containers are not tied to a known project.")
            } else if let idleSince = group.idleSince {
                let grace = TimeInterval(settings.projectIdleGraceMinutes) * 60
                if now.timeIntervalSince(idleSince) < grace {
                    denials.append("The project has been without an agent session for \(TimeFormat.age(now.timeIntervalSince(idleSince))); the threshold is \(settings.projectIdleGraceMinutes) minutes.")
                }
            } else if group.agentSessions == 0 {
                denials.append("PEPEL has not observed this project long enough.")
            }
        case .user, .cli:
            confirmations.append("Stopping always needs your confirmation when requested by hand.")
            if group.projectID == nil { warnings.append("These containers are not tied to a known project.") }
        }
        let verdict: CleanupVerdict = !denials.isEmpty ? .denied : !confirmations.isEmpty ? .needsConfirmation : .allowed
        return ContainerStopDecision(group: group, verdict: verdict, reasons: denials.isEmpty ? confirmations : denials, warnings: warnings)
    }

    public func approveContainerStop(_ decision: ContainerStopDecision, confirmed: Bool, initiator: Initiator) -> ApprovedContainerStop? {
        switch decision.verdict {
        case .denied: return nil
        case .needsConfirmation: guard confirmed, initiator == .user || initiator == .cli else { return nil }
        case .allowed: break
        }
        return ApprovedContainerStop(group: decision.group, initiator: initiator)
    }
}

public struct ContainerStopReport: Codable, Sendable {
    public var groupName: String
    public var stopped: [String]
    public var failed: [String]
    /// What the containers used, by the runtime's accounting, before they were stopped.
    public var memoryBytes: Int64
}

/// Stops containers through `docker stop`. Never `rm`, never `down`, never anything on volumes.
public struct ContainerStopper: Sendable {
    public typealias Runner = @Sendable (_ arguments: [String], _ timeout: TimeInterval) -> (status: Int32, output: String)?

    let run: Runner
    let store: PepelStore?

    public init(tools: ToolRunner, store: PepelStore?) {
        run = { arguments, timeout in tools.run("docker", arguments, timeout: timeout) }
        self.store = store
    }

    public init(store: PepelStore?, run: @escaping Runner) {
        self.run = run
        self.store = store
    }

    public func stop(_ approved: ApprovedContainerStop) -> ContainerStopReport {
        let names = approved.group.containers.map(\.name)
        var report = ContainerStopReport(groupName: approved.group.name, stopped: [], failed: [], memoryBytes: approved.group.memoryBytes)
        // `docker stop` prints the name of each container it stopped, one per line.
        if let result = run(["stop"] + names, 180) {
            let printed = Set(result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
            report.stopped = names.filter { printed.contains($0) }
            report.failed = names.filter { !printed.contains($0) }
        } else {
            report.failed = names
        }
        store?.appendAudit(
            AuditEntry(
                kind: .container, initiator: approved.initiator.rawValue, subject: "\(approved.group.name) (\(names.count) containers)",
                outcome: report.failed.isEmpty ? "stopped" : "stopped \(report.stopped.count) of \(names.count)", bytes: 0,
                detail: [
                    "containers": names.joined(separator: ", "), "memoryInsideVM": Bytes.format(report.memoryBytes),
                    "project": approved.group.projectID ?? "", "failed": report.failed.joined(separator: ", "),
                ]))
        return report
    }
}
