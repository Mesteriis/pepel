import Darwin
import Foundation
import PEPELCore

public struct FreezeDecision: Codable, Sendable, Hashable {
    public var session: AgentSession
    public var verdict: CleanupVerdict
    public var reasons: [String]
    public var warnings: [String]
}

/// A suspension the policy engine cleared; cannot be built elsewhere.
public struct ApprovedFreeze: Sendable {
    public let session: AgentSession
    public let members: [ProcessIdentity]
    public let initiator: Initiator

    init(session: AgentSession, members: [ProcessIdentity], initiator: Initiator) {
        self.session = session
        self.members = members
        self.initiator = initiator
    }
}

extension CleanupPolicyEngine {
    /// Whether an agent session may be suspended.
    ///
    /// Suspending loses nothing, so the bar is lower than for ending a session, but a suspended
    /// session cannot answer anyone. Automatically it therefore happens only when PEPEL knows
    /// which application the session lives in and can see that the application is not in front,
    /// so that coming back to it wakes the session.
    /// - Parameters:
    ///   - members: the session's whole process tree, root included.
    ///   - ownerAppPID: the application the session runs inside, when one was found.
    ///   - frontmostPID: the application in front; nil when PEPEL cannot tell.
    public func evaluateFreeze(
        _ session: AgentSession, members: [ProcessSnapshot], ownerAppPID: Int32?, frontmostPID: Int32?, initiator: Initiator,
        settings: PepelSettings, now: Date = Date(), currentUID: UInt32 = getuid(), ownPID: Int32 = getpid(), ownAncestors: Set<Int32> = []
    ) -> FreezeDecision {
        var denials: [String] = []
        var confirmations: [String] = []
        var warnings: [String] = []

        if session.isService { denials.append("This is a server for an application, not a session; suspending it would hang the application.") }
        if session.state == .working { denials.append("The session is working.") }
        if session.activeBuildCount > 0 { denials.append("A build or test run is in progress inside the session.") }
        if session.frozenSince != nil { denials.append("The session is already suspended.") }
        if members.contains(where: { $0.pid == ownPID || ownAncestors.contains($0.pid) }) { denials.append("PEPEL does not suspend the session it is running in.") }
        if members.contains(where: { $0.uid != currentUID }) { denials.append("Part of the session belongs to another user.") }
        if members.contains(where: { !$0.listeningPorts.isEmpty }) { warnings.append("A process in the session listens on a port; clients will wait while it is suspended.") }

        switch initiator {
        case .agent:
            denials.append("Agents cannot have sessions suspended.")
        case .automatic:
            if !settings.freezeIdleAgents || settings.paused { denials.append("Suspending idle agent sessions is not enabled.") }
            let quiet = session.quietSince.map { now.timeIntervalSince($0) } ?? 0
            if quiet < TimeInterval(settings.freezeAfterMinutes) * 60 {
                denials.append("Quiet for \(TimeFormat.age(quiet)); the threshold is \(settings.freezeAfterMinutes) minutes.")
            }
            if ownerAppPID == nil {
                denials.append("PEPEL cannot tell which application this session lives in, so it could not wake it when you come back.")
            } else if frontmostPID == nil {
                denials.append("PEPEL cannot tell which application is in front.")
            } else if ownerAppPID == frontmostPID {
                denials.append("The session's application is in front.")
            }
        case .user, .cli:
            confirmations.append("The session stops responding until it is woken.")
            if ownerAppPID == nil { warnings.append("PEPEL cannot tell which application this session lives in; wake it yourself with `pepel thaw`.") }
        }
        let verdict: CleanupVerdict = !denials.isEmpty ? .denied : !confirmations.isEmpty ? .needsConfirmation : .allowed
        return FreezeDecision(session: session, verdict: verdict, reasons: denials.isEmpty ? confirmations : denials, warnings: warnings)
    }

    public func approveFreeze(_ decision: FreezeDecision, members: [ProcessIdentity], confirmed: Bool, initiator: Initiator) -> ApprovedFreeze? {
        switch decision.verdict {
        case .denied: return nil
        case .needsConfirmation: guard confirmed, initiator == .user || initiator == .cli else { return nil }
        case .allowed: break
        }
        return ApprovedFreeze(session: decision.session, members: members, initiator: initiator)
    }
}
