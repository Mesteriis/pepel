import Darwin
import Foundation
import PEPELCore

public enum ApplicationAction: String, Codable, Sendable {
    /// Quit normally and open again: returns what the application accumulated.
    case restart
    /// Quit normally and leave closed.
    case quit
}

public struct ApplicationDecision: Codable, Sendable, Hashable {
    public var action: ApplicationAction
    public var bundlePath: String
    public var name: String
    public var pid: Int32
    public var footprintBytes: Int64
    public var verdict: CleanupVerdict
    public var reasons: [String]
    public var warnings: [String]
}

/// An application action the policy engine cleared; cannot be built elsewhere.
public struct ApprovedApplicationAction: Sendable {
    public let decision: ApplicationDecision
    init(decision: ApplicationDecision) { self.decision = decision }
}

extension CleanupPolicyEngine {
    /// Whether PEPEL may ask an application to quit (and open it again).
    ///
    /// The request is the ordinary one, so unsaved work is the application's to ask about. What
    /// PEPEL must not do is take down things that live inside the application: agent sessions and
    /// builds in a terminal, or itself. Only a person can ask.
    /// - Parameters:
    ///   - agentSessions: sessions running inside this application.
    ///   - developerProcesses: builds, tests and servers running inside it.
    public func evaluateApplication(
        _ action: ApplicationAction, bundlePath: String, name: String, pid: Int32, footprintBytes: Int64, agentSessions: Int,
        developerProcesses: Int, isFrontmost: Bool, initiator: Initiator, ownPID: Int32 = getpid(), ownAncestors: Set<Int32> = []
    ) -> ApplicationDecision {
        var denials: [String] = []
        var warnings: [String] = []
        if initiator == .agent || initiator == .automatic { denials.append(L("Only you can have an application quit.")) }
        if pid == ownPID || ownAncestors.contains(pid) { denials.append(L("PEPEL does not quit itself or the application it runs in.")) }
        // Finder, the Dock and the like. Applications Apple ships (/System/Applications) are ordinary applications.
        if bundlePath.hasPrefix("/System/Library/") { denials.append(L("This is part of macOS.")) }
        if agentSessions > 0 {
            denials.append(L("\(agentSessions) agent sessions run inside \(name) and would end with it."))
        }
        if developerProcesses > 0 {
            denials.append(L("\(developerProcesses) build, test or server processes run inside \(name)."))
        }
        if isFrontmost { warnings.append(L("\(name) is the application in front.")) }
        let verdict: CleanupVerdict = denials.isEmpty ? .needsConfirmation : .denied
        let ask = action == .restart
            ? L("\(name) is asked to quit normally and is opened again. It may ask about unsaved changes; if it does not quit, it is left running.")
            : L("\(name) is asked to quit normally. It may ask about unsaved changes; if it does not quit, it is left running.")
        return ApplicationDecision(
            action: action, bundlePath: bundlePath, name: name, pid: pid, footprintBytes: footprintBytes, verdict: verdict,
            reasons: denials.isEmpty ? [ask] : denials, warnings: warnings)
    }

    public func approveApplication(_ decision: ApplicationDecision, confirmed: Bool, initiator: Initiator) -> ApprovedApplicationAction? {
        guard decision.verdict == .needsConfirmation, confirmed, initiator == .user || initiator == .cli else { return nil }
        return ApprovedApplicationAction(decision: decision)
    }
}
