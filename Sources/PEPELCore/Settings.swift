import Foundation

public enum MenuBarMode: String, Codable, Sendable, CaseIterable {
    case iconOnly, reclaimable, memoryPressure, activeBuilds
}

public enum MonitoringMode: String, Codable, Sendable, CaseIterable {
    /// PEPEL only acts when asked.
    case manual
    /// PEPEL scans in the background and notifies; nothing is removed without the user.
    case notifyOnly
    /// PEPEL may additionally remove items classified `safe`.
    case automaticSafe
}

public enum DeletionMode: String, Codable, Sendable, CaseIterable {
    /// Safe items are removed permanently (they are reproducible and trashing frees no space);
    /// review items go to the Trash so they can be restored.
    case automatic
    /// Everything goes to the Trash. Space is only reclaimed once the Trash is emptied.
    case trash
    /// Everything is removed permanently. Irreversible.
    case permanent
}

public struct QuietHours: Codable, Sendable, Equatable {
    public var enabled = false
    public var startHour = 22
    public var endHour = 8

    public init() {}

    public func contains(hour: Int) -> Bool {
        guard enabled, startHour != endHour else { return false }
        return startHour < endHour
            ? (startHour..<endHour).contains(hour)
            : hour >= startHour || hour < endHour
    }
}

/// Retention policy for build generations of one project. Active and pinned builds are always
/// kept; that is not configurable.
public struct RetentionPolicy: Codable, Sendable, Hashable {
    public var keepSuccessful = 2
    public var keepFailed = 1
    /// Generations younger than this are never proposed.
    public var reviewAfterHours = 48
    /// Generations older than this are proposed even if they would otherwise be kept by count.
    public var maxAgeDays: Int?
    public var budgetBytes: Int64? = 40 * Bytes.gb
    public var protectLastKnownGood = true

    public init() {}
}

public struct PepelSettings: Codable, Sendable, Equatable {
    public var projectRoots: [String] = []
    public var registeredProjects: [String] = []
    public var excludedPaths: [String] = []
    public var discoveryDepth = 5

    public var menuBarMode: MenuBarMode = .reclaimable
    public var monitoringMode: MonitoringMode = .notifyOnly
    public var paused = false
    public var quietHours = QuietHours()
    public var batteryAware = true
    public var notificationsEnabled = true
    public var launchAtLogin = false

    public var deletionMode: DeletionMode = .automatic
    public var defaultRetention = RetentionPolicy()
    public var projectRetention: [String: RetentionPolicy] = [:]
    public var globalBuildBudgetBytes: Int64 = 200 * Bytes.gb
    public var lowDiskThresholdBytes: Int64 = 50 * Bytes.gb
    /// Opt-in. When true, build generations the retention policy marks obsolete are classified
    /// `safe` (and so eligible for automatic cleanup) instead of `review`.
    public var retentionCandidatesAreSafe = false
    /// Artifacts modified more recently than this are treated as possibly being written.
    public var recentWriteProtectionMinutes = 10

    /// Opt-in. Limited to verified, idle, orphaned build/test processes with resolved ownership.
    public var autoTerminateAbandoned = false
    /// Opt-in. Stops (never removes) the containers of a project once no agent session has been
    /// running in that project for `projectIdleGraceMinutes`. For workstations where containers
    /// exist only to serve development done through agents.
    public var stopContainersOfIdleProjects = false
    /// Whether those containers are stopped or only paused.
    public var idleContainerAction: IdleContainerAction = .stop
    public var projectIdleGraceMinutes = 60
    /// Opt-in. Restarts the container VM once a day at `vmRefreshHour` to return the memory it
    /// holds beyond what its containers use, then starts the same containers again. Skipped while
    /// an agent session is working, while a kept container runs, or when there is little to return.
    public var refreshContainerVMNightly = false
    /// Under memory pressure, act sooner: shorter sleep and idle thresholds, and the Docker VM may
    /// be restarted outside its night window. Only tightens rules that are already switched on.
    public var adaptToMemoryPressure = false
    /// Suspend agent sessions that have gone quiet instead of waiting to end them. A suspended
    /// session keeps everything and continues when its application comes to the front.
    /// An open application counts as unused after this long without being in front.
    public var unusedApplicationHours = 6
    /// Applications never listed as unused (by name), such as a music player or a messenger.
    public var keepApplications: [String] = []
    /// Control-Option-Command-M opens Free memory from anywhere.
    public var freeMemoryHotkey = false
    /// Run the preselected Free memory steps whenever the screen is locked.
    public var freeMemoryOnLock = false
    /// Limits for what an owner may hold; exceeding one raises an alert, nothing more.
    public var memoryBudgets: [MemoryBudget] = []
    /// An older copy of a program inside an agent's server counts as left behind after this long idle.
    public var serviceBranchIdleMinutes = 120
    /// A browser tab's process counts as idle after this long without CPU use.
    public var tabIdleMinutes = 30
    /// Warn when memory is forecast to run short within this many minutes; 0 switches the warning off.
    public var forecastWarnMinutes = 45
    /// Post a summary of the last day once a day at `dailySummaryHour`.
    public var dailySummary = false
    public var dailySummaryHour = 9
    /// Write the memory journal: a reading every five minutes, kept as daily files.
    public var journalEnabled = true
    public var journalRetentionDays = 30
    /// Once a day, remove what Docker can rebuild or pull again and has not used for `dockerUnusedDays`:
    /// stopped containers, images no container uses, build cache, unused networks. Never volumes.
    public var dockerAutoClean = false
    public var dockerUnusedDays = 30
    /// Once a day, remove environments, dependencies and build output of projects nobody has
    /// touched for `staleProjectDays`. Source, git metadata and configuration are never part of it.
    public var cleanStaleProjects = false
    public var staleProjectDays = 30
    public var freezeIdleAgents = false
    public var freezeAfterMinutes = 20
    /// How often a frozen session is woken for a moment to see whether work is waiting.
    public var freezePeekMinutes = 10
    /// Local hour (0–23) at which the nightly restart may start; it has two hours to find a quiet moment.
    public var vmRefreshHour = 4
    /// The VM is only restarted when it is charged at least this much more than its containers use.
    public var vmRefreshMinimumExcessBytes: Int64 = 4 * Bytes.gb
    /// Containers and compose projects PEPEL must leave running: exact container names or compose
    /// project names. A container can also declare this itself with the label `pepel.keep=true`.
    public var keepContainers: [String] = []
    /// Opt-in. Terminates processes an application left running after it quit, once
    /// `appLeftoverGraceMinutes` have passed. System-managed components, agent sessions and
    /// container runtimes are never part of this.
    public var terminateAppLeftovers = false
    public var appLeftoverGraceMinutes = 10
    /// Opt-in. Terminates agent sessions that have been asleep for `agentSleepMinutes`: no disk
    /// writes, no CPU bursts, no new processes and no build in that whole time. A session waiting
    /// for the user's reply is indistinguishable from a sleeping one and is terminated too.
    public var terminateSleepingAgents = false
    public var agentSleepMinutes = 120
    public var idleMinutesBeforeAbandoned = 30
    public var gracefulTerminationSeconds = 10

    public init() {}

    public func retention(for projectID: String?) -> RetentionPolicy {
        projectID.flatMap { projectRetention[$0] } ?? defaultRetention
    }

    /// Roots that exist on this machine. `~/Documents`, `~/Desktop` and `~/Downloads` are not
    /// probed by default: touching them triggers a privacy prompt PEPEL does not need.
    public static func detectDefaultRoots(home: String = NSHomeDirectory()) -> [String] {
        var seen = Set<FileIdentity>()
        var roots: [String] = []
        for name in ["projects", "Developer", "src", "code", "work", "dev", "git", "repos", "workspace"] {
            let path = home + "/" + name
            guard let id = PathUtil.identity(PathUtil.canonical(path)), id.isDirectory, seen.insert(id).inserted
            else { continue }
            roots.append("~/" + name)
        }
        return roots
    }

    /// Decodes stored settings on top of current defaults so that settings written by an older
    /// or newer build never fail to load because of a missing key.
    public static func decodeLenient(_ data: Data) -> PepelSettings {
        let defaults = PepelSettings()
        guard
            let defaultData = try? JSONEncoder().encode(defaults),
            var merged = (try? JSONSerialization.jsonObject(with: defaultData)) as? [String: Any],
            let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return defaults }
        for (key, value) in stored where merged[key] != nil || key == "maxAgeDays" {
            if var nested = merged[key] as? [String: Any], let storedNested = value as? [String: Any],
                key == "defaultRetention" || key == "quietHours"
            {
                for (k, v) in storedNested { nested[k] = v }
                merged[key] = nested
            } else {
                merged[key] = value
            }
        }
        guard
            let mergedData = try? JSONSerialization.data(withJSONObject: merged),
            let settings = try? JSONDecoder().decode(PepelSettings.self, from: mergedData)
        else { return defaults }
        return settings
    }
}

extension PepelSettings {
    /// The settings in force at a given memory pressure. With `adaptToMemoryPressure` on, waiting
    /// periods halve under elevated pressure and quarter under critical pressure, never below a
    /// floor that keeps a session someone just stepped away from safe.
    public func adapted(to pressure: MemoryPressureLevel) -> PepelSettings {
        guard adaptToMemoryPressure, pressure != .normal else { return self }
        let divisor = pressure == .critical ? 4 : 2
        var copy = self
        copy.agentSleepMinutes = max(30, agentSleepMinutes / divisor)
        copy.projectIdleGraceMinutes = max(15, projectIdleGraceMinutes / divisor)
        copy.appLeftoverGraceMinutes = max(2, appLeftoverGraceMinutes / divisor)
        copy.freezeAfterMinutes = max(5, freezeAfterMinutes / divisor)
        return copy
    }
}
