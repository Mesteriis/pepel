import Foundation

/// A PID alone is not an identity: PIDs are reused. PEPEL identifies a process by PID plus its
/// kernel-reported start time and re-checks both before acting on it.
public struct ProcessIdentity: Hashable, Codable, Sendable, CustomStringConvertible {
    public var pid: Int32
    /// Microseconds since the Unix epoch.
    public var startTime: UInt64

    public init(pid: Int32, startTime: UInt64) {
        self.pid = pid
        self.startTime = startTime
    }

    public var description: String { "\(pid)@\(startTime)" }
    public var startDate: Date { Date(timeIntervalSince1970: Double(startTime) / 1_000_000) }
}

public enum ProcessState: String, Codable, Sendable {
    case running, sleeping, stopped, zombie, idle, unknown
}

public struct ProcessSnapshot: Codable, Sendable, Identifiable, Hashable {
    public var identity: ProcessIdentity
    public var parentPID: Int32
    public var processGroup: Int32
    public var uid: UInt32
    public var name: String
    public var executablePath: String?
    /// Command line only. The environment block is never read.
    public var arguments: [String]
    public var workingDirectory: String?
    public var residentBytes: Int64
    /// Physical footprint as reported by the kernel ledger; closer to what Activity Monitor shows.
    public var footprintBytes: Int64
    /// Cumulative user + system CPU time in nanoseconds.
    public var cpuTimeNs: UInt64
    /// Cumulative bytes the process has written to disk, from the kernel's I/O accounting.
    public var diskBytesWritten: UInt64 = 0
    public var state: ProcessState
    public var hasControllingTerminal: Bool
    public var listeningPorts: [UInt16]

    public var id: ProcessIdentity { identity }
    public var pid: Int32 { identity.pid }

    public init(
        identity: ProcessIdentity, parentPID: Int32, processGroup: Int32 = 0, uid: UInt32 = 0, name: String,
        executablePath: String? = nil, arguments: [String] = [], workingDirectory: String? = nil,
        residentBytes: Int64 = 0, footprintBytes: Int64 = 0, cpuTimeNs: UInt64 = 0,
        state: ProcessState = .sleeping, hasControllingTerminal: Bool = false, listeningPorts: [UInt16] = []
    ) {
        self.identity = identity
        self.parentPID = parentPID
        self.processGroup = processGroup
        self.uid = uid
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.residentBytes = residentBytes
        self.footprintBytes = footprintBytes
        self.cpuTimeNs = cpuTimeNs
        self.state = state
        self.hasControllingTerminal = hasControllingTerminal
        self.listeningPorts = listeningPorts
    }

    /// Like `displayCommand`, with the executable reduced to its name so the arguments stay visible.
    public var shortCommand: String {
        var parts = ArgumentRedactor.redact(arguments)
        guard let first = parts.first else { return name }
        parts[0] = (first as NSString).lastPathComponent
        return parts.joined(separator: " ")
    }

    /// Command line with secret-looking values masked. Use this for anything shown or stored.
    public var displayCommand: String {
        let line = ArgumentRedactor.redact(arguments).joined(separator: " ")
        return line.isEmpty ? name : line
    }
}

/// Masks values that look like credentials before a command line is shown, logged or persisted.
public enum ArgumentRedactor {
    private static let sensitive = [
        "token", "secret", "password", "passwd", "apikey", "api-key", "api_key", "auth", "credential", "private-key",
        "private_key", "bearer", "session",
    ]

    private static func isSensitive(_ key: String) -> Bool {
        let k = key.lowercased()
        return sensitive.contains { k.contains($0) }
    }

    public static func redact(_ arguments: [String]) -> [String] {
        var out: [String] = []
        var maskNext = false
        for arg in arguments {
            if maskNext {
                out.append("•••")
                maskNext = false
                continue
            }
            if let eq = arg.firstIndex(of: "="), isSensitive(String(arg[..<eq])) {
                out.append(arg[...eq] + "•••")
            } else if arg.hasPrefix("-"), isSensitive(arg) {
                out.append(arg)
                maskNext = true
            } else if arg.contains("://"), let at = arg.firstIndex(of: "@"),
                let scheme = arg.range(of: "://"), scheme.upperBound < at
            {
                out.append(arg[..<scheme.upperBound] + "•••" + arg[at...])
            } else {
                out.append(arg)
            }
        }
        return out
    }
}

public enum ProcessRole: String, Codable, Sendable, CaseIterable {
    case agent, buildTool, testRunner, devServer, container, projectBinary, ide, userApp, system, other

    /// Roles the guardian reasons about at all.
    public var isDeveloperWorkload: Bool {
        switch self {
        case .agent, .buildTool, .testRunner, .devServer, .container, .projectBinary: true
        case .ide, .userApp, .system, .other: false
        }
    }
}

public enum LifecycleClass: String, Codable, Sendable, CaseIterable {
    case agentSession
    case activeBuildOrTest
    case activeDevService
    /// Background service that appears to have been left running on purpose, or is protected by a rule.
    case backgroundService
    /// A finished task left this subprocess behind.
    case abandonedSubprocess
    case suspiciousOrphan
    case unknown

    public var isAbandonedCandidate: Bool { self == .abandonedSubprocess || self == .suspiciousOrphan }
}

public enum TerminationEligibility: Codable, Sendable, Hashable {
    /// PEPEL will not terminate this process, even on request.
    case never(reason: String)
    /// Only after explicit user approval; `warning` says what may be interrupted.
    case approvalRequired(warning: String)
    /// Verified disposable. May be terminated automatically if the user opted in.
    case automaticEligible

    public var isNever: Bool {
        if case .never = self { return true }
        return false
    }
}

public struct ProcessAssessment: Codable, Sendable, Identifiable, Hashable {
    public var process: ProcessSnapshot
    public var role: ProcessRole
    public var lifecycle: LifecycleClass
    /// Confidence in `lifecycle`.
    public var confidence: Confidence
    public var projectID: String?
    public var projectConfidence: Confidence
    /// Human-readable reasons, in the order they were established.
    public var evidence: [String]
    public var eligibility: TerminationEligibility
    /// Share of one core used since the previous observation, when one exists.
    public var cpuPercent: Double?
    public var agentAncestor: ProcessIdentity?
    public var descendantCount: Int
    public var subtreeFootprintBytes: Int64
    /// Set when this process was left behind by an application that has quit: the application's name.
    public var leftoverOf: String?
    /// Set when the process lives almost entirely in swap and has not used CPU.
    public var dormant = false
    /// Set for a language server or indexer whose editor or agent has exited.
    public var orphanedTool = false

    public var id: ProcessIdentity { process.identity }

    public init(
        process: ProcessSnapshot, role: ProcessRole, lifecycle: LifecycleClass, confidence: Confidence,
        projectID: String? = nil, projectConfidence: Confidence = .unknown, evidence: [String] = [],
        eligibility: TerminationEligibility, cpuPercent: Double? = nil, agentAncestor: ProcessIdentity? = nil,
        descendantCount: Int = 0, subtreeFootprintBytes: Int64 = 0
    ) {
        self.process = process
        self.role = role
        self.lifecycle = lifecycle
        self.confidence = confidence
        self.projectID = projectID
        self.projectConfidence = projectConfidence
        self.evidence = evidence
        self.eligibility = eligibility
        self.cpuPercent = cpuPercent
        self.agentAncestor = agentAncestor
        self.descendantCount = descendantCount
        self.subtreeFootprintBytes = subtreeFootprintBytes
    }
}

/// One point of the observation history kept per process identity.
public struct ProcessObservation: Codable, Sendable, Hashable {
    public var timestamp: Date
    public var cpuTimeNs: UInt64
    public var footprintBytes: Int64
    public var diskBytesWritten: UInt64

    public init(timestamp: Date, cpuTimeNs: UInt64, footprintBytes: Int64, diskBytesWritten: UInt64 = 0) {
        self.timestamp = timestamp
        self.cpuTimeNs = cpuTimeNs
        self.footprintBytes = footprintBytes
        self.diskBytesWritten = diskBytesWritten
    }
}

public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claudeCode, codex, openCode, hermes

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .openCode: "OpenCode"
        case .hermes: "Hermes"
        }
    }
}

public enum AgentActivityState: String, Codable, Sendable {
    /// Wrote to disk, burned CPU, spawned a process or ran a build within the last few minutes.
    case working
    /// Quiet, but not yet for the whole sleep window (or not observed that long).
    case idle
    /// Quiet for the whole sleep window: no disk writes, no CPU bursts, no new processes, no build.
    case sleeping
}

/// An agent session observed through its root process. Nothing here comes from agent-internal files.
public struct AgentSession: Codable, Sendable, Identifiable, Hashable {
    public var kind: AgentKind
    public var root: ProcessIdentity
    public var workingDirectory: String?
    public var projectID: String?
    public var projectConfidence: Confidence
    public var processCount: Int
    public var footprintBytes: Int64
    public var activeBuildCount: Int
    /// True when the session's process tree used CPU since the previous observation.
    public var recentlyActive: Bool?
    public var startedAt: Date
    public var state: AgentActivityState = .idle
    /// True when the agent binary runs as a long-lived server for an application (`codex
    /// app-server`, `claude mcp serve`) rather than as a session someone talks to. Servers are
    /// quiet by nature and are never treated as asleep.
    public var isService = false
    /// When the session last showed activity, as far back as PEPEL's observations reach.
    public var quietSince: Date?
    /// How long PEPEL has been watching this session.
    public var observedFor: TimeInterval = 0
    /// What the state was concluded from.
    public var evidence: [String] = []
    /// Set while PEPEL has the session suspended.
    public var frozenSince: Date?

    public var id: ProcessIdentity { root }

    public init(
        kind: AgentKind, root: ProcessIdentity, workingDirectory: String?, projectID: String?,
        projectConfidence: Confidence, processCount: Int, footprintBytes: Int64, activeBuildCount: Int,
        recentlyActive: Bool?, startedAt: Date
    ) {
        self.kind = kind
        self.root = root
        self.workingDirectory = workingDirectory
        self.projectID = projectID
        self.projectConfidence = projectConfidence
        self.processCount = processCount
        self.footprintBytes = footprintBytes
        self.activeBuildCount = activeBuildCount
        self.recentlyActive = recentlyActive
        self.startedAt = startedAt
    }
}

/// The same helper program started once per agent session (a tool server, typically).
public struct AgentHelperGroup: Codable, Sendable, Hashable, Identifiable {
    /// The command with paths shortened and options dropped; identical for every copy.
    public var id: String
    public var copies: Int
    /// How many different sessions run a copy.
    public var sessions: Int
    public var footprintBytes: Int64

    public init(id: String, copies: Int, sessions: Int, footprintBytes: Int64) {
        self.id = id
        self.copies = copies
        self.sessions = sessions
        self.footprintBytes = footprintBytes
    }

    /// What all copies but one hold: an upper bound on what one shared instance would save.
    public var duplicatedBytes: Int64 { copies > 1 ? footprintBytes - footprintBytes / Int64(copies) : 0 }
}
