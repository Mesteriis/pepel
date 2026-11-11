import Foundation
import PEPELCore

public enum Initiator: String, Codable, Sendable {
    case user, cli, automatic, agent
}

public enum CleanupVerdict: String, Codable, Sendable {
    case allowed, needsConfirmation, denied
}

public enum PlannedAction: Codable, Sendable, Hashable {
    /// Move to the Trash. Reversible until the Trash is emptied; frees no space until then.
    case trash
    /// Remove permanently. Irreversible.
    case removePermanently
    case tool(ToolCleanup)
    case none

    public var isUndoable: Bool { self == .trash }

    public var summary: String {
        switch self {
        case .trash: "Move to Trash"
        case .removePermanently: "Remove permanently"
        case .tool(let tool): "Run `\(tool.commandDescription)`"
        case .none: "No action"
        }
    }
}

public struct CleanupDecision: Codable, Sendable, Identifiable, Hashable {
    public var item: StorageItem
    public var verdict: CleanupVerdict
    /// Why it is denied or needs confirmation.
    public var reasons: [String]
    public var warnings: [String]
    public var action: PlannedAction

    public var id: String { item.id }
}

public struct CleanupPlan: Codable, Sendable, Identifiable {
    public var id: String
    public var createdAt: Date
    public var initiator: Initiator
    public var decisions: [CleanupDecision]

    public init(id: String, createdAt: Date, initiator: Initiator, decisions: [CleanupDecision]) {
        self.id = id
        self.createdAt = createdAt
        self.initiator = initiator
        self.decisions = decisions
    }

    public func bytes(_ verdict: CleanupVerdict) -> Int64 {
        decisions.filter { $0.verdict == verdict }.reduce(0) { $0 + $1.item.reclaimableBytes }
    }
}

public struct PolicyContext: Sendable {
    public var settings: PepelSettings
    public var home: String
    public var temporaryRoots: [String]
    public var protections: [ProtectionRule]
    public var leases: [ResourceLease]
    /// Item id → reason, for items in use by running processes.
    public var usage: [String: String]
    public var agentSessions: [AgentSession]
    public var projectRoots: [String]
    public var now: Date

    public init(
        settings: PepelSettings = PepelSettings(), home: String = NSHomeDirectory(), temporaryRoots: [String]? = nil,
        protections: [ProtectionRule] = [], leases: [ResourceLease] = [], usage: [String: String] = [:],
        agentSessions: [AgentSession] = [], projectRoots: [String] = [], now: Date = Date()
    ) {
        self.settings = settings
        self.home = home
        self.temporaryRoots = temporaryRoots ?? ["/private/tmp", "/private/var/folders", PathUtil.canonical(NSTemporaryDirectory())]
        self.protections = protections
        self.leases = leases
        self.usage = usage
        self.agentSessions = agentSessions
        self.projectRoots = projectRoots
        self.now = now
    }
}

/// An item the policy engine cleared for cleanup. Only this module can create one, so nothing
/// outside it — no analyzer, no integration, no UI code — can hand the executor an unchecked path.
public struct ApprovedAction: Sendable, Identifiable {
    public let item: StorageItem
    public let action: PlannedAction
    public let initiator: Initiator
    public let confirmed: Bool

    public var id: String { item.id }

    init(item: StorageItem, action: PlannedAction, initiator: Initiator, confirmed: Bool) {
        self.item = item
        self.action = action
        self.initiator = initiator
        self.confirmed = confirmed
    }
}

/// The single gate every destructive action passes through.
public struct CleanupPolicyEngine: Sendable {
    public init() {}

    /// Home-relative locations that are never cleaned, whatever an analyzer says.
    static let forbiddenHomePaths = [
        ".ssh", ".gnupg", ".aws", ".kube", ".azure", ".netrc", ".config/gh", ".config/gcloud", ".config/op", ".docker/config.json",
        ".claude", ".codex", ".hermes", ".config/opencode", ".local/share/opencode", ".ollama", ".cache/huggingface", ".lmstudio",
        "Library/Keychains", "Library/Application Support", "Library/Containers", "Library/Group Containers", "Library/Preferences",
        "Library/Mail", "Library/Messages", "Library/Mobile Documents", "Library/Developer/Xcode/Archives",
        "Library/Developer/CoreSimulator/Devices",
    ]

    /// Structural checks on the path itself. Returns the reason the path may never be removed.
    public func pathViolation(_ path: String, context: PolicyContext) -> String? {
        guard path.hasPrefix("/") else { return "The path is not absolute." }
        let parts = PathUtil.components(path)
        if parts.contains("..") || parts.contains(".") { return "The path is not normalised." }
        guard let identity = PathUtil.identity(path) else { return "The path does not exist." }
        if identity.isSymlink { return "The path is a symbolic link; PEPEL never follows links." }
        if PathUtil.canonical(path) != path { return "The path passes through a symbolic link." }
        if parts.contains(".git") { return "The path is inside git metadata." }

        let home = PathUtil.canonical(context.home)
        if PathUtil.isInsideIgnoringCase(home, root: path) { return "The path contains your home directory." }
        let inHome = PathUtil.isInside(path, root: home)
        let inTemp = context.temporaryRoots.contains { $0 != path && PathUtil.isInside(path, root: $0) }
        guard inHome || inTemp else { return "The path is outside your home directory and the temporary folders." }
        if inHome {
            let relativeDepth = parts.count - PathUtil.components(home).count
            if relativeDepth < 2 { return "The path is a top-level folder of your home directory." }
            for forbidden in Self.forbiddenHomePaths where PathUtil.isInsideIgnoringCase(path, root: home + "/" + forbidden) {
                return "~/\(forbidden) holds credentials, agent state or application data."
            }
        }
        if let marked = PathUtil.keepMarker(at: path, stopAt: inHome ? home : path) {
            return "\(PathUtil.display(marked, home: context.home)) is marked as not to be cleaned."
        }
        if PathUtil.exists(path + "/.git") { return "The path is a git working tree." }
        if let root = context.projectRoots.first(where: { PathUtil.isInsideIgnoringCase($0, root: path) }) {
            return "The path contains the project \((root as NSString).lastPathComponent)."
        }
        return nil
    }

    func action(for item: StorageItem, settings: PepelSettings) -> PlannedAction {
        switch item.method {
        case .none: return .none
        case .tool(let tool): return .tool(tool)
        case .filesystem:
            switch settings.deletionMode {
            case .trash: return .trash
            case .permanent: return .removePermanently
            case .automatic: return item.safety == .safe ? .removePermanently : .trash
            }
        }
    }

    public func evaluate(_ item: StorageItem, initiator: Initiator, context: PolicyContext) -> CleanupDecision {
        var denials: [String] = []
        var confirmations: [String] = []
        var warnings: [String] = []
        let action = action(for: item, settings: context.settings)

        if item.safety == .protected { denials.append("Protected: \(item.safetyReason)") }
        if action == .none && item.safety != .protected { denials.append("No supported cleanup method is available for this item.") }
        if !item.hasPseudoPath {
            if let violation = pathViolation(item.path, context: context) { denials.append(violation) }
            if let recorded = item.identity, let current = PathUtil.identity(item.path), !recorded.sameObject(as: current) {
                denials.append("The path now points at a different object than the one that was scanned.")
            }
            for rule in context.protections {
                switch rule.kind {
                case .path, .pin:
                    if PathUtil.isInsideIgnoringCase(item.path, root: rule.value) || PathUtil.isInsideIgnoringCase(rule.value, root: item.path) {
                        denials.append(rule.kind == .pin ? "Pinned by you." : "Protected by your rule for \(PathUtil.display(rule.value, home: context.home)).")
                    }
                case .project:
                    if item.projectID == rule.value || PathUtil.isInsideIgnoringCase(item.path, root: rule.value) {
                        denials.append("Its project is excluded from cleanup.")
                    }
                case .processName, .command, .port:
                    break
                }
            }
            if let lease = context.leases.first(where: { $0.isActive(at: context.now) && $0.covers(item.path) }) {
                denials.append("Leased by \(lease.owner) until \(lease.expiresAt.formatted(date: .omitted, time: .shortened)).")
            }
            if let modified = item.lastModified {
                let age = context.now.timeIntervalSince(modified)
                if age < TimeInterval(context.settings.recentWriteProtectionMinutes) * 60 {
                    denials.append("Modified \(TimeFormat.age(age)) ago; it may still be being written.")
                }
            }
        }
        if let usage = context.usage[item.id] { denials.append("In use: \(usage)") }

        if let projectID = item.projectID,
            let session = context.agentSessions.first(where: { $0.projectID == projectID }),
            item.category != .toolCache || item.safety != .safe
        {
            let text = "\(session.kind.displayName) has a session in this project."
            if initiator == .automatic { denials.append(text) } else { confirmations.append(text) }
        }

        if item.size?.inaccessibleCount ?? 0 > 0 { warnings.append("Parts of it could not be read; the size is a lower bound.") }
        if item.size?.hardLinkedBytes ?? 0 > 0 { warnings.append("Contains hard-linked files; less space may be freed than shown.") }
        if !action.isUndoable, action != .none { warnings.append("This cannot be undone.") }
        if action == .trash { warnings.append("Space is reclaimed only when the Trash is emptied.") }

        switch initiator {
        case .agent:
            denials.append("Agents can preview cleanup but cannot run it.")
        case .automatic:
            // Two rules let PEPEL clean on its own: the general "automatic safe" mode, and the
            // rule for artifacts of projects left untouched.
            let staleRule = context.settings.cleanStaleProjects && item.isStale(days: context.settings.staleProjectDays, now: context.now)
            if (context.settings.monitoringMode != .automaticSafe && !staleRule) || context.settings.paused {
                denials.append("Automatic cleanup is not enabled.")
            }
            if item.safety != .safe { denials.append("Only items classified safe are cleaned automatically.") }
        case .user, .cli:
            if item.safety == .review { confirmations.append("Review: \(item.safetyReason)") }
        }

        let verdict: CleanupVerdict = !denials.isEmpty ? .denied : !confirmations.isEmpty ? .needsConfirmation : .allowed
        return CleanupDecision(item: item, verdict: verdict, reasons: denials.isEmpty ? confirmations : denials, warnings: warnings, action: action)
    }

    public func plan(items: [StorageItem], initiator: Initiator, context: PolicyContext) -> CleanupPlan {
        CleanupPlan(
            id: UUID().uuidString, createdAt: context.now, initiator: initiator,
            decisions: items.map { evaluate($0, initiator: initiator, context: context) })
    }

    /// Turns a plan into executable approvals. Every item is evaluated again against `context`;
    /// items needing confirmation are included only when their id is in `confirmed`.
    public func approve(_ plan: CleanupPlan, confirmed: Set<String>, context: PolicyContext) -> [ApprovedAction] {
        plan.decisions.compactMap { previous in
            let decision = evaluate(previous.item, initiator: plan.initiator, context: context)
            switch decision.verdict {
            case .denied:
                return nil
            case .needsConfirmation:
                guard confirmed.contains(decision.id), plan.initiator == .user || plan.initiator == .cli else { return nil }
                return ApprovedAction(item: decision.item, action: decision.action, initiator: plan.initiator, confirmed: true)
            case .allowed:
                return ApprovedAction(item: decision.item, action: decision.action, initiator: plan.initiator, confirmed: false)
            }
        }
    }

    /// Re-check performed by the executor immediately before acting.
    func stillPermitted(_ approved: ApprovedAction, context: PolicyContext) -> CleanupDecision? {
        let decision = evaluate(approved.item, initiator: approved.initiator, context: context)
        switch decision.verdict {
        case .allowed: return nil
        case .needsConfirmation: return approved.confirmed ? nil : decision
        case .denied: return decision
        }
    }
}
