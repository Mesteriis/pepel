import Foundation

/// One thing a daily rule is set to do within the next day, as it stands now.
public struct RuleAction: Codable, Sendable, Identifiable, Hashable {
    public enum Rule: String, Codable, Sendable, CaseIterable {
        case docker, staleProjects, toolCaches, appCaches, logs, temp, emulators, systemImages, toolBackups, screenshots, downloads

        public var title: String {
            switch self {
            case .docker: "Docker"
            case .staleProjects: "Projects left untouched"
            case .toolCaches: "Tool caches"
            case .appCaches: "Application caches"
            case .logs: "Old logs"
            case .temp: "Temporary folder"
            case .emulators: "Android emulators"
            case .systemImages: "Android system images"
            case .toolBackups: "Clausona backups"
            case .screenshots: "Screenshots"
            case .downloads: "Downloads"
            }
        }

        /// The key under which the whole rule's next run is left alone.
        public var key: String { "rule:" + rawValue }
    }

    /// Stable key; putting it on the leave-alone list keeps the rule's hands off this item.
    public var id: String
    public var rule: Rule
    public var title: String
    public var path: String?
    public var bytes: Int64
    /// When the rule runs next; the past means at the next pass.
    public var due: Date
    /// "remove", "move to the Trash".
    public var verb: String

    public init(id: String, rule: Rule, title: String, path: String? = nil, bytes: Int64, due: Date, verb: String) {
        self.id = id
        self.rule = rule
        self.title = title
        self.path = path
        self.bytes = bytes
        self.due = due
        self.verb = verb
    }

    public static func pathKey(_ path: String) -> String { "path:" + path }
}

public struct ActionPlan: Codable, Sendable, Hashable {
    public var madeAt: Date
    public var actions: [RuleAction]
    /// Rules that are on but could not be looked at now (Docker not running, for example).
    public var notes: [String]

    public init(madeAt: Date, actions: [RuleAction], notes: [String]) {
        self.madeAt = madeAt
        self.actions = actions
        self.notes = notes
    }

    public var bytes: Int64 { actions.reduce(0) { $0 + $1.bytes } }
}

/// Something PEPEL moved to the Trash, with where it went, so it can be put back.
public struct TrashRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: Int64
    public var at: Date
    /// Which rule or screen moved it ("Downloads and screenshots", "Cleanup").
    public var source: String
    public var originalPath: String
    public var trashedPath: String
    public var bytes: Int64
    public var restoredAt: Date?

    public init(id: Int64 = 0, at: Date = Date(), source: String, originalPath: String, trashedPath: String, bytes: Int64, restoredAt: Date? = nil) {
        self.id = id
        self.at = at
        self.source = source
        self.originalPath = originalPath
        self.trashedPath = trashedPath
        self.bytes = bytes
        self.restoredAt = restoredAt
    }

    public var name: String { (originalPath as NSString).lastPathComponent }
}

/// Everything PEPEL removed recently: what can still be taken back, and what cannot.
public struct RestoreCenter: Codable, Sendable, Hashable {
    /// Still in the Trash, original place free: can be put back.
    public var restorable: [TrashRecord]
    /// Trashed, but the Trash was emptied or the original place is taken again.
    public var gone: [TrashRecord]
    /// Removed for good (caches, rebuildable output, tool cleanups): listed, not returnable.
    public var removed: [AuditEntry]

    public init(restorable: [TrashRecord], gone: [TrashRecord], removed: [AuditEntry]) {
        self.restorable = restorable
        self.gone = gone
        self.removed = removed
    }
}

public enum SummaryFrequency: String, Codable, Sendable, CaseIterable {
    case off, daily, weekly

    public var hours: Double { self == .daily ? 24 : 24 * 7 }

    /// The latest moment a summary was due at, at or before `now`; nil when summaries are off.
    public func lastDue(before now: Date, weekday: Int, hour: Int, calendar: Calendar = .current) -> Date? {
        switch self {
        case .off: return nil
        case .daily:
            var parts = calendar.dateComponents([.year, .month, .day], from: now)
            parts.hour = hour
            guard let today = calendar.date(from: parts) else { return nil }
            return today <= now ? today : calendar.date(byAdding: .day, value: -1, to: today)
        case .weekly:
            let wanted = DateComponents(hour: hour, minute: 0, second: 0, weekday: weekday)
            if calendar.date(now, matchesComponents: wanted) { return now }
            return calendar.nextDate(after: now, matching: wanted, matchingPolicy: .nextTime, direction: .backward)
        }
    }

    /// Whether a summary is owed: one was due since the last one was posted.
    public func isDue(lastPosted: Date?, now: Date, weekday: Int, hour: Int, calendar: Calendar = .current) -> Bool {
        guard let due = lastDue(before: now, weekday: weekday, hour: hour, calendar: calendar) else { return false }
        return (lastPosted ?? .distantPast) < due
    }
}

/// Three ready-made sets for the daily disk rules, so nobody has to tune twenty switches.
public enum SettingsPreset: String, Codable, Sendable, CaseIterable {
    case careful, normal, aggressive

    public var title: String {
        switch self {
        case .careful: "Careful"
        case .normal: "Normal"
        case .aggressive: "Aggressive"
        }
    }

    public var summary: String {
        switch self {
        case .careful: "Nothing is removed on its own. PEPEL finds and reports; you decide."
        case .normal: "Daily rules remove what is rebuilt or downloaded again after a month or two unused. Screenshots go to the Trash after a week."
        case .aggressive: "Daily rules act after two weeks unused, caches are capped at 10 GB, screenshots go after a day and downloads after a month, to the Trash."
        }
    }

    public func apply(to s: inout PepelSettings) {
        let on = self != .careful
        let days = self == .aggressive ? 14 : self == .normal ? 30 : 60
        s.dockerAutoClean = on
        s.dockerUnusedDays = days
        s.cleanStaleProjects = on
        s.staleProjectDays = self == .aggressive ? 30 : self == .normal ? 60 : 90
        s.trimCaches = on
        s.cacheUnusedDays = days
        s.cacheSizeLimitGB = self == .aggressive ? 10 : 0
        s.cleanAppCaches = on
        s.appCacheUnusedDays = days
        s.cleanOldLogs = on
        s.logDays = days
        s.cleanTempFiles = on
        s.tempDays = self == .aggressive ? 3 : self == .normal ? 7 : 14
        s.cleanAndroidEmulators = on
        s.emulatorUnusedDays = self == .careful ? 90 : days
        s.cleanUnusedSystemImages = on
        s.cleanToolBackups = on
        s.toolBackupsKeep = self == .aggressive ? 1 : self == .normal ? 2 : 3
        s.toolBackupsDays = self == .aggressive ? 7 : self == .normal ? 14 : 30
        s.tidyScreenshots = on
        s.screenshotDays = self == .aggressive ? 1 : self == .normal ? 7 : 14
        s.tidyDownloads = self == .aggressive
        s.downloadDays = self == .aggressive ? 30 : self == .normal ? 60 : 90
        s.tidyAction = .trash
    }

    /// The preset the settings are exactly at, or nil when something was tuned by hand.
    public static func matching(_ settings: PepelSettings) -> SettingsPreset? {
        allCases.first { preset in
            var copy = settings
            preset.apply(to: &copy)
            return copy == settings
        }
    }

    /// The rule settings that would change, as "name: old → new".
    public func changes(from settings: PepelSettings) -> [String] {
        var copy = settings
        apply(to: &copy)
        guard
            let before = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))) as? [String: Any],
            let after = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(copy))) as? [String: Any]
        else { return [] }
        return after.keys.sorted().compactMap { key in
            let old = before[key].map { "\($0)" } ?? "", new = after[key].map { "\($0)" } ?? ""
            return old == new ? nil : "\(key): \(old) → \(new)"
        }
    }
}

/// PEPEL watching itself: what its own processes cost and which heavy jobs are running.
public struct SelfUsage: Codable, Sendable, Hashable {
    public struct Process: Codable, Sendable, Hashable {
        public var pid: Int32
        public var name: String
        public var footprintBytes: Int64
        /// Share of one core over the last interval, 100 = one core fully busy; nil on the first reading.
        public var cpuPercent: Double?

        public init(pid: Int32, name: String, footprintBytes: Int64, cpuPercent: Double?) {
            self.pid = pid
            self.name = name
            self.footprintBytes = footprintBytes
            self.cpuPercent = cpuPercent
        }
    }

    public var processes: [Process]
    /// Heavy jobs the app reports as running ("Disk map", "Large files").
    public var heavyTasks: [String]
    public var at: Date

    public init(processes: [Process], heavyTasks: [String], at: Date = Date()) {
        self.processes = processes
        self.heavyTasks = heavyTasks
        self.at = at
    }

    public var footprintBytes: Int64 { processes.reduce(0) { $0 + $1.footprintBytes } }
    public var cpuPercent: Double? { processes.compactMap(\.cpuPercent).isEmpty ? nil : processes.compactMap(\.cpuPercent).reduce(0, +) }

    /// A sentence when PEPEL itself is in the way, nil when it is not.
    public func warning(memoryLimitMB: Int) -> String? {
        let cpu = cpuPercent ?? 0
        if memoryLimitMB > 0, footprintBytes > Int64(memoryLimitMB) * Bytes.mb {
            return "PEPEL itself holds \(Bytes.format(footprintBytes))" + (heavyTasks.isEmpty ? "." : " while \(heavyTasks.joined(separator: ", ")) runs.")
        }
        if cpu >= 80, !heavyTasks.isEmpty {
            return "\(heavyTasks.joined(separator: ", ")) keeps PEPEL at \(Int(cpu.rounded()))% CPU; stop it if the Mac feels slow."
        }
        if cpu >= 50, heavyTasks.isEmpty {
            return "PEPEL uses \(Int(cpu.rounded()))% CPU with no scan running."
        }
        return nil
    }
}
