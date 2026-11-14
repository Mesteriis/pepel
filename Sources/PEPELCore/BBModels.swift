import Foundation

/// BB, the agent IDE: its threads and what its processes hold.
public struct BBThread: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var projectID: String?
    public var projectName: String?
    public var environmentID: String?
    public var providerID: String?
    /// BB's own status: idle, running, error, waiting…
    public var status: String
    /// Last change in the thread, or the person's last look at it, whichever is later.
    public var lastActivity: Date
    /// Something is queued or still running in the background (agents, commands, plans, workflows).
    public var busy: Bool
    /// When PEPEL last asked BB to release this thread's runtime, if it has since been quiet.
    public var releasedAt: Date?
    /// A live agent runtime works in this thread's environment, so it may be this thread's.
    public var environmentHasRuntime = false

    public init(
        id: String, title: String, projectID: String?, projectName: String?, environmentID: String? = nil, providerID: String?, status: String, lastActivity: Date, busy: Bool,
        releasedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.projectID = projectID
        self.projectName = projectName
        self.environmentID = environmentID
        self.providerID = providerID
        self.status = status
        self.lastActivity = lastActivity
        self.busy = busy
        self.releasedAt = releasedAt
    }

    /// Threads quiet for longer have no runtime left: BB releases one itself after 30 idle minutes.
    public static let runtimeWindow: TimeInterval = 24 * 3600

    /// Idle with nothing pending, quiet for `minutes` (and less than a day, past which BB has
    /// released it already), and not released since its last activity.
    public func isReleasable(minutes: Int, now: Date = Date()) -> Bool {
        let quiet = now.timeIntervalSince(lastActivity)
        guard status == "idle", !busy, quiet >= Double(minutes) * 60, quiet < Self.runtimeWindow else { return false }
        if let releasedAt, releasedAt >= lastActivity { return false }
        return true
    }
}

/// One agent runtime BB keeps alive: a provider worker with its agent and the agent's MCP servers.
public struct BBRuntime: Codable, Sendable, Hashable, Identifiable {
    public var workerPID: Int32
    /// "codex", "pi"…
    public var provider: String
    /// Where its agent works: the environment's folder.
    public var path: String?
    public var bytes: Int64
    public var processCount: Int
    /// Threads whose environment is that folder; one of them owns this runtime.
    public var threadIDs: [String]
    /// BB's own maintenance work, not a thread of yours.
    public var isMaintenance: Bool

    public var id: Int32 { workerPID }

    public init(workerPID: Int32, provider: String, path: String?, bytes: Int64, processCount: Int, threadIDs: [String] = [], isMaintenance: Bool = false) {
        self.workerPID = workerPID
        self.provider = provider
        self.path = path
        self.bytes = bytes
        self.processCount = processCount
        self.threadIDs = threadIDs
        self.isMaintenance = isMaintenance
    }
}

public struct BBState: Codable, Sendable, Hashable {
    public struct Plugin: Codable, Sendable, Hashable {
        public var name: String
        public var bytes: Int64
        public var processCount: Int
        public init(name: String, bytes: Int64, processCount: Int) {
            self.name = name
            self.bytes = bytes
            self.processCount = processCount
        }
    }

    /// The BB app is running.
    public var running: Bool
    /// The `bb` command line answered; without it threads are unknown.
    public var cliAvailable: Bool
    public var threads: [BBThread]
    /// Agent runtimes BB keeps for its threads (provider workers with the agent and its MCP servers).
    public var runtimeCount: Int
    public var runtimeBytes: Int64
    public var runtimeProcesses: Int
    /// The app, its server and daemon.
    public var appBytes: Int64
    public var plugins: [Plugin]
    public var runtimes: [BBRuntime] = []
    public var at: Date

    public init(running: Bool, cliAvailable: Bool, threads: [BBThread], runtimeCount: Int, runtimeBytes: Int64, runtimeProcesses: Int, appBytes: Int64, plugins: [Plugin], at: Date = Date()) {
        self.running = running
        self.cliAvailable = cliAvailable
        self.threads = threads
        self.runtimeCount = runtimeCount
        self.runtimeBytes = runtimeBytes
        self.runtimeProcesses = runtimeProcesses
        self.appBytes = appBytes
        self.plugins = plugins
        self.at = at
    }

    public var totalBytes: Int64 { appBytes + runtimeBytes + plugins.reduce(0) { $0 + $1.bytes } }
}
