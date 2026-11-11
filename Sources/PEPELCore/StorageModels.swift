import Foundation

public enum ArtifactCategory: String, Codable, Sendable, CaseIterable {
    case buildOutput, dependencyCache, toolCache, testArtifact, virtualEnvironment, dependencies
    case simulator, archive, container, containerVolume, agentState, modelWeights, temporary

    public var displayName: String {
        switch self {
        case .buildOutput: L("Build output")
        case .dependencyCache: L("Dependency cache")
        case .toolCache: L("Tool cache")
        case .testArtifact: L("Test artifact")
        case .virtualEnvironment: L("Virtual environment")
        case .dependencies: L("Installed dependencies")
        case .simulator: L("Simulator data")
        case .archive: L("Archive")
        case .container: L("Container data")
        case .containerVolume: L("Container volume")
        case .agentState: L("Agent state")
        case .modelWeights: L("Model weights")
        case .temporary: L("Temporary files")
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
        case .other: L("Other")
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
    /// When the project this artifact belongs to was last worked on. Set only for artifacts that
    /// are recreated by installing or building again, and that lie inside the project.
    public var projectLastActivity: Date?

    public var id: String { path }

    /// Whether the artifact's project has been left untouched for at least `days`.
    public func isStale(days: Int, now: Date = Date()) -> Bool {
        guard let last = projectLastActivity else { return false }
        return now.timeIntervalSince(last) >= Double(days) * 86_400
    }

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

/// A project nobody has touched for a long time, with what its recreatable artifacts hold.
public struct StaleProject: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var lastActivity: Date
    public var bytes: Int64
    public var itemIDs: [String]

    public init(id: String, name: String, lastActivity: Date, bytes: Int64, itemIDs: [String]) {
        self.id = id
        self.name = name
        self.lastActivity = lastActivity
        self.bytes = bytes
        self.itemIDs = itemIDs
    }
}

/// A tool's cache that PEPEL can keep in bounds by age.
public struct ManagedCache: Codable, Sendable, Identifiable, Hashable {
    public enum Style: String, Codable, Sendable {
        /// A store of independent files: each one unused for long enough is removed.
        case files
        /// One folder per entry (a browser build, an unpacked package): removed whole when nothing in it was used.
        case entries
    }

    public var id: String
    public var title: String
    public var path: String
    public var style: Style
    public var note: String
    public var totalBytes: Int64 = 0
    public var fileCount = 0
    /// Not read or written for the chosen number of days.
    public var staleBytes: Int64 = 0
    public var staleCount = 0

    public init(id: String, title: String, path: String, style: Style, note: String) {
        self.id = id
        self.title = title
        self.path = path
        self.style = style
        self.note = note
    }
}

public struct CacheTrimReport: Codable, Sendable, Hashable {
    public struct Step: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var bytes: Int64
        public var removed: Int

        public init(id: String, title: String, bytes: Int64, removed: Int) {
            self.id = id
            self.title = title
            self.bytes = bytes
            self.removed = removed
        }
    }

    public var days: Int
    public var steps: [Step]
    public var diskAvailableBefore: Int64
    public var diskAvailableAfter: Int64

    public init(days: Int, steps: [Step], diskAvailableBefore: Int64, diskAvailableAfter: Int64) {
        self.days = days
        self.steps = steps
        self.diskAvailableBefore = diskAvailableBefore
        self.diskAvailableAfter = diskAvailableAfter
    }

    public var bytes: Int64 { steps.reduce(0) { $0 + $1.bytes } }
}

public enum ApplicationDataOwner: String, Codable, Sendable {
    /// The application is running now.
    case running
    case installed
    /// Named by a bundle identifier that no installed application has.
    case removed
    /// Not named in a way that says whose it is (often a command-line tool).
    case unknown
}

/// A folder an application keeps in the Library: its cache, or what it left behind.
public struct ApplicationData: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case cache, leftover
    }

    public var name: String
    public var path: String
    public var kind: Kind
    public var owner: ApplicationDataOwner
    public var bytes: Int64
    public var lastUse: Date?

    public var id: String { path }

    public init(name: String, path: String, kind: Kind, owner: ApplicationDataOwner, bytes: Int64, lastUse: Date?) {
        self.name = name
        self.path = path
        self.kind = kind
        self.owner = owner
        self.bytes = bytes
        self.lastUse = lastUse
    }

    public func unused(days: Int, now: Date = Date()) -> Bool {
        guard let lastUse else { return false }
        return now.timeIntervalSince(lastUse) >= Double(days) * 86_400
    }
}

/// A large place PEPEL shows but does not clean.
public struct OtherPlace: Codable, Sendable, Identifiable, Hashable {
    public var path: String
    public var title: String
    public var note: String
    public var bytes: Int64
    public var lastUse: Date?
    /// Marked by someone as not to be cleaned.
    public var kept: Bool
    public var id: String { path }

    public init(path: String, title: String, note: String, bytes: Int64, lastUse: Date?, kept: Bool) {
        self.path = path
        self.title = title
        self.note = note
        self.bytes = bytes
        self.lastUse = lastUse
        self.kept = kept
    }
}

/// When the disk would be full if it kept filling at the rate of the last days.
public struct DiskForecast: Codable, Sendable, Hashable {
    public var perDayBytes: Int64
    public var availableBytes: Int64
    public var fullAt: Date
    public var basedOn: TimeInterval

    public init(perDayBytes: Int64, availableBytes: Int64, fullAt: Date, basedOn: TimeInterval) {
        self.perDayBytes = perDayBytes
        self.availableBytes = availableBytes
        self.fullAt = fullAt
        self.basedOn = basedOn
    }

    /// From the growth over a period of at least two days. No forecast for a disk that is not
    /// filling, or that would take more than a year.
    public static func project(grownBytes: Int64, over span: TimeInterval, availableBytes: Int64, now: Date = Date()) -> DiskForecast? {
        guard span >= 2 * 86_400, grownBytes > 0, availableBytes > 0 else { return nil }
        let perDay = Double(grownBytes) / (span / 86_400)
        let days = Double(availableBytes) / perDay
        guard perDay >= Double(Bytes.gb) / 10, days <= 365 else { return nil }
        return DiskForecast(perDayBytes: Int64(perDay), availableBytes: availableBytes, fullAt: now.addingTimeInterval(days * 86_400), basedOn: span)
    }

    public func sentence(now: Date = Date()) -> String {
        L("The disk has been filling by about \(Bytes.format(perDayBytes)) a day over the last \(TimeFormat.age(basedOn)). At that rate the \(Bytes.format(availableBytes)) that are available last about \(max(1, Int(fullAt.timeIntervalSince(now) / 86_400))) days.")
    }
}

/// One file or folder directly inside the temporary folder.
public struct TempEntry: Codable, Sendable, Identifiable, Hashable {
    public var path: String
    public var name: String
    public var bytes: Int64
    public var lastUse: Date
    public var isDirectory: Bool
    /// Why PEPEL leaves it; nil when it would be removed.
    public var keptBecause: String?
    public var id: String { path }

    public init(path: String, name: String, bytes: Int64, lastUse: Date, isDirectory: Bool, keptBecause: String? = nil) {
        self.path = path
        self.name = name
        self.bytes = bytes
        self.lastUse = lastUse
        self.isDirectory = isDirectory
        self.keptBecause = keptBecause
    }
}

/// A large folder inside a project that git ignores and PEPEL does not recognise as a build
/// artifact: scratch data, local state, downloads. It may be data, so it is only ever moved to
/// the Trash, and only when the user asks.
public struct IgnoredFolder: Codable, Sendable, Identifiable, Hashable {
    public var path: String
    public var projectID: String
    public var projectName: String
    public var bytes: Int64
    public var lastUse: Date?
    /// Its name says it holds data (a database, dumps, backups, configuration), not output.
    public var looksLikeData = false
    public var id: String { path }

    public init(path: String, projectID: String, projectName: String, bytes: Int64, lastUse: Date?) {
        self.path = path
        self.projectID = projectID
        self.projectName = projectName
        self.bytes = bytes
        self.lastUse = lastUse
    }

    static let dataWords: Set<String> = [
        "data", "db", "database", "databases", "postgres", "pgdata", "postgresql", "mysql", "mariadb", "redis", "mongo", "mongodb", "sqlite", "volumes",
        "backup", "backups", "dumps", "dump", "config", "uploads", "storage", "mail", "minio", "elasticsearch", "opensearch",
    ]

    public static func looksLikeData(_ relativePath: String) -> Bool {
        relativePath.lowercased().split(separator: "/").contains { dataWords.contains(String($0)) }
    }
}

/// An Android virtual device: its disk images, its data, and whether it is running.
public struct AndroidEmulator: Codable, Sendable, Identifiable, Hashable {
    public var name: String
    /// The `.avd` folder.
    public var path: String
    public var bytes: Int64
    /// When it was last started or written to.
    public var lastUse: Date?
    public var target: String?
    public var running: Bool
    public var id: String { name }

    public init(name: String, path: String, bytes: Int64, lastUse: Date?, target: String?, running: Bool) {
        self.name = name
        self.path = path
        self.bytes = bytes
        self.lastUse = lastUse
        self.target = target
        self.running = running
    }
}

/// A large file, for the report of what is old or duplicated.
public struct LargeFile: Codable, Sendable, Identifiable, Hashable {
    public var path: String
    public var bytes: Int64
    public var lastUse: Date
    public var id: String { path }

    public init(path: String, bytes: Int64, lastUse: Date) {
        self.path = path
        self.bytes = bytes
        self.lastUse = lastUse
    }
}

/// Large files nobody has opened for a long time, and identical copies of large files.
public struct LargeFilesReport: Codable, Sendable, Hashable {
    public var old: [LargeFile]
    /// Each group holds files with exactly the same contents, the most recently used first.
    public var duplicates: [[LargeFile]]
    public var filesSeen: Int
    public var measuredAt: Date

    public init(old: [LargeFile], duplicates: [[LargeFile]], filesSeen: Int, measuredAt: Date = Date()) {
        self.old = old
        self.duplicates = duplicates
        self.filesSeen = filesSeen
        self.measuredAt = measuredAt
    }

    /// What removing every copy but one would free at most. Copies Finder made on the same disk
    /// can be clones that share their blocks, in which case less is freed.
    public var duplicateBytes: Int64 { duplicates.reduce(0) { $0 + $1.dropFirst().reduce(0) { $0 + $1.bytes } } }
    public var oldBytes: Int64 { old.reduce(0) { $0 + $1.bytes } }
}

/// An Android system image in the SDK, and the emulators that start from it.
public struct AndroidSystemImage: Codable, Sendable, Identifiable, Hashable {
    /// `android-36/google_apis/arm64-v8a`
    public var id: String
    public var path: String
    public var bytes: Int64
    public var usedBy: [String]

    public init(id: String, path: String, bytes: Int64, usedBy: [String]) {
        self.id = id
        self.path = path
        self.bytes = bytes
        self.usedBy = usedBy
    }
}

/// One backup a tool made: a folder with its own date.
public struct ToolBackup: Codable, Sendable, Identifiable, Hashable {
    public var path: String
    /// The group it belongs to; retention keeps the newest of each.
    public var set: String
    public var createdAt: Date
    public var bytes: Int64
    /// Kept by the retention rule: among the newest of its set, or not old enough yet.
    public var kept: Bool
    public var id: String { path }

    public init(path: String, set: String, createdAt: Date, bytes: Int64, kept: Bool) {
        self.path = path
        self.set = set
        self.createdAt = createdAt
        self.bytes = bytes
        self.kept = kept
    }
}

/// What tidying Downloads and the Desktop does with what it picks.
public enum TidyAction: String, Codable, Sendable, CaseIterable {
    /// Move to the Trash: recoverable until the Trash is emptied.
    case trash
    /// Remove for good.
    case delete
}

/// A file or folder in Downloads or on the Desktop, as tidying sees it.
public struct TidyItem: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// A screenshot or screen recording macOS made (it marks them itself).
        case screenshot
        /// Anything else in Downloads.
        case download
        /// A download that never finished.
        case partial
    }

    public var path: String
    public var name: String
    public var kind: Kind
    public var bytes: Int64
    /// The newest of when it arrived, was changed and was last opened.
    public var lastUse: Date
    /// Why it stays; nil when tidying would take it.
    public var keptBecause: String?
    public var id: String { path }

    public init(path: String, name: String, kind: Kind, bytes: Int64, lastUse: Date, keptBecause: String?) {
        self.path = path
        self.name = name
        self.kind = kind
        self.bytes = bytes
        self.lastUse = lastUse
        self.keptBecause = keptBecause
    }
}
