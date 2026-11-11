import Foundation
@_exported import PEPELAgents
@_exported import PEPELBuilds
@_exported import PEPELCleanup
@_exported import PEPELCore
@_exported import PEPELMemory
@_exported import PEPELMonitoring
@_exported import PEPELPersistence
@_exported import PEPELProcesses
@_exported import PEPELProjects
@_exported import PEPELStorage

/// Fast-changing state: telemetry and the process table.
public struct LiveState: Codable, Sendable {
    public var telemetry: SystemTelemetry
    public var assessments: [ProcessAssessment]
    public var agentSessions: [AgentSession]
    public var memory: MemoryAdvice
    /// Distinct builds or test runs in progress (a build with many compiler processes counts once).
    public var activeBuildCount: Int
    public var userProcessCount: Int
    public var sampledAt: Date
    /// Memory grouped by who is responsible for it, largest first.
    public var memoryOwners: [MemoryOwner] = []
    public var memoryExplanation = ""
    /// Container memory as the runtime reports it; nil when no runtime answers.
    public var containers: ContainerReport?
    /// The same helper started once per agent session.
    public var agentHelpers: [AgentHelperGroup] = []
    /// Processes still running after the application that started them quit.
    public var leftovers: [AppLeftovers] = []
    /// Owners whose memory has kept growing while PEPEL watched.
    public var growth: [MemoryGrowth] = []
    /// Open applications nobody has used for a long time.
    public var unusedApplications: [UnusedApplication] = []
    /// Processes that live almost entirely in swap and do nothing.
    public var dormant: [ProcessAssessment] = []
    /// Process trees PEPEL has suspended.
    public var frozen: [FrozenTree] = []

    public var abandoned: [ProcessAssessment] { assessments.filter { $0.lifecycle.isAbandonedCandidate } }
}

public struct ProjectUsage: Codable, Sendable, Identifiable, Hashable {
    /// Repository group id.
    public var id: String
    public var name: String
    public var roots: [String]
    public var branches: [String]
    public var kinds: [ProjectKind]
    public var artifactBytes: Int64
    public var reclaimableBytes: Int64
    public var itemCount: Int
    /// Change in artifact bytes against the snapshot closest to 24 hours ago, when one exists.
    public var growth: GrowthFigure?
    public var processCount: Int
    public var agentCount: Int
}

/// Slow-changing state produced by a storage scan.
public struct StorageState: Codable, Sendable {
    public var scan: ScanResult
    public var builds: [ProjectBuildSummary]
    public var buildTotalBytes: Int64
    public var globalBuildBudgetBytes: Int64
    public var projects: [Project]
    public var projectUsage: [ProjectUsage]
    /// Item id → reason, for items in use when the scan finished.
    public var inUse: [String: String]

    public var items: [StorageItem] { scan.items }
    public var safeBytes: Int64 { scan.bytes(.safe) }
    public var reviewBytes: Int64 { scan.bytes(.review) }
    /// Safe + review bytes not currently in use. This is the menu bar figure.
    public var reclaimableBytes: Int64 {
        scan.items.filter { $0.safety != .protected && inUse[$0.id] == nil }.reduce(0) { $0 + $1.reclaimableBytes }
    }
    /// True when any contributing measurement is approximate, so the total reads "up to".
    public var reclaimableIsApproximate: Bool {
        scan.items.contains { $0.safety != .protected && ($0.size?.isApproximate ?? false) }
    }
}

public struct GrowthState: Codable, Sendable {
    public var hour: GrowthFigure?
    public var day: GrowthFigure?
    public var week: GrowthFigure?
    public var spikes: [Spike]

    public struct Spike: Codable, Sendable, Hashable, Identifiable {
        public var at: Date
        public var deltaBytes: Int64
        public var id: Date { at }
    }
}

public enum AlertSeverity: String, Codable, Sendable {
    case info, warning, critical
}

public struct PepelAlert: Codable, Sendable, Identifiable, Hashable {
    /// Stable per condition, so a notification is sent once per occurrence.
    public var id: String
    public var severity: AlertSeverity
    public var title: String
    public var message: String
}

public enum AlertEvaluator {
    public static func alerts(live: LiveState?, storage: StorageState?, growth: GrowthState?, settings: PepelSettings) -> [PepelAlert] {
        var alerts: [PepelAlert] = []
        if let t = live?.telemetry, t.diskTotalBytes > 0, t.diskAvailableBytes < settings.lowDiskThresholdBytes {
            let reclaimable = storage?.reclaimableBytes ?? 0
            alerts.append(
                PepelAlert(
                    id: "disk-low", severity: t.diskAvailableBytes < settings.lowDiskThresholdBytes / 4 ? .critical : .warning,
                    title: "Disk space is low",
                    message: "\(Bytes.format(t.diskAvailableBytes)) available. "
                        + (reclaimable > 0
                            ? "Up to \(Bytes.format(reclaimable)) of developer artifacts can be reviewed for cleanup."
                            : "No reclaimable developer artifacts are known; run a scan to diagnose.")))
        }
        if let live, live.telemetry.pressure != .normal {
            alerts.append(
                PepelAlert(
                    id: "memory-\(live.telemetry.pressure.rawValue)", severity: live.telemetry.pressure == .critical ? .critical : .warning,
                    title: live.memory.headline, message: live.memory.detail))
        }
        if let storage {
            for summary in storage.builds where summary.attributed && summary.nearBudget {
                alerts.append(
                    PepelAlert(
                        id: "budget-\(summary.id)-\(summary.overBudget ? "over" : "near")", severity: summary.overBudget ? .warning : .info,
                        title: summary.overBudget ? "\(summary.name) is over its build budget" : "\(summary.name) is near its build budget",
                        message: summary.narrative))
            }
            if storage.buildTotalBytes > storage.globalBuildBudgetBytes {
                alerts.append(
                    PepelAlert(
                        id: "budget-global", severity: .warning, title: "Build artifacts exceed the global budget",
                        message: "Build outputs use \(Bytes.format(storage.buildTotalBytes)) of the \(Bytes.format(storage.globalBuildBudgetBytes)) budget."))
            }
        }
        if let spike = growth?.spikes.last, Date().timeIntervalSince(spike.at) < 3600 {
            alerts.append(
                PepelAlert(
                    id: "spike-\(Int(spike.at.timeIntervalSince1970))", severity: .info, title: "Sudden storage growth",
                    message: "Disk usage grew by \(Bytes.format(spike.deltaBytes)) within minutes at \(spike.at.formatted(date: .omitted, time: .shortened)). Run a scan to see where."))
        }
        return alerts
    }
}

/// Items agents marked as disposable inside workspaces they registered. They are only ever
/// listed for review; an agent's word does not make anything safe.
public struct AgentDisposableAnalyzer: StorageAnalyzer {
    public let id = "agent-registered"
    public let displayName = "Agent-registered temporary files"
    public let detection = "Paths an agent marked disposable through the local API, inside a workspace the same agent registered."
    let store: PepelStore

    public init(store: PepelStore) { self.store = store }

    public func discover(_ context: ScanContext) async -> AnalyzerOutput {
        let marks = store.loadCodable([DisposableMark].self, key: "agent.disposables") ?? []
        var output = AnalyzerOutput()
        for mark in marks {
            guard let identity = PathUtil.identity(mark.path), !identity.isSymlink else { continue }
            output.items.append(
                item(
                    context, category: .temporary, path: mark.path, title: (mark.path as NSString).lastPathComponent,
                    explanation: "Marked disposable by \(mark.owner) on \(mark.markedAt.formatted(date: .abbreviated, time: .shortened)).",
                    safety: .review, reason: "Declared disposable by an agent; needs your confirmation.", reproducible: false))
        }
        return output
    }
}
