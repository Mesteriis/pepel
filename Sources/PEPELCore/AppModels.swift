import Foundation

/// Recorded use of one application over a period.
public struct AppUsageTotal: Codable, Sendable, Hashable {
    public var name: String
    public var foregroundSeconds: Double
    public var runningSeconds: Double
    /// yyyy-MM-dd of the last day it was open.
    public var lastDay: String
    /// Days on which it was open.
    public var days: Int

    public init(name: String, foregroundSeconds: Double, runningSeconds: Double, lastDay: String, days: Int) {
        self.name = name
        self.foregroundSeconds = foregroundSeconds
        self.runningSeconds = runningSeconds
        self.lastDay = lastDay
        self.days = days
    }
}

/// A place where an application keeps data outside its bundle.
public struct AppDataPlace: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    /// "Application Support", "Caches", "Preferences" …
    public var kind: String
    public var bytes: Int64
    public var id: String { path }

    public init(path: String, kind: String, bytes: Int64) {
        self.path = path
        self.kind = kind
        self.bytes = bytes
    }
}

/// An installed application, how much it is used, and what it occupies.
public struct InstalledApp: Codable, Sendable, Hashable, Identifiable {
    public var bundleID: String
    public var name: String
    public var path: String
    public var version: String?
    /// When macOS last opened it (Spotlight's record), or when PEPEL last saw it open, whichever is later.
    public var lastUsed: Date?
    /// How many times macOS has opened it, when Spotlight knows.
    public var useCount: Int?
    /// When it arrived on this Mac.
    public var added: Date?
    public var bundleBytes: Int64
    public var data: [AppDataPlace]
    /// From PEPEL's own record over the last 30 days.
    public var foregroundSeconds: Double = 0
    public var runningSeconds: Double = 0
    public var daysUsed = 0
    public var isApple: Bool
    public var isRunning = false
    /// Launch agents and daemons whose program lives inside this app.
    public var startupLabels: [String] = []
    /// Why it is not suggested for removal, or nil when it is.
    public var keptBecause: String?

    public var id: String { path }
    public var dataBytes: Int64 { data.reduce(0) { $0 + $1.bytes } }
    public var totalBytes: Int64 { bundleBytes + dataBytes }
    public var isSuggested: Bool { keptBecause == nil }

    public init(bundleID: String, name: String, path: String, version: String?, lastUsed: Date?, useCount: Int?, added: Date?, bundleBytes: Int64, data: [AppDataPlace], isApple: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
        self.version = version
        self.lastUsed = lastUsed
        self.useCount = useCount
        self.added = added
        self.bundleBytes = bundleBytes
        self.data = data
        self.isApple = isApple
    }

    /// Decides whether removal is suggested: unused for `days`, not part of macOS, not open, not
    /// running in the background, not kept, and not installed recently.
    public mutating func judge(days: Int, keep: Set<String>, now: Date = Date()) {
        let limit = Double(days) * 86_400
        if isApple { keptBecause = L("It comes with macOS."); return }
        if keep.contains(name.lowercased()) || keep.contains(bundleID.lowercased()) { keptBecause = L("It is on the keep list."); return }
        if isRunning { keptBecause = L("It is open now."); return }
        if !startupLabels.isEmpty { keptBecause = L("It starts on its own (\(startupLabels.joined(separator: ", "))): switch that off in Startup first if you no longer need it."); return }
        if let added, now.timeIntervalSince(added) < limit { keptBecause = L("Installed \(TimeFormat.age(now.timeIntervalSince(added))) ago."); return }
        if let lastUsed, now.timeIntervalSince(lastUsed) < limit { keptBecause = L("Used \(TimeFormat.age(now.timeIntervalSince(lastUsed))) ago."); return }
        keptBecause = nil
    }
}
