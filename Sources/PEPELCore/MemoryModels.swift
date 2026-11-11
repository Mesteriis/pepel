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

    public var id: String { name }

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

    public init(id: String, name: String, projectID: String? = nil, projectConfidence: Confidence = .unknown, containers: [ContainerMemory]) {
        self.id = id
        self.name = name
        self.projectID = projectID
        self.projectConfidence = projectConfidence
        self.containers = containers
    }

    public var memoryBytes: Int64 { containers.reduce(0) { $0 + $1.memoryBytes } }
    public var cpuPercent: Double { containers.reduce(0) { $0 + $1.cpuPercent } }
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

    /// What the containers themselves use right now, by the runtime's own accounting.
    public var usedByContainersBytes: Int64 { groups.reduce(0) { $0 + $1.memoryBytes } }

    /// A limit with headroom over current use: 1.5× plus 2 GiB, rounded up to 2 GiB steps,
    /// never below 4 GiB. Nil when that would not be meaningfully lower than the current limit.
    public var suggestedLimitBytes: Int64? {
        let gib: Int64 = 1 << 30
        let wanted = max(4 * gib, usedByContainersBytes * 3 / 2 + 2 * gib)
        let rounded = (wanted + 2 * gib - 1) / (2 * gib) * (2 * gib)
        return vmLimitBytes > 0 && rounded * 4 <= vmLimitBytes * 3 ? rounded : nil
    }

    public var explanation: String {
        var text = "\(running) running container\(running == 1 ? "" : "s") use \(Bytes.format(usedByContainersBytes)) of a virtual machine limited to \(Bytes.format(vmLimitBytes))."
        if hostFootprintBytes > usedByContainersBytes + (2 << 30) {
            text += " This Mac is charged \(Bytes.format(hostFootprintBytes)) for that machine: Linux keeps memory it once used as cache, and the virtual machine hands it back slowly or not at all."
        }
        if let suggestedLimitBytes {
            text += " A limit around \(Bytes.format(suggestedLimitBytes)) would still leave 1.5× headroom over what is used now."
        }
        return text
    }
}
