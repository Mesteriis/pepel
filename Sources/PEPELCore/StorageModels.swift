import Foundation

public enum ArtifactCategory: String, Codable, Sendable, CaseIterable {
    case buildOutput, dependencyCache, toolCache, testArtifact, virtualEnvironment, dependencies
    case simulator, archive, container, containerVolume, agentState, modelWeights, temporary

    public var displayName: String {
        switch self {
        case .buildOutput: "Build output"
        case .dependencyCache: "Dependency cache"
        case .toolCache: "Tool cache"
        case .testArtifact: "Test artifact"
        case .virtualEnvironment: "Virtual environment"
        case .dependencies: "Installed dependencies"
        case .simulator: "Simulator data"
        case .archive: "Archive"
        case .container: "Container data"
        case .containerVolume: "Container volume"
        case .agentState: "Agent state"
        case .modelWeights: "Model weights"
        case .temporary: "Temporary files"
        }
    }
}

public enum BuildSystem: String, Codable, Sendable, CaseIterable {
    case xcode, swiftpm, cargo, go, python, node, cmake, ninja, make, other

    public var displayName: String {
        switch self {
        case .xcode: "Xcode"
        case .swiftpm: "SwiftPM"
        case .cargo: "Cargo"
        case .go: "Go"
        case .python: "Python"
        case .node: "Node.js"
        case .cmake: "CMake"
        case .ninja: "Ninja"
        case .make: "Make"
        case .other: "Other"
        }
    }
}

public enum BuildStatus: String, Codable, Sendable {
    case succeeded, failed, running
    /// PEPEL did not observe the build finishing, so it does not claim an outcome.
    case unknown
}

/// Cleanup through a tool's own supported interface instead of filesystem deletion.
public enum ToolCleanup: String, Codable, Sendable, CaseIterable {
    case dockerBuildCache, dockerStoppedContainers, dockerDanglingImages
    case goBuildCache, goModuleCache, simulatorUnavailable, uvCacheClean, pnpmStorePrune

    public var commandDescription: String {
        switch self {
        case .dockerBuildCache: "docker builder prune --force"
        case .dockerStoppedContainers: "docker container prune --force"
        case .dockerDanglingImages: "docker image prune --force"
        case .goBuildCache: "go clean -cache"
        case .goModuleCache: "go clean -modcache"
        case .simulatorUnavailable: "xcrun simctl delete unavailable"
        case .uvCacheClean: "uv cache clean"
        case .pnpmStorePrune: "pnpm store prune"
        }
    }
}

public enum CleanupMethod: Codable, Sendable, Hashable {
    /// Remove or trash the path itself.
    case filesystem
    /// Run the owning tool's cleanup command.
    case tool(ToolCleanup)
    /// Shown for information only.
    case none
}

/// Result of measuring a directory tree without following symlinks or crossing volumes.
public struct SizeInfo: Codable, Sendable, Hashable {
    /// Sum of file lengths.
    public var logicalBytes: Int64
    /// Blocks actually allocated, with each hard-linked file counted once. This is an upper bound
    /// on what removal frees: APFS clones and snapshots may keep blocks alive.
    public var allocatedBytes: Int64
    public var fileCount: Int
    /// Entries that could not be read. When non-zero the totals are a lower bound.
    public var inaccessibleCount: Int
    /// Allocated bytes of files that have additional hard links (possibly outside this tree).
    public var hardLinkedBytes: Int64
    public var newestModification: Date?
    public var measuredAt: Date
    /// False when the measurement was cancelled before finishing.
    public var complete: Bool

    public init(
        logicalBytes: Int64 = 0, allocatedBytes: Int64 = 0, fileCount: Int = 0, inaccessibleCount: Int = 0,
        hardLinkedBytes: Int64 = 0, newestModification: Date? = nil, measuredAt: Date = Date(), complete: Bool = true
    ) {
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.inaccessibleCount = inaccessibleCount
        self.hardLinkedBytes = hardLinkedBytes
        self.newestModification = newestModification
        self.measuredAt = measuredAt
        self.complete = complete
    }

    /// True when the reclaimable figure cannot be stated exactly.
    public var isApproximate: Bool { inaccessibleCount > 0 || hardLinkedBytes > 0 || !complete }
}

public struct BuildMetadata: Codable, Sendable, Hashable {
    public var system: BuildSystem
    public var configuration: String?
    public var branch: String?
    public var commit: String?
    public var status: BuildStatus
    /// Workspace or manifest the artifact was produced from, when recorded by the tool.
    public var sourcePath: String?
    /// True when the source the artifact was built from no longer exists.
    public var sourceMissing: Bool

    public init(
        system: BuildSystem, configuration: String? = nil, branch: String? = nil, commit: String? = nil,
        status: BuildStatus = .unknown, sourcePath: String? = nil, sourceMissing: Bool = false
    ) {
        self.system = system
        self.configuration = configuration
        self.branch = branch
        self.commit = commit
        self.status = status
        self.sourcePath = sourcePath
        self.sourceMissing = sourceMissing
    }
}

/// One discovered artifact. Analyzers only describe; they have no way to delete.
public struct StorageItem: Codable, Sendable, Identifiable, Hashable {
    public var analyzerID: String
    public var category: ArtifactCategory
    /// Canonical path, or a `tool://` pseudo-path for resources managed through a tool.
    public var path: String
    public var title: String
    public var explanation: String
    public var safety: SafetyClass
    public var safetyReason: String
    public var reproducible: Bool
    public var method: CleanupMethod
    public var projectID: String?
    public var projectConfidence: Confidence
    public var size: SizeInfo?
    public var identity: FileIdentity?
    public var build: BuildMetadata?
    /// Reclaimable bytes reported by the owning tool, for items that are not measured on disk.
    public var toolReportedReclaimable: Int64?
    /// For tool-managed items without a single path: the directories whose sizes add up to the item.
    public var measuredPaths: [String]?

    public var id: String { path }

    public init(
        analyzerID: String, category: ArtifactCategory, path: String, title: String, explanation: String,
        safety: SafetyClass, safetyReason: String, reproducible: Bool, method: CleanupMethod = .filesystem,
        projectID: String? = nil, projectConfidence: Confidence = .unknown, size: SizeInfo? = nil,
        identity: FileIdentity? = nil, build: BuildMetadata? = nil, toolReportedReclaimable: Int64? = nil,
        measuredPaths: [String]? = nil
    ) {
        self.measuredPaths = measuredPaths
        self.analyzerID = analyzerID
        self.category = category
        self.path = path
        self.title = title
        self.explanation = explanation
        self.safety = safety
        self.safetyReason = safetyReason
        self.reproducible = reproducible
        self.method = method
        self.projectID = projectID
        self.projectConfidence = projectConfidence
        self.size = size
        self.identity = identity
        self.build = build
        self.toolReportedReclaimable = toolReportedReclaimable
    }

    /// True when `path` is a `tool://` identifier rather than a location on disk.
    public var hasPseudoPath: Bool { path.hasPrefix("tool://") }

    /// Bytes this item occupies on disk, as far as PEPEL could establish.
    public var occupiedBytes: Int64 { size?.allocatedBytes ?? toolReportedReclaimable ?? 0 }

    /// Upper bound on what removing the item frees.
    public var reclaimableBytes: Int64 { toolReportedReclaimable ?? size?.allocatedBytes ?? 0 }

    public var lastModified: Date? { size?.newestModification }
}

public struct AnalyzerIssue: Codable, Sendable, Hashable {
    public var analyzerID: String
    public var message: String

    public init(analyzerID: String, message: String) {
        self.analyzerID = analyzerID
        self.message = message
    }
}

public struct ScanResult: Codable, Sendable {
    public var startedAt: Date
    public var finishedAt: Date
    public var items: [StorageItem]
    public var issues: [AnalyzerIssue]
    public var cancelled: Bool
    /// Items whose size was reused from the previous scan because nothing under them changed.
    public var reusedMeasurements: Int

    public init(
        startedAt: Date = Date(), finishedAt: Date = Date(), items: [StorageItem] = [],
        issues: [AnalyzerIssue] = [], cancelled: Bool = false, reusedMeasurements: Int = 0
    ) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.items = items
        self.issues = issues
        self.cancelled = cancelled
        self.reusedMeasurements = reusedMeasurements
    }

    public func bytes(_ safety: SafetyClass) -> Int64 {
        items.filter { $0.safety == safety }.reduce(0) { $0 + $1.reclaimableBytes }
    }

    /// Safe + review. Protected data is never counted as reclaimable.
    public var reclaimableBytes: Int64 { bytes(.safe) + bytes(.review) }
}
