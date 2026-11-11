import Darwin
import Foundation

/// Applications that keep running with no window: noticed, listed, and quit when the user
/// asked for it, after a grace period and only when nothing suggests they are still in use.
extension PepelEngine {
    static let windowlessKey = "apps.windowless"

    struct WindowlessState: Codable, Sendable {
        /// When it was first seen with no window in the current stretch, and its CPU time then.
        var since: Date
        var cpuMilliseconds: Int64
    }

    nonisolated func windowlessSeen() -> [String: WindowlessApp] { store.loadCodable([String: WindowlessApp].self, key: Self.windowlessKey) ?? [:] }

    /// CPU time of an application's processes, its helpers included.
    func cpuMilliseconds(of bundlePath: String) -> Int64 {
        lastProcesses.filter { $0.executablePath?.hasPrefix(bundlePath + "/") ?? false }.reduce(0) { $0 + Int64($1.cpuTimeNs / 1_000_000) }
    }

    /// One pass: who is open without a window, and whom to quit.
    @discardableResult
    func windowlessPass(now: Date = Date()) async -> [String] {
        guard applicationControl.isAvailable else { return [] }
        let counts = applicationControl.windowCounts()
        let front = frontmostPID()
        var seen = windowlessSeen()
        var changed = false
        var quit: [String] = []
        var stillWindowless = Set<String>()
        for app in applicationControl.running() where app.isRegular {
            guard let id = app.bundleID, app.pid != getpid() else { continue }
            guard counts[app.pid, default: 0] == 0 else {
                windowlessStates[id] = nil
                continue
            }
            stillWindowless.insert(id)
            // A new stretch without windows counts as one sighting.
            if windowlessStates[id] == nil {
                var entry = seen[id] ?? WindowlessApp(bundleID: id, name: app.name, path: app.bundlePath, timesSeen: 0, lastSeen: nil, known: WindowlessApp.knownApps.contains(id))
                entry.timesSeen += 1
                entry.lastSeen = now
                entry.name = app.name
                entry.path = app.bundlePath
                seen[id] = entry
                changed = true
            }
            // In front, the person may be about to open something: the clock starts again.
            if app.pid == front || windowlessStates[id] == nil {
                windowlessStates[id] = WindowlessState(since: now, cpuMilliseconds: cpuMilliseconds(of: app.bundlePath))
                continue
            }
            guard settings.quitWhenWindowless.contains(id), !settings.paused, let state = windowlessStates[id] else { continue }
            let identity = processSource.identity(of: app.pid)
            if let identity, windowlessAsked.contains(identity) { continue }
            let waited = now.timeIntervalSince(state.since)
            guard waited >= Double(settings.windowlessQuitMinutes) * 60 else { continue }
            // Busy without a window (playing, exporting, syncing): it is being used. Start again.
            let used = Double(cpuMilliseconds(of: app.bundlePath) - state.cpuMilliseconds) / 1000
            if used > max(1, waited * 0.02) {
                windowlessStates[id] = WindowlessState(since: now, cpuMilliseconds: cpuMilliseconds(of: app.bundlePath))
                continue
            }
            // The same checks as quitting by hand: nothing living inside it, not PEPEL's own surroundings.
            guard let decision = await applicationDecision(.quit, bundlePath: app.bundlePath, initiator: .user), decision.verdict != .denied else { continue }
            if let identity { windowlessAsked.insert(identity) }
            if applicationControl.quit(app.pid) {
                quit.append(app.name)
                windowlessStates[id] = nil
                store.appendAudit(
                    AuditEntry(
                        kind: .termination, initiator: Initiator.automatic.rawValue, subject: app.name, outcome: "quit (no window)",
                        detail: ["withoutWindowFor": TimeFormat.age(waited), "bundleID": id]))
            }
        }
        for id in windowlessStates.keys where !stillWindowless.contains(id) { windowlessStates[id] = nil }
        windowlessAsked = windowlessAsked.filter { processSource.identity(of: $0.pid) == $0 }
        if changed { try? store.saveCodable(seen, key: Self.windowlessKey) }
        return quit
    }

    /// Applications that stay open with no window: those PEPEL has seen, and Apple's document
    /// apps that are installed. Most often seen first.
    public func windowlessApps() async -> [WindowlessApp] {
        var all = windowlessSeen()
        for id in WindowlessApp.knownApps where all[id] == nil {
            guard let path = applicationControl.locate(id) else { continue }
            all[id] = WindowlessApp(bundleID: id, name: ((path as NSString).lastPathComponent as NSString).deletingPathExtension, path: path, timesSeen: 0, lastSeen: nil, known: true)
        }
        let counts = applicationControl.windowCounts()
        let running = Dictionary(applicationControl.running().compactMap { app in app.bundleID.map { ($0, app) } }, uniquingKeysWith: { first, _ in first })
        return all.values.map { app in
            var app = app
            app.known = app.known || WindowlessApp.knownApps.contains(app.bundleID)
            if let process = running[app.bundleID] {
                app.running = true
                app.windowlessNow = counts[process.pid, default: 0] == 0
            }
            app.quitWhenWindowless = settings.quitWhenWindowless.contains(app.bundleID)
            return app
        }
        .sorted { ($0.quitWhenWindowless ? 1 : 0, $0.timesSeen, $0.known ? 1 : 0) > ($1.quitWhenWindowless ? 1 : 0, $1.timesSeen, $1.known ? 1 : 0) }
    }

    /// Switches the rule on or off for one application.
    public func setQuitWhenWindowless(_ bundleID: String, _ on: Bool) throws {
        _ = try update { s in
            s.quitWhenWindowless.removeAll { $0 == bundleID }
            if on { s.quitWhenWindowless.append(bundleID) }
        }
    }
}
