import Foundation
import PEPELCore
import PEPELStorage

/// Which applications are used, how much, what they occupy, and removing the ones nobody uses.
extension PepelEngine {
    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Adds the time since the last reading to every open application, and to the one in front.
    /// Only the app records it (the command line does not watch), and a gap longer than two
    /// minutes (sleep, a pause) counts as two minutes.
    func recordAppUsage(now: Date) {
        guard journaling else { return }
        defer { lastAppUsageAt = now }
        guard let last = lastAppUsageAt else { return }
        let elapsed = min(120, max(0, now.timeIntervalSince(last)))
        guard elapsed > 0 else { return }
        let front = frontmostPID(), day = Self.day(now)
        for app in applicationControl.running() where app.isRegular {
            guard let id = app.bundleID ?? Self.bundleID(at: app.bundlePath) else { continue }
            store.addAppUsage(day: day, bundleID: id, name: app.name, foreground: app.pid == front ? elapsed : 0, running: elapsed)
        }
    }

    static func bundleID(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path + "/Contents/Info.plist"),
            let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }

    /// Every application in /Applications (and one level of folders in it) and ~/Applications,
    /// measured with its data, with how it was used and whether removal is suggested.
    public func installedApps(now: Date = Date()) async -> [InstalledApp] {
        // Under a fixture home only its own Applications folder is looked at.
        let scanner = InstalledAppsScanner(home: paths.home, folders: paths.isRedirected ? [paths.home + "/Applications"] : nil)
        let usage = store.appUsage(sinceDay: Self.day(now.addingTimeInterval(-30 * 86_400)))
        let lastSeen = store.appLastSeen()
        let running = applicationControl.running()
        let processes = processSource.snapshot()
        let startup = await startupItems()
        let days = settings.appUnusedDays
        let keep = Set(settings.keepApplications.map { $0.lowercased() })
        var apps = await Task.detached(priority: .utility) { scanner.apps() }.value
        for index in apps.indices {
            var app = apps[index]
            if let total = usage[app.bundleID] {
                app.foregroundSeconds = total.foregroundSeconds
                app.runningSeconds = total.runningSeconds
                app.daysUsed = total.days
            }
            // PEPEL's own record counts too: an app opened by a launcher Spotlight did not see.
            if let seen = lastSeen[app.bundleID].flatMap(Self.date(day:)) { app.lastUsed = max(app.lastUsed ?? .distantPast, seen) }
            app.isRunning = running.contains { $0.bundlePath == app.path } || processes.contains { ($0.executablePath ?? "").hasPrefix(app.path + "/") }
            app.startupLabels = startup.filter { !$0.disabled && ($0.program ?? "").hasPrefix(app.path + "/") }.map(\.label)
            app.judge(days: days, keep: keep, now: now)
            apps[index] = app
        }
        return apps.sorted { ($0.isSuggested ? 1 : 0, $0.totalBytes) > ($1.isSuggested ? 1 : 0, $1.totalBytes) }
    }

    static func date(day: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day).map { $0.addingTimeInterval(86_399) }
    }

    /// Moves an application and, unless asked not to, its data to the Trash, where the restore
    /// center can put them back. A person asks and confirms; never automatic, never an agent.
    public func uninstallApp(_ path: String, includeData: Bool, confirmed: Bool, initiator: Initiator) async -> (denial: String?, bytes: Int64) {
        switch initiator {
        case .agent: return (L("Agents cannot remove applications."), 0)
        case .automatic: return (L("PEPEL never removes an application on its own."), 0)
        case .user, .cli: if !confirmed { return (L("This needs your confirmation."), 0) }
        }
        // Decided again on a fresh reading.
        guard let app = await installedApps().first(where: { $0.path == path }) else { return (L("No such application."), 0) }
        if app.isApple { return (L("It comes with macOS."), 0) }
        if app.isRunning { return (L("\(app.name) is open; quit it first."), 0) }
        if app.bundleID.hasPrefix("dev.pepel.") { return (L("PEPEL does not remove itself."), 0) }
        if PathUtil.keepMarker(at: app.path, stopAt: "/") != nil { return (L("It is marked as not to be cleaned."), 0) }
        var bytes: Int64 = 0
        var moved: [String] = []
        let trash: String? = paths.isRedirected ? paths.home + "/.Trash" : nil
        func toTrash(_ item: String, size: Int64) -> Bool {
            var destination: String?
            if let trash {
                try? FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
                let target = trash + "/" + UUID().uuidString.prefix(6) + "-" + (item as NSString).lastPathComponent
                if (try? FileManager.default.moveItem(atPath: item, toPath: target)) != nil { destination = target }
            } else {
                var resulting: NSURL?
                if (try? FileManager.default.trashItem(at: URL(fileURLWithPath: item), resultingItemURL: &resulting)) != nil { destination = resulting?.path ?? "" }
            }
            guard let destination else { return false }
            if !destination.isEmpty { store.recordTrashed(TrashRecord(source: "Uninstall", originalPath: item, trashedPath: destination, bytes: size)) }
            bytes += size
            moved.append(item)
            return true
        }
        guard toTrash(app.path, size: app.bundleBytes) else {
            return (L("\(app.name) could not be moved to the Trash; an application installed for all users needs an administrator: drag it to the Trash in Finder."), 0)
        }
        var kept: [String] = []
        if includeData {
            for place in app.data where PathUtil.keepMarker(at: place.path, stopAt: paths.home) == nil {
                if !toTrash(place.path, size: place.bytes) { kept.append(place.path) }
            }
        }
        store.appendAudit(
            AuditEntry(
                kind: .cleanup, initiator: initiator.rawValue, subject: "Uninstalled \(app.name)", outcome: "trashed", bytes: bytes,
                detail: ["bundleID": app.bundleID, "moved": moved.joined(separator: "\n"), "notMoved": kept.joined(separator: "\n"), "withData": includeData ? "yes" : "no"]))
        return (nil, bytes)
    }
}
