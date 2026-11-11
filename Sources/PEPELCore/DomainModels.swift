import Foundation

public enum ProjectKind: String, Codable, Sendable, CaseIterable {
    case git, xcode, swiftpm, python, node, cargo, go, dockerCompose, cmake, registered
}

public struct GitInfo: Codable, Sendable, Hashable {
    /// Canonical path of the shared `.git` directory. Worktrees of one repository share it, so it
    /// serves as the repository identity.
    public var commonDirectory: String
    public var branch: String?
    public var headCommit: String?
    public var isLinkedWorktree: Bool
    /// `origin` URL with any embedded credentials removed.
    public var remoteURL: String?

    public init(
        commonDirectory: String, branch: String? = nil, headCommit: String? = nil, isLinkedWorktree: Bool = false,
        remoteURL: String? = nil
    ) {
        self.commonDirectory = commonDirectory
        self.branch = branch
        self.headCommit = headCommit
        self.isLinkedWorktree = isLinkedWorktree
        self.remoteURL = remoteURL
    }
}

public struct Project: Codable, Sendable, Identifiable, Hashable {
    /// Canonical root path.
    public var id: String
    public var name: String
    public var kinds: Set<ProjectKind>
    public var git: GitInfo?
    /// Projects that are worktrees of the same repository share a group.
    public var groupID: String
    public var groupName: String
    /// How sure PEPEL is that this directory is a project at all.
    public var confidence: Confidence

    public var rootPath: String { id }

    public init(
        id: String, name: String, kinds: Set<ProjectKind>, git: GitInfo? = nil, groupID: String? = nil,
        groupName: String? = nil, confidence: Confidence = .verified
    ) {
        self.id = id
        self.name = name
        self.kinds = kinds
        self.git = git
        self.groupID = groupID ?? id
        self.groupName = groupName ?? name
        self.confidence = confidence
    }
}

public enum MemoryPressureLevel: String, Codable, Sendable, Comparable {
    case normal, elevated, critical

    private var rank: Int {
        switch self {
        case .normal: 0
        case .elevated: 1
        case .critical: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

public struct SystemTelemetry: Codable, Sendable, Hashable {
    public var timestamp: Date
    public var diskTotalBytes: Int64
    /// Space the system reports as available for important usage (includes purgeable space).
    public var diskAvailableBytes: Int64
    /// Space free right now without purging anything.
    public var diskFreeBytes: Int64
    public var memoryTotalBytes: Int64
    /// Anonymous memory owned by applications (internal minus purgeable).
    public var appMemoryBytes: Int64
    public var wiredBytes: Int64
    public var compressedBytes: Int64
    public var cachedFileBytes: Int64
    public var freeBytes: Int64
    public var pressure: MemoryPressureLevel
    public var swapUsedBytes: Int64
    public var swapTotalBytes: Int64
    public var onBattery: Bool

    public init(
        timestamp: Date = Date(), diskTotalBytes: Int64 = 0, diskAvailableBytes: Int64 = 0, diskFreeBytes: Int64 = 0,
        memoryTotalBytes: Int64 = 0, appMemoryBytes: Int64 = 0, wiredBytes: Int64 = 0, compressedBytes: Int64 = 0,
        cachedFileBytes: Int64 = 0, freeBytes: Int64 = 0, pressure: MemoryPressureLevel = .normal,
        swapUsedBytes: Int64 = 0, swapTotalBytes: Int64 = 0, onBattery: Bool = false
    ) {
        self.timestamp = timestamp
        self.diskTotalBytes = diskTotalBytes
        self.diskAvailableBytes = diskAvailableBytes
        self.diskFreeBytes = diskFreeBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.appMemoryBytes = appMemoryBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedFileBytes = cachedFileBytes
        self.freeBytes = freeBytes
        self.pressure = pressure
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.onBattery = onBattery
    }

    /// What Activity Monitor calls "Memory Used".
    public var memoryUsedBytes: Int64 { appMemoryBytes + wiredBytes + compressedBytes }
    public var diskUsedBytes: Int64 { diskTotalBytes - diskAvailableBytes }
}

public enum ProtectionKind: String, Codable, Sendable, CaseIterable {
    /// Path prefix that must never be cleaned.
    case path
    /// Build generation pinned by the user.
    case pin
    /// Project excluded from cleanup entirely.
    case project
    /// Process name that is a persistent service.
    case processName
    /// Substring of a command line that marks a persistent service.
    case command
    /// Listening port that marks a persistent service.
    case port
}

public struct ProtectionRule: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var kind: ProtectionKind
    public var value: String
    public var note: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, kind: ProtectionKind, value: String, note: String = "", createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.value = value
        self.note = note
        self.createdAt = createdAt
    }
}

/// A time-limited claim on a path by an agent or build. An expired lease never makes anything
/// deletable on its own: after expiry the normal usage checks decide.
public struct ResourceLease: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var owner: String
    public var path: String
    public var purpose: String
    public var createdAt: Date
    public var expiresAt: Date
    public var releasedAt: Date?

    public init(
        id: String = UUID().uuidString, owner: String, path: String, purpose: String = "", createdAt: Date = Date(),
        expiresAt: Date, releasedAt: Date? = nil
    ) {
        self.id = id
        self.owner = owner
        self.path = path
        self.purpose = purpose
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.releasedAt = releasedAt
    }

    public func isActive(at now: Date) -> Bool { releasedAt == nil && expiresAt > now }

    public func covers(_ candidate: String) -> Bool {
        PathUtil.isInside(candidate, root: path) || PathUtil.isInside(path, root: candidate)
    }
}

public enum AuditKind: String, Codable, Sendable, CaseIterable {
    case cleanupPreview, cleanup, cleanupDenied, termination, terminationDenied, protection, lease, scan, alert, agent, container
}

public struct AuditEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: Int64
    public var timestamp: Date
    public var kind: AuditKind
    public var initiator: String
    public var subject: String
    public var outcome: String
    public var bytes: Int64
    public var detail: [String: String]

    public init(
        id: Int64 = 0, timestamp: Date = Date(), kind: AuditKind, initiator: String, subject: String, outcome: String,
        bytes: Int64 = 0, detail: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.initiator = initiator
        self.subject = subject
        self.outcome = outcome
        self.bytes = bytes
        self.detail = detail
    }
}

/// A build observed from start to finish through the opt-in `pepel run` wrapper.
public struct BuildRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var projectID: String?
    public var workingDirectory: String
    public var command: String
    public var branch: String?
    public var commit: String?
    public var startedAt: Date
    public var finishedAt: Date?
    public var exitCode: Int32?
    public var wrapperPID: Int32

    public init(
        id: String = UUID().uuidString, projectID: String?, workingDirectory: String, command: String,
        branch: String? = nil, commit: String? = nil, startedAt: Date = Date(), finishedAt: Date? = nil,
        exitCode: Int32? = nil, wrapperPID: Int32 = 0
    ) {
        self.id = id
        self.projectID = projectID
        self.workingDirectory = workingDirectory
        self.command = command
        self.branch = branch
        self.commit = commit
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.wrapperPID = wrapperPID
    }

    public var status: BuildStatus {
        guard let exitCode else { return .running }
        return exitCode == 0 ? .succeeded : .failed
    }
}

public struct ProjectAttribution: Sendable, Hashable {
    public var projectID: String
    public var groupID: String
    public var confidence: Confidence

    public init(projectID: String, groupID: String, confidence: Confidence) {
        self.projectID = projectID
        self.groupID = groupID
        self.confidence = confidence
    }
}

/// Resolves which project a path belongs to. Implemented by the project index.
public protocol ProjectAttributing: Sendable {
    func attribute(path: String) -> ProjectAttribution?
}
