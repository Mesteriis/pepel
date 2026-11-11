import Foundation

public enum MemoryOwnerKind: String, Codable, Sendable, CaseIterable {
    case virtualMachine, agentSession, application, project, developerTool, system, other

    public var displayName: String {
        switch self {
        case .virtualMachine: "Virtual machines and containers"
        case .agentSession: "Agent session"
        case .application: "Application"
        case .project: "Project processes"
        case .developerTool: "Developer tool"
        case .system: "System services"
        case .other: "Other"
        }
    }
}

public struct MemoryOwnerProcess: Codable, Sendable, Hashable, Identifiable {
    public var identity: ProcessIdentity
    public var name: String
    public var footprintBytes: Int64
    public var residentBytes: Int64

    public var id: ProcessIdentity { identity }

    public init(identity: ProcessIdentity, name: String, footprintBytes: Int64, residentBytes: Int64) {
        self.identity = identity
        self.name = name
        self.footprintBytes = footprintBytes
        self.residentBytes = residentBytes
    }
}

/// Everything one owner — an app with its helpers, an agent session with its tools, a virtual
/// machine — holds in memory. This answers "where did the memory go" at the level a person can
/// act on, instead of a flat list of process names.
public struct MemoryOwner: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: MemoryOwnerKind
    public var name: String
    public var detail: String
    /// How sure PEPEL is about the grouping (for example, which app a virtual machine belongs to).
    public var confidence: Confidence
    public var projectID: String?
    public var processCount: Int
    /// What the kernel charges to these processes, including compressed and swapped pages.
    public var footprintBytes: Int64
    /// What is physically in RAM right now.
    public var residentBytes: Int64
    public var largest: [MemoryOwnerProcess]

    public init(
        id: String, kind: MemoryOwnerKind, name: String, detail: String = "", confidence: Confidence = .verified,
        projectID: String? = nil, processCount: Int = 0, footprintBytes: Int64 = 0, residentBytes: Int64 = 0,
        largest: [MemoryOwnerProcess] = []
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.detail = detail
        self.confidence = confidence
        self.projectID = projectID
        self.processCount = processCount
        self.footprintBytes = footprintBytes
        self.residentBytes = residentBytes
        self.largest = largest
    }

    /// Memory charged to the owner that is not in RAM: compressed by macOS or written to swap.
    /// An estimate, summed per process as footprint minus resident size; shared pages blur it.
    public var notInRAMBytes: Int64 = 0
}

/// Processes still running after the application that started them has quit.
public struct AppLeftovers: Codable, Sendable, Hashable, Identifiable {
    /// The application's bundle path.
    public var id: String
    public var appName: String
    public var quitAt: Date
    public var processes: [ProcessAssessment]

    public init(id: String, appName: String, quitAt: Date, processes: [ProcessAssessment]) {
        self.id = id
        self.appName = appName
        self.quitAt = quitAt
        self.processes = processes
    }

    public var footprintBytes: Int64 { processes.reduce(0) { $0 + $1.subtreeFootprintBytes } }
}

public struct ContainerMemory: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var composeProject: String?
    /// Directory the compose project was started from, as recorded by Docker in the container's labels.
    public var workingDirectory: String?
    public var memoryBytes: Int64
    public var cpuPercent: Double
    /// Why PEPEL leaves this container running, when it does: the `pepel.keep` label or the keep list.
    public var keepReason: String?

    public var id: String { name }
    public var isKept: Bool { keepReason != nil }

    public init(name: String, composeProject: String? = nil, workingDirectory: String? = nil, memoryBytes: Int64, cpuPercent: Double) {
        self.name = name
        self.composeProject = composeProject
        self.workingDirectory = workingDirectory
        self.memoryBytes = memoryBytes
        self.cpuPercent = cpuPercent
    }
}

/// Containers of one compose project (or the stand-alone ones together).
public struct ContainerGroup: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var projectID: String?
    public var projectConfidence: Confidence
    public var containers: [ContainerMemory]
    /// Agent sessions running in the project these containers belong to, right now.
    public var agentSessions = 0
    /// Since when the project has had no agent session, as far as PEPEL has observed.
    public var idleSince: Date?

    public init(id: String, name: String, projectID: String? = nil, projectConfidence: Confidence = .unknown, containers: [ContainerMemory]) {
        self.id = id
        self.name = name
        self.projectID = projectID
        self.projectConfidence = projectConfidence
        self.containers = containers
    }

    public var memoryBytes: Int64 { containers.reduce(0) { $0 + $1.memoryBytes } }
    public var cpuPercent: Double { containers.reduce(0) { $0 + $1.cpuPercent } }
    /// Containers PEPEL may stop: everything not on the keep list.
    public var stoppable: [ContainerMemory] { containers.filter { !$0.isKept } }
}

/// What the container runtime reports about memory inside its virtual machine, next to what
/// the machine is charged for it on the host.
public struct ContainerReport: Codable, Sendable, Hashable {
    public var product: String
    /// Memory the virtual machine is allowed to use (its configured limit).
    public var vmLimitBytes: Int64
    public var cpus: Int
    public var running: Int
    public var total: Int
    public var groups: [ContainerGroup]
    /// What the host is charged for the virtual machine, from the process table.
    public var hostFootprintBytes: Int64
    public var hostResidentBytes: Int64
    public var measuredAt: Date
    /// What the VM costs the host on top of its containers even right after a restart (its
    /// kernel and the container engine), as measured the last time it was restarted.
    public var baselineOverheadBytes: Int64 = 0
    /// The most the containers used together on any of the last 14 days PEPEL was watching.
    public var peakUsedBytes: Int64 = 0

    public init(
        product: String, vmLimitBytes: Int64, cpus: Int, running: Int, total: Int, groups: [ContainerGroup],
        hostFootprintBytes: Int64 = 0, hostResidentBytes: Int64 = 0, measuredAt: Date = Date()
    ) {
        self.product = product
        self.vmLimitBytes = vmLimitBytes
        self.cpus = cpus
        self.running = running
        self.total = total
        self.groups = groups
        self.hostFootprintBytes = hostFootprintBytes
        self.hostResidentBytes = hostResidentBytes
        self.measuredAt = measuredAt
    }

    /// Running containers marked to be left alone.
    public var kept: [ContainerMemory] { groups.flatMap(\.containers).filter(\.isKept) }

    /// What a VM restart would give back: what the host is charged, minus what the containers
    /// use, minus what a freshly restarted VM costs anyway.
    public var excessBytes: Int64 { max(0, hostFootprintBytes - usedByContainersBytes - baselineOverheadBytes) }

    /// What the containers themselves use right now, by the runtime's own accounting.
    public var usedByContainersBytes: Int64 { groups.reduce(0) { $0 + $1.memoryBytes } }

    /// The lowest limit PEPEL accepts: a quarter above the most the containers have been seen
    /// to use, plus 1 GiB for the VM's own kernel and engine.
    public var minimumLimitBytes: Int64 { max(2 << 30, max(usedByContainersBytes, peakUsedBytes) * 5 / 4 + (1 << 30)) }

    /// A limit with headroom over the most the containers have used: 1.5× plus 2 GiB, rounded up
    /// to 2 GiB steps, never below 4 GiB. Nil when that would not be meaningfully lower than the
    /// current limit.
    public var suggestedLimitBytes: Int64? {
        let gib: Int64 = 1 << 30
        let wanted = max(4 * gib, max(usedByContainersBytes, peakUsedBytes) * 3 / 2 + 2 * gib)
        let rounded = (wanted + 2 * gib - 1) / (2 * gib) * (2 * gib)
        return vmLimitBytes > 0 && rounded * 4 <= vmLimitBytes * 3 ? rounded : nil
    }

    public var explanation: String {
        var text = "\(running) running container\(running == 1 ? "" : "s") use \(Bytes.format(usedByContainersBytes)) of a virtual machine limited to \(Bytes.format(vmLimitBytes))."
        if excessBytes > (2 << 30) {
            text += " This Mac is charged \(Bytes.format(hostFootprintBytes)) for that machine: Linux keeps memory it once used as cache, and the virtual machine hands it back slowly or not at all. Restarting it would return about \(Bytes.format(excessBytes))."
        } else if hostFootprintBytes > 0 {
            text += " This Mac is charged \(Bytes.format(hostFootprintBytes)) for that machine, which is about what it costs right after a restart."
        }
        if let suggestedLimitBytes {
            text += " A limit around \(Bytes.format(suggestedLimitBytes)) would still leave 1.5× headroom over the most the containers have used\(peakUsedBytes > usedByContainersBytes ? " (\(Bytes.format(peakUsedBytes)))" : "")."
        }
        return text
    }
}

// MARK: - Free memory

public enum ReclaimStepKind: String, Codable, Sendable, CaseIterable {
    case abandonedProcesses, appLeftovers, sleepingAgents, freezeAgents, idleAgents, grownApps, unusedApps, dormantProcesses, simulators, idleContainers, containerVM, fileCache
}

/// One thing "Free memory" can do, with what it would act on and what it could give back.
public struct ReclaimStep: Codable, Sendable, Identifiable, Hashable {
    public var kind: ReclaimStepKind
    public var title: String
    public var detail: String
    /// Names of what would be terminated, stopped or restarted.
    public var targets: [String]
    /// Upper bound. A process's footprint is not a promise of that much becoming available.
    public var estimatedBytes: Int64
    /// Steps that only touch what PEPEL already considers unused are on by default; steps that
    /// can interrupt something a person might still want are offered but off.
    public var selectedByDefault: Bool

    public var id: String { kind.rawValue }

    public init(kind: ReclaimStepKind, title: String, detail: String, targets: [String], estimatedBytes: Int64, selectedByDefault: Bool) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.targets = targets
        self.estimatedBytes = estimatedBytes
        self.selectedByDefault = selectedByDefault
    }
}

public struct ReclaimPlan: Codable, Sendable {
    public var steps: [ReclaimStep]
    public var telemetry: SystemTelemetry

    public init(steps: [ReclaimStep], telemetry: SystemTelemetry) {
        self.steps = steps
        self.telemetry = telemetry
    }

    public var defaultSelection: Set<String> { Set(steps.filter(\.selectedByDefault).map(\.id)) }

    public func estimatedBytes(_ selection: Set<String>) -> Int64 {
        steps.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.estimatedBytes }
    }
}

public struct ReclaimStepResult: Codable, Sendable, Identifiable, Hashable {
    public var kind: ReclaimStepKind
    public var title: String
    public var done: Int
    public var attempted: Int
    public var notes: [String]

    public var id: String { kind.rawValue }

    public init(kind: ReclaimStepKind, title: String, done: Int, attempted: Int, notes: [String] = []) {
        self.kind = kind
        self.title = title
        self.done = done
        self.attempted = attempted
        self.notes = notes
    }
}

/// What "Free memory" did, with measurements taken before and after.
public struct ReclaimReport: Codable, Sendable {
    public var startedAt: Date
    public var finishedAt: Date
    public var before: SystemTelemetry
    public var after: SystemTelemetry
    public var results: [ReclaimStepResult]

    public init(startedAt: Date, finishedAt: Date, before: SystemTelemetry, after: SystemTelemetry, results: [ReclaimStepResult]) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.before = before
        self.after = after
        self.results = results
    }

    /// Measured change in memory used (application + wired + compressed). Other activity on the
    /// machine moves this number too.
    public var freedBytes: Int64 { before.memoryUsedBytes - after.memoryUsedBytes }
    public var swapFreedBytes: Int64 { before.swapUsedBytes - after.swapUsedBytes }
}

// MARK: - Freezing

/// A process tree PEPEL has suspended (SIGSTOP) instead of ending it. Nothing is lost: the
/// processes keep their state and continue (SIGCONT) when woken.
public struct FrozenTree: Codable, Sendable, Identifiable, Hashable {
    public var root: ProcessIdentity
    public var members: [ProcessIdentity]
    public var name: String
    public var frozenAt: Date
    /// "automatic", "user" or "cli". Trees frozen by hand are not thawed when the rule is switched off.
    public var initiator: String
    /// The application whose window the tree lives in; coming back to it wakes the tree.
    public var ownerAppPID: Int32?
    public var ownerAppName: String?
    /// Next time the tree is woken briefly to see whether work is waiting for it.
    public var nextPeek: Date
    public var peekStarted: Date?
    /// CPU time of the whole tree when the current peek began.
    public var peekCPUNs: UInt64 = 0
    public var footprintBytes: Int64
    public var residentBytesAtFreeze: Int64

    public var id: ProcessIdentity { root }
    public var isPeeking: Bool { peekStarted != nil }

    public init(
        root: ProcessIdentity, members: [ProcessIdentity], name: String, frozenAt: Date, initiator: String, ownerAppPID: Int32?,
        ownerAppName: String?, nextPeek: Date, footprintBytes: Int64, residentBytesAtFreeze: Int64
    ) {
        self.root = root
        self.members = members
        self.name = name
        self.frozenAt = frozenAt
        self.initiator = initiator
        self.ownerAppPID = ownerAppPID
        self.ownerAppName = ownerAppName
        self.nextPeek = nextPeek
        self.footprintBytes = footprintBytes
        self.residentBytesAtFreeze = residentBytesAtFreeze
    }
}

// MARK: - Growth over time

/// An owner whose memory has kept growing while PEPEL watched: the usual sign of a leak, or of
/// an application that has not been restarted for a long time.
public struct MemoryGrowth: Codable, Sendable, Identifiable, Hashable {
    /// The memory owner's id (`app:<bundle path>`, `agent:…`, `exe:<name>`).
    public var id: String
    public var kind: MemoryOwnerKind
    public var name: String
    /// Typical level at the start of the observed stretch.
    public var baselineBytes: Int64
    public var currentBytes: Int64
    public var since: Date
    public var perHourBytes: Int64

    public var grownBytes: Int64 { currentBytes - baselineBytes }

    public init(id: String, kind: MemoryOwnerKind, name: String, baselineBytes: Int64, currentBytes: Int64, since: Date, perHourBytes: Int64) {
        self.id = id
        self.kind = kind
        self.name = name
        self.baselineBytes = baselineBytes
        self.currentBytes = currentBytes
        self.since = since
        self.perHourBytes = perHourBytes
    }
}

public struct MemorySample: Codable, Sendable, Hashable {
    public var at: Date
    public var bytes: Int64
    public init(at: Date, bytes: Int64) {
        self.at = at
        self.bytes = bytes
    }
}

public enum MemoryGrowthAnalyzer {
    static func median(_ values: [Int64]) -> Int64 {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    /// Samples since the owner last started over: a fall of 40% or more between two readings is
    /// a restart, and what came before it says nothing about the current run.
    static func currentRun(_ samples: [MemorySample]) -> [MemorySample] {
        var start = 0
        for index in samples.indices.dropFirst() where samples[index].bytes * 10 <= samples[index - 1].bytes * 6 { start = index }
        return Array(samples[start...])
    }

    /// Sustained growth only: at least two hours of readings, a typical level that rose by 1 GiB
    /// and by half, and no dip in between. A single spike, or a level that is merely high, is not growth.
    public static func growth(
        id: String, kind: MemoryOwnerKind, name: String, samples: [MemorySample], minimumSpan: TimeInterval = 2 * 3600,
        minimumGrowthBytes: Int64 = 1 << 30
    ) -> MemoryGrowth? {
        let run = currentRun(samples.sorted { $0.at < $1.at })
        guard run.count >= 6, let first = run.first, let last = run.last else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= minimumSpan else { return nil }
        let third = run.count / 3
        let baseline = median(run[..<third].map(\.bytes))
        let middle = median(run[third..<(run.count - third)].map(\.bytes))
        let current = median(run[(run.count - third)...].map(\.bytes))
        guard current - baseline >= minimumGrowthBytes, current * 2 >= baseline * 3, middle >= baseline, current >= middle else { return nil }
        return MemoryGrowth(
            id: id, kind: kind, name: name, baselineBytes: baseline, currentBytes: current, since: first.at,
            perHourBytes: Int64(Double(current - baseline) / (span / 3600)))
    }
}

// MARK: - Unused applications

/// What macOS says about a running application.
public struct RunningApplicationInfo: Codable, Sendable, Hashable {
    public var pid: Int32
    public var bundlePath: String
    public var name: String
    /// An ordinary application with a Dock icon, as opposed to a menu bar item or a helper.
    public var isRegular: Bool

    public init(pid: Int32, bundlePath: String, name: String, isRegular: Bool) {
        self.pid = pid
        self.bundlePath = bundlePath
        self.name = name
        self.isRegular = isRegular
    }
}

/// An application that is open but has not been brought to the front for a long time and is
/// not doing anything in the background either.
public struct UnusedApplication: Codable, Sendable, Identifiable, Hashable {
    public var bundlePath: String
    public var name: String
    public var pid: Int32
    public var footprintBytes: Int64
    public var residentBytes: Int64
    /// When it was last in front, as far as PEPEL has seen.
    public var lastActive: Date
    /// Average share of one core over the last hour; nil when PEPEL has no readings yet.
    public var cpuPercent: Double?

    public var id: String { bundlePath }

    public init(bundlePath: String, name: String, pid: Int32, footprintBytes: Int64, residentBytes: Int64, lastActive: Date, cpuPercent: Double?) {
        self.bundlePath = bundlePath
        self.name = name
        self.pid = pid
        self.footprintBytes = footprintBytes
        self.residentBytes = residentBytes
        self.lastActive = lastActive
        self.cpuPercent = cpuPercent
    }
}

// MARK: - Simulators

/// An iOS (or watchOS, tvOS, visionOS) simulator that is booted, with what it holds in memory.
public struct BootedSimulator: Codable, Sendable, Identifiable, Hashable {
    public var udid: String
    public var name: String
    public var root: ProcessIdentity
    public var processCount: Int
    public var footprintBytes: Int64
    public var bootedAt: Date
    /// Why PEPEL thinks it is being used right now; nil when nothing suggests it is.
    public var inUse: String?

    public var id: String { udid }

    public init(udid: String, name: String, root: ProcessIdentity, processCount: Int, footprintBytes: Int64, bootedAt: Date, inUse: String?) {
        self.udid = udid
        self.name = name
        self.root = root
        self.processCount = processCount
        self.footprintBytes = footprintBytes
        self.bootedAt = bootedAt
        self.inUse = inUse
    }
}

// MARK: - Memory budgets

/// A limit the user sets for what one owner may hold. PEPEL only reports when it is exceeded.
public struct MemoryBudget: Codable, Sendable, Hashable, Identifiable {
    /// An owner's name ("Dia", "orders-api"), compared without regard to case, or
    /// `kind:<kind>` (`kind:agentSession`, `kind:application`, …) for every owner of that kind.
    public var match: String
    public var bytes: Int64

    public var id: String { match.lowercased() }

    public init(match: String, bytes: Int64) {
        self.match = match
        self.bytes = bytes
    }

    public func applies(to owner: MemoryOwner) -> Bool {
        if match.lowercased().hasPrefix("kind:") { return owner.kind.rawValue.lowercased() == match.dropFirst(5).lowercased() }
        return owner.name.lowercased() == match.lowercased()
    }
}

public struct OverBudget: Codable, Sendable, Hashable, Identifiable {
    public var ownerID: String
    public var name: String
    public var kind: MemoryOwnerKind
    public var footprintBytes: Int64
    public var budgetBytes: Int64

    public var id: String { ownerID }
    public var excessBytes: Int64 { footprintBytes - budgetBytes }

    /// A budget by name wins over a budget for the whole kind.
    public static func find(owners: [MemoryOwner], budgets: [MemoryBudget]) -> [OverBudget] {
        owners.compactMap { owner -> OverBudget? in
            let named = budgets.first { !$0.match.lowercased().hasPrefix("kind:") && $0.applies(to: owner) }
            guard let budget = named ?? budgets.first(where: { $0.applies(to: owner) }), budget.bytes > 0, owner.footprintBytes > budget.bytes else { return nil }
            return OverBudget(ownerID: owner.id, name: owner.name, kind: owner.kind, footprintBytes: owner.footprintBytes, budgetBytes: budget.bytes)
        }
        .sorted { $0.excessBytes > $1.excessBytes }
    }
}
