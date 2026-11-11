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
}
