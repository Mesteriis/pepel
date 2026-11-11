import Darwin
import Foundation

public struct ApplicationActionReport: Codable, Sendable {
    public var decision: ApplicationDecision
    public var quit: Bool
    public var reopened: Bool
    public var footprintBefore: Int64
    public var footprintAfter: Int64
    public var note: String
}

/// Memory history per owner, growth detection, and asking applications to quit or restart.
extension PepelEngine {
    static let memoryScope = "memory"

    /// Every five minutes: what each sizeable owner holds, and a fresh look at who has grown.
    func recordMemory(owners: [MemoryOwner], now: Date) {
        guard now.timeIntervalSince(lastMemoryWrite) >= 300 else { return }
        lastMemoryWrite = now
        // The system group and the VM have their own explanations; growth is about things a
        // person can restart.
        let tracked = owners.filter { [.application, .agentSession, .project, .developerTool, .other].contains($0.kind) && $0.footprintBytes >= 200 * Bytes.mb }
        store.recordUsage(scope: Self.memoryScope, entries: tracked.map { ($0.id, $0.name, $0.footprintBytes) }, at: now)
        recordApplicationCPU(processes: lastProcesses, now: now)
        growthCache = memoryGrowth(owners: owners, now: now)
    }

    /// Owners still running whose memory rose steadily over the recorded history, largest first.
    public func memoryGrowth(owners: [MemoryOwner], now: Date = Date()) -> [MemoryGrowth] {
        let running = Dictionary(owners.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return store.usageSeries(scope: Self.memoryScope, since: now.addingTimeInterval(-7 * 86_400))
            .compactMap { key, entry -> MemoryGrowth? in
                guard let owner = running[key] else { return nil }
                return MemoryGrowthAnalyzer.growth(id: key, kind: owner.kind, name: owner.name, samples: entry.samples)
            }
            .sorted { $0.grownBytes > $1.grownBytes }
    }

    /// The main process of the application a memory owner stands for.
    func applicationProcess(bundlePath: String) -> ProcessSnapshot? {
        let prefix = bundlePath + "/Contents/MacOS/"
        return lastProcesses.filter { $0.executablePath?.hasPrefix(prefix) ?? false }.min { $0.identity.startTime < $1.identity.startTime }
    }

    public func applicationDecision(_ action: ApplicationAction, bundlePath: String, initiator: Initiator) async -> ApplicationDecision? {
        let liveState = await refreshLive()
        guard let main = applicationProcess(bundlePath: bundlePath) else { return nil }
        let tree = ProcessTree(lastProcesses)
        let inside = Set(tree.descendants(of: main).map(\.identity))
        let sessions = liveState.agentSessions.filter { inside.contains($0.root) }.count
        let developer = liveState.assessments.filter { inside.contains($0.process.identity) && $0.lifecycle != .agentSession && ($0.role == .buildTool || $0.role == .testRunner || $0.role == .devServer) }.count
        let own = lastProcesses.first { $0.pid == getpid() }
        let owner = liveState.memoryOwners.first { $0.id == "app:\(bundlePath)" }
        return policy.evaluateApplication(
            action, bundlePath: bundlePath, name: owner?.name ?? main.name, pid: main.pid, footprintBytes: owner?.footprintBytes ?? main.footprintBytes,
            agentSessions: sessions, developerProcesses: developer, isFrontmost: frontmostPID() == main.pid, initiator: initiator,
            ownAncestors: Set(own.map { tree.ancestors(of: $0).map(\.pid) } ?? []))
    }

    /// Asks an application to quit, waits for it, and for a restart opens it again.
    public func performApplication(_ action: ApplicationAction, bundlePath: String, confirmed: Bool, initiator: Initiator, waitSeconds: Double = 30) async -> ApplicationActionReport? {
        guard let decision = await applicationDecision(action, bundlePath: bundlePath, initiator: initiator) else { return nil }
        var report = ApplicationActionReport(decision: decision, quit: false, reopened: false, footprintBefore: decision.footprintBytes, footprintAfter: decision.footprintBytes, note: "")
        guard let approved = policy.approveApplication(decision, confirmed: confirmed, initiator: initiator), applicationControl.isAvailable else {
            report.note = decision.verdict == .denied ? decision.reasons.joined(separator: " ") : "Not confirmed."
            return report
        }
        let target = approved.decision
        guard let identity = processSource.identity(of: target.pid), applicationControl.quit(target.pid) else {
            report.note = "\(target.name) did not accept the request to quit."
            return report
        }
        let deadline = ContinuousClock.now + .seconds(waitSeconds)
        while processSource.identity(of: target.pid) == identity, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(waitSeconds < 1 ? 5 : 300))
        }
        report.quit = processSource.identity(of: target.pid) != identity
        if !report.quit {
            report.note = "\(target.name) is still running; it may be asking about unsaved changes. PEPEL did not force it."
        } else if action == .restart {
            report.reopened = await applicationControl.launch(target.bundlePath)
            report.note = report.reopened ? "\(target.name) quit and was opened again." : "\(target.name) quit, but could not be opened again; open it yourself."
            // Let it settle before reading what it holds now.
            if waitSeconds >= 1 { try? await Task.sleep(for: .seconds(8)) }
        } else {
            report.note = "\(target.name) quit."
        }
        let after = await refreshLive()
        report.footprintAfter = after.memoryOwners.first { $0.id == "app:\(target.bundlePath)" }?.footprintBytes ?? 0
        store.appendAudit(
            AuditEntry(
                kind: .termination, initiator: initiator.rawValue, subject: target.name,
                outcome: report.quit ? (action == .restart ? "restarted" : "quit") : "asked to quit, still running",
                bytes: max(0, report.footprintBefore - report.footprintAfter),
                detail: ["chargedBefore": Bytes.format(report.footprintBefore), "chargedAfter": Bytes.format(report.footprintAfter), "note": report.note]))
        return report
    }

    // MARK: Unused applications

    static let lastActiveKey = "apps.lastActive"
    static let cpuScope = "appcpu"

    nonisolated func lastActive() -> [String: Date] { store.loadCodable([String: Date].self, key: Self.lastActiveKey) ?? [:] }

    /// An application came to the front (reported by the app). Safe to call from anywhere.
    public nonisolated func noteActivation(bundlePath: String, at date: Date = Date()) {
        var known = lastActive()
        known[bundlePath] = date
        try? store.saveCodable(known, key: Self.lastActiveKey)
    }

    /// Every five minutes: the CPU time each application's processes have used so far, so that an
    /// application working in the background (playing music, syncing) is not mistaken for unused.
    func recordApplicationCPU(processes: [ProcessSnapshot], now: Date) {
        var totals: [String: Int64] = [:]
        for p in processes {
            guard let path = p.executablePath, let range = path.range(of: ".app/Contents/") else { continue }
            totals[String(path[..<range.lowerBound]) + ".app", default: 0] += Int64(p.cpuTimeNs / 1_000_000)
        }
        // Helpers live in nested bundles; charge them to the outermost one.
        var outer: [String: Int64] = [:]
        for (bundle, milliseconds) in totals {
            let top = bundle.range(of: ".app/").map { String(bundle[..<$0.lowerBound]) + ".app" } ?? bundle
            outer[top, default: 0] += milliseconds
        }
        store.recordUsage(scope: Self.cpuScope, entries: outer.map { ($0.key, "", $0.value) }, at: now)
    }

    /// Open applications that have not been in front for `unusedApplicationHours` and used almost
    /// no CPU over the last hour. Listed for the user to decide; never acted on automatically.
    func unusedApplications(owners: [MemoryOwner], now: Date) -> [UnusedApplication] {
        guard applicationControl.isAvailable else { return [] }
        var known = lastActive()
        var changed = false
        let front = frontmostPID()
        let threshold = TimeInterval(settings.unusedApplicationHours) * 3600
        let keep = Set(settings.keepApplications.map { $0.lowercased() })
        let cpu = store.usageSeries(scope: Self.cpuScope, since: now.addingTimeInterval(-3900))
        var result: [UnusedApplication] = []
        for app in applicationControl.running() where app.isRegular {
            if app.pid == front || known[app.bundlePath] == nil {
                // In front now, or seen for the first time: the clock starts here.
                known[app.bundlePath] = now
                changed = true
                continue
            }
            guard let last = known[app.bundlePath], now.timeIntervalSince(last) >= threshold, !keep.contains(app.name.lowercased()) else { continue }
            guard let owner = owners.first(where: { $0.id == "app:\(app.bundlePath)" }), owner.footprintBytes >= 200 * Bytes.mb else { continue }
            var percent: Double?
            if let samples = cpu[app.bundlePath]?.samples, let first = samples.first, let latest = samples.last, latest.at.timeIntervalSince(first.at) >= 600 {
                percent = max(0, Double(latest.bytes - first.bytes) / 1000 / latest.at.timeIntervalSince(first.at) * 100)
            }
            // Busy in the background: it is being used, just not looked at.
            if let percent, percent >= 2 { continue }
            result.append(
                UnusedApplication(
                    bundlePath: app.bundlePath, name: app.name, pid: app.pid, footprintBytes: owner.footprintBytes, residentBytes: owner.residentBytes,
                    lastActive: last, cpuPercent: percent))
        }
        if changed { try? store.saveCodable(known.filter { now.timeIntervalSince($0.value) < 30 * 86_400 }, key: Self.lastActiveKey) }
        return result.sorted { $0.footprintBytes > $1.footprintBytes }
    }

    // MARK: Simulators

    /// Shuts a booted simulator down the way Xcode does. Only a person can ask.
    public func shutdownSimulator(udid: String, initiator: Initiator) async -> (done: Bool, note: String) {
        guard initiator == .user || initiator == .cli else { return (false, "Only you can have a simulator shut down.") }
        let liveState = await refreshLive()
        guard let simulator = liveState.simulators.first(where: { $0.udid == udid }) else { return (false, "That simulator is not booted.") }
        guard let shutdown = simulatorShutdown else { return (false, "simctl is not available.") }
        let done = await Task.detached(priority: .utility) { shutdown(udid) }.value
        store.appendAudit(
            AuditEntry(
                kind: .termination, initiator: initiator.rawValue, subject: "Simulator \(simulator.name)", outcome: done ? "shut down" : "shutdown failed",
                bytes: done ? simulator.footprintBytes : 0, detail: ["udid": udid, "held": Bytes.format(simulator.footprintBytes)]))
        await refreshLive()
        return (done, done ? "\(simulator.name) was shut down; it held \(Bytes.format(simulator.footprintBytes))." : "simctl could not shut \(simulator.name) down.")
    }
}
