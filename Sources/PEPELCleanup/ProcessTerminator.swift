import Darwin
import Foundation
import PEPELCore
import PEPELPersistence

public struct TerminationDecision: Codable, Sendable, Hashable {
    public var target: ProcessAssessment
    public var verdict: CleanupVerdict
    public var reasons: [String]
    public var warnings: [String]
    /// Descendants that would be terminated together with the target.
    public var descendants: [ProcessIdentity]
}

/// A termination the policy engine cleared. Like `ApprovedAction`, it cannot be built elsewhere.
public struct ApprovedTermination: Sendable {
    public let target: ProcessAssessment
    public let descendants: [ProcessIdentity]
    public let allowForce: Bool
    public let graceSeconds: Int
    public let initiator: Initiator

    init(target: ProcessAssessment, descendants: [ProcessIdentity], allowForce: Bool, graceSeconds: Int, initiator: Initiator) {
        self.target = target
        self.descendants = descendants
        self.allowForce = allowForce
        self.graceSeconds = graceSeconds
        self.initiator = initiator
    }
}

extension CleanupPolicyEngine {
    /// - Parameter descendants: assessments or bare snapshots of the target's process subtree.
    public func evaluateTermination(
        _ target: ProcessAssessment, descendants: [ProcessSnapshot], descendantAssessments: [ProcessAssessment],
        initiator: Initiator, settings: PepelSettings, currentUID: UInt32 = getuid(), ownPID: Int32 = getpid()
    ) -> TerminationDecision {
        var denials: [String] = []
        var confirmations: [String] = []
        var warnings: [String] = []
        let p = target.process

        if p.pid <= 1 { denials.append("System process.") }
        if p.pid == ownPID || descendants.contains(where: { $0.pid == ownPID }) { denials.append("PEPEL does not terminate itself or its own ancestors.") }
        if p.uid != currentUID { denials.append("The process belongs to another user.") }
        // Two things PEPEL acts on: developer workloads, and whatever a quit application left behind.
        let leftover = target.leftoverOf != nil
        if !target.role.isDeveloperWorkload && !leftover { denials.append("Not a developer workload; PEPEL leaves applications and system processes alone.") }

        switch target.eligibility {
        case .never(let reason):
            denials.append(reason)
        case .approvalRequired(let warning):
            confirmations.append(warning)
        case .automaticEligible:
            break
        }
        // A sleeping agent session goes down with the tool servers it started; they are "owned by
        // an agent session" only for as long as that session is worth keeping.
        let sleepingAgent = target.lifecycle == .agentSession && target.eligibility == .automaticEligible
        for child in descendantAssessments where !sleepingAgent {
            if case .never(let reason) = child.eligibility {
                denials.append("Its descendant \(child.process.name) (PID \(child.process.pid)) must not be terminated: \(reason)")
            }
        }
        if target.projectConfidence == .unknown, !leftover { warnings.append("PEPEL could not establish which project this process belongs to.") }
        if !descendants.isEmpty { warnings.append("\(descendants.count) child process\(descendants.count == 1 ? "" : "es") will be terminated with it.") }
        if !p.listeningPorts.isEmpty { warnings.append("Clients connected to port \(p.listeningPorts.map(String.init).joined(separator: ", ")) will be disconnected.") }

        switch initiator {
        case .agent:
            denials.append("Agents cannot request process termination.")
        case .automatic:
            if sleepingAgent {
                if !settings.terminateSleepingAgents { denials.append("Terminating sleeping agent sessions is not enabled.") }
            } else if leftover {
                if !settings.terminateAppLeftovers { denials.append("Terminating what quit applications leave behind is not enabled.") }
                if target.eligibility != .automaticEligible { denials.append("This leftover needs your decision.") }
            } else {
                if !settings.autoTerminateAbandoned { denials.append("Automatic termination is not enabled.") }
                if target.eligibility != .automaticEligible || target.lifecycle != .abandonedSubprocess || target.confidence != .verified {
                    denials.append("Only verified abandoned build and test processes are terminated automatically.")
                }
            }
        case .user, .cli:
            if target.eligibility == .automaticEligible { confirmations.append("Termination always needs your confirmation when requested manually.") }
        }

        let verdict: CleanupVerdict = !denials.isEmpty ? .denied : !confirmations.isEmpty ? .needsConfirmation : .allowed
        return TerminationDecision(
            target: target, verdict: verdict, reasons: denials.isEmpty ? confirmations : denials, warnings: warnings,
            descendants: descendants.map(\.identity))
    }

    /// - Parameter force: escalation to SIGKILL; honoured only for an explicit user request.
    public func approveTermination(_ decision: TerminationDecision, confirmed: Bool, force: Bool, initiator: Initiator, settings: PepelSettings) -> ApprovedTermination? {
        switch decision.verdict {
        case .denied: return nil
        case .needsConfirmation: guard confirmed, initiator == .user || initiator == .cli else { return nil }
        case .allowed: break
        }
        return ApprovedTermination(
            target: decision.target, descendants: decision.descendants,
            allowForce: force && confirmed && (initiator == .user || initiator == .cli),
            graceSeconds: settings.gracefulTerminationSeconds, initiator: initiator)
    }
}

/// How the terminator talks to the process table; replaced by a fake in tests.
public protocol ProcessControl: Sendable {
    /// Identity currently behind `pid`, or nil when no live process has it.
    func identity(of pid: Int32) -> ProcessIdentity?
    func send(_ signal: Int32, to pid: Int32) -> Bool
}

public struct TerminationReport: Codable, Sendable {
    public var target: ProcessIdentity
    public var name: String
    public var steps: [String]
    public var exited: Bool
    public var forced: Bool
    public var footprintBefore: Int64
    public var before: SystemTelemetry
    public var after: SystemTelemetry

    /// Observed change in used memory. A process's footprint is not a promise of this much
    /// becoming available: shared pages, caches and other activity all move the number.
    public var observedMemoryChange: Int64 { after.memoryUsedBytes - before.memoryUsedBytes }
}

public struct ProcessTerminator: Sendable {
    public let control: any ProcessControl
    public let store: PepelStore?
    public var pollInterval: Duration = .milliseconds(200)
    public var settle: Duration = .seconds(1)

    public init(control: any ProcessControl, store: PepelStore?) {
        self.control = control
        self.store = store
    }

    private func alive(_ identity: ProcessIdentity) -> Bool { control.identity(of: identity.pid) == identity }

    private func waitForExit(_ identity: ProcessIdentity, seconds: Double) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while alive(identity) {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: pollInterval)
        }
        return true
    }

    public func terminate(_ approved: ApprovedTermination, telemetry: @Sendable () -> SystemTelemetry) async -> TerminationReport {
        let target = approved.target.process
        var report = TerminationReport(
            target: target.identity, name: target.name, steps: [], exited: false, forced: false,
            footprintBefore: approved.target.subtreeFootprintBytes, before: telemetry(), after: SystemTelemetry())

        // The PID may have been reused since the assessment: act only on the same process.
        guard alive(target.identity) else {
            report.steps.append("PID \(target.pid) no longer refers to the assessed process; nothing was signalled.")
            report.exited = control.identity(of: target.pid) == nil
            report.after = telemetry()
            record(report, initiator: approved.initiator, outcome: "not signalled")
            return report
        }

        _ = control.send(SIGTERM, to: target.pid)
        report.steps.append("Sent SIGTERM to \(target.name) (PID \(target.pid)).")
        report.exited = await waitForExit(target.identity, seconds: Double(approved.graceSeconds))
        report.steps.append(report.exited ? "It exited." : "Still running after \(approved.graceSeconds) seconds.")

        // Children that outlive their parent would become new orphans.
        for child in approved.descendants where alive(child) {
            _ = control.send(SIGTERM, to: child.pid)
            report.steps.append("Sent SIGTERM to child PID \(child.pid).")
        }

        if !report.exited {
            if approved.allowForce, alive(target.identity) {
                _ = control.send(SIGKILL, to: target.pid)
                report.forced = true
                report.steps.append("Escalated to SIGKILL as you authorised.")
                report.exited = await waitForExit(target.identity, seconds: 3)
                report.steps.append(report.exited ? "It exited." : "It is still present.")
            } else {
                report.steps.append("Not escalated: forced termination was not authorised.")
            }
        }

        try? await Task.sleep(for: settle)
        report.after = telemetry()
        record(report, initiator: approved.initiator, outcome: report.exited ? (report.forced ? "killed" : "terminated") : "still running")
        return report
    }

    private func record(_ report: TerminationReport, initiator: Initiator, outcome: String) {
        store?.appendAudit(
            AuditEntry(
                kind: .termination, initiator: initiator.rawValue, subject: "\(report.name) (PID \(report.target.pid))",
                outcome: outcome, bytes: 0,
                detail: [
                    "footprintBefore": Bytes.format(report.footprintBefore),
                    "memoryUsedBefore": Bytes.format(report.before.memoryUsedBytes),
                    "memoryUsedAfter": Bytes.format(report.after.memoryUsedBytes),
                    "observedChange": Bytes.formatDelta(report.observedMemoryChange),
                    "pressureBefore": report.before.pressure.rawValue, "pressureAfter": report.after.pressure.rawValue,
                    "swapBefore": Bytes.format(report.before.swapUsedBytes), "swapAfter": Bytes.format(report.after.swapUsedBytes),
                    "steps": report.steps.joined(separator: " "),
                ]))
    }
}
