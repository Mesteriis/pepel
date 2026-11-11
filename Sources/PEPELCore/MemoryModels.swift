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
