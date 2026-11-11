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
