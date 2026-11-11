import Foundation
import PEPELCore
import PEPELPersistence

public struct ContainerStopDecision: Codable, Sendable, Hashable {
    public var group: ContainerGroup
    public var verdict: CleanupVerdict
    public var reasons: [String]
    public var warnings: [String]
}

/// A container stop the policy engine cleared. Cannot be built outside this module.
public struct ApprovedContainerStop: Sendable {
    public let group: ContainerGroup
    public let initiator: Initiator

    init(group: ContainerGroup, initiator: Initiator) {
        self.group = group
        self.initiator = initiator
    }
}

extension CleanupPolicyEngine {
    /// Whether the containers of one compose project may be stopped. Stopping keeps containers
    /// and volumes; it is the reversible end of what Docker offers, and the only one PEPEL uses.
    public func evaluateContainerStop(
        _ group: ContainerGroup, initiator: Initiator, settings: PepelSettings, protections: [ProtectionRule], leases: [ResourceLease],
        now: Date = Date()
    ) -> ContainerStopDecision {
        var denials: [String] = []
        var confirmations: [String] = []
        var warnings = ["Containers and their volumes are kept; `docker compose start` brings them back."]

        if group.containers.isEmpty { denials.append("No running containers in this group.") }
        let kept = group.containers.filter(\.isKept)
        if !group.containers.isEmpty, kept.count == group.containers.count {
            denials.append("Every container here is marked to be left running.")
        } else if !kept.isEmpty {
            warnings.append("\(kept.count) container\(kept.count == 1 ? " is" : "s are") marked to be left running and will not be stopped: \(kept.map(\.name).joined(separator: ", ")).")
        }
        if let projectID = group.projectID {
            if protections.contains(where: { $0.kind == .project && PathUtil.isInsideIgnoringCase(projectID, root: $0.value) }) {
                denials.append("Its project is excluded by one of your protection rules.")
            }
            if let lease = leases.first(where: { $0.isActive(at: now) && $0.covers(projectID) }) {
                denials.append("Leased by \(lease.owner) until \(lease.expiresAt.formatted(date: .omitted, time: .shortened)).")
            }
        }
        if group.agentSessions > 0 {
            let text = "\(group.agentSessions) agent session\(group.agentSessions == 1 ? " is" : "s are") running in this project."
            if initiator == .automatic { denials.append(text) } else { confirmations.append(text) }
        }

        switch initiator {
        case .agent:
            denials.append("Agents cannot have containers stopped.")
        case .automatic:
            if !settings.stopContainersOfIdleProjects { denials.append("Stopping containers of idle projects is not enabled.") }
            if group.projectID == nil {
                // Without a project there is nothing to tie the containers to an agent's work.
                denials.append("These containers are not tied to a known project.")
            } else if let idleSince = group.idleSince {
                let grace = TimeInterval(settings.projectIdleGraceMinutes) * 60
                if now.timeIntervalSince(idleSince) < grace {
                    denials.append("The project has been without an agent session for \(TimeFormat.age(now.timeIntervalSince(idleSince))); the threshold is \(settings.projectIdleGraceMinutes) minutes.")
                }
            } else if group.agentSessions == 0 {
                denials.append("PEPEL has not observed this project long enough.")
            }
        case .user, .cli:
            confirmations.append("Stopping always needs your confirmation when requested by hand.")
            if group.projectID == nil { warnings.append("These containers are not tied to a known project.") }
        }
        let verdict: CleanupVerdict = !denials.isEmpty ? .denied : !confirmations.isEmpty ? .needsConfirmation : .allowed
        return ContainerStopDecision(group: group, verdict: verdict, reasons: denials.isEmpty ? confirmations : denials, warnings: warnings)
    }

    public func approveContainerStop(_ decision: ContainerStopDecision, confirmed: Bool, initiator: Initiator) -> ApprovedContainerStop? {
        switch decision.verdict {
        case .denied: return nil
        case .needsConfirmation: guard confirmed, initiator == .user || initiator == .cli else { return nil }
        case .allowed: break
        }
        return ApprovedContainerStop(group: decision.group, initiator: initiator)
    }
}

public struct ContainerStopReport: Codable, Sendable {
    public var groupName: String
    public var stopped: [String]
    public var failed: [String]
    /// What the containers used, by the runtime's accounting, before they were stopped.
    public var memoryBytes: Int64
}

/// Stops containers through `docker stop`. Never `rm`, never `down`, never anything on volumes.
public struct ContainerStopper: Sendable {
    public typealias Runner = @Sendable (_ arguments: [String], _ timeout: TimeInterval) -> (status: Int32, output: String)?

    let run: Runner
    let store: PepelStore?

    public init(tools: ToolRunner, store: PepelStore?) {
        run = { arguments, timeout in tools.run("docker", arguments, timeout: timeout) }
        self.store = store
    }

    public init(store: PepelStore?, run: @escaping Runner) {
        self.run = run
        self.store = store
    }

    /// Freezes the containers in place. Nothing is lost; they continue with `unpause`.
    public func pause(_ approved: ApprovedContainerStop) -> ContainerStopReport {
        let names = approved.group.pausable.map(\.name)
        var report = ContainerStopReport(groupName: approved.group.name, stopped: [], failed: [], memoryBytes: approved.group.pausable.reduce(0) { $0 + $1.memoryBytes })
        guard !names.isEmpty else { return report }
        if let result = run(["pause"] + names, 60) {
            let printed = Set(result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
            report.stopped = names.filter { printed.contains($0) }
            report.failed = names.filter { !printed.contains($0) }
        } else {
            report.failed = names
        }
        store?.appendAudit(
            AuditEntry(
                kind: .container, initiator: approved.initiator.rawValue, subject: "\(approved.group.name) (\(names.count) containers)",
                outcome: report.failed.isEmpty ? "paused" : "paused \(report.stopped.count) of \(names.count)",
                detail: ["containers": names.joined(separator: ", "), "project": approved.group.projectID ?? "", "failed": report.failed.joined(separator: ", ")]))
        return report
    }

    /// Lets paused containers continue. Returns the names that did.
    public func unpause(_ names: [String], group: String, reason: String) -> [String] {
        guard !names.isEmpty, let result = run(["unpause"] + names, 60) else { return [] }
        let printed = Set(result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        let resumed = names.filter { printed.contains($0) }
        store?.appendAudit(
            AuditEntry(
                kind: .container, initiator: "engine", subject: "\(group) (\(names.count) containers)", outcome: resumed.count == names.count ? "resumed" : "resumed \(resumed.count) of \(names.count)",
                detail: ["containers": names.joined(separator: ", "), "reason": reason]))
        return resumed
    }

    public func stop(_ approved: ApprovedContainerStop) -> ContainerStopReport {
        // Containers on the keep list are never part of a stop, whoever asked.
        let names = approved.group.stoppable.map(\.name)
        var report = ContainerStopReport(
            groupName: approved.group.name, stopped: [], failed: [], memoryBytes: approved.group.stoppable.reduce(0) { $0 + $1.memoryBytes })
        guard !names.isEmpty else { return report }
        // `docker stop` prints the name of each container it stopped, one per line.
        if let result = run(["stop"] + names, 180) {
            let printed = Set(result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
            report.stopped = names.filter { printed.contains($0) }
            report.failed = names.filter { !printed.contains($0) }
        } else {
            report.failed = names
        }
        store?.appendAudit(
            AuditEntry(
                kind: .container, initiator: approved.initiator.rawValue, subject: "\(approved.group.name) (\(names.count) containers)",
                outcome: report.failed.isEmpty ? "stopped" : "stopped \(report.stopped.count) of \(names.count)", bytes: 0,
                detail: [
                    "containers": names.joined(separator: ", "), "memoryInsideVM": Bytes.format(report.memoryBytes),
                    "project": approved.group.projectID ?? "", "failed": report.failed.joined(separator: ", "),
                ]))
        return report
    }
}

// MARK: - Restarting the container VM

public struct VMRefreshDecision: Codable, Sendable, Hashable {
    public var verdict: CleanupVerdict
    public var reasons: [String]
    public var warnings: [String]
    public var containers: [String]
}

/// A VM restart the policy engine cleared.
public struct ApprovedVMRefresh: Sendable {
    public let containers: [String]
    public let initiator: Initiator

    init(containers: [String], initiator: Initiator) {
        self.containers = containers
        self.initiator = initiator
    }
}

extension CleanupPolicyEngine {
    /// Restarting the VM is the only thing that gives its memory back to the Mac, and it takes
    /// every container down for a minute or two. By hand it always asks. On its own PEPEL does it
    /// at most once a day, at night, and only in a quiet moment.
    /// - Parameters:
    ///   - lastRefresh: when the VM was last restarted through PEPEL, if ever.
    ///   - userIdleSeconds: time since the last keyboard or pointer input.
    public func evaluateVMRefresh(
        _ report: ContainerReport, workingSessions: Int, initiator: Initiator, settings: PepelSettings = PepelSettings(),
        lastRefresh: Date? = nil, userIdleSeconds: TimeInterval = 0, pressure: MemoryPressureLevel = .normal, now: Date = Date(),
        calendar: Calendar = .current
    ) -> VMRefreshDecision {
        var denials: [String] = []
        var confirmations: [String] = []
        var warnings: [String] = []
        let names = report.groups.flatMap(\.containers).map(\.name)

        if !report.product.lowercased().contains("docker desktop") {
            denials.append("Restarting the VM is only supported for Docker Desktop; this is \(report.product).")
        }
        switch initiator {
        case .agent:
            denials.append("Agents cannot have the container VM restarted.")
        case .automatic:
            if !settings.refreshContainerVMNightly || settings.paused { denials.append("The nightly VM restart is not enabled.") }
            let sinceLast = lastRefresh.map { now.timeIntervalSince($0) }
            // Under memory pressure the restart does not wait for the night, but still not more
            // often than every six hours, and every other condition below stays.
            let urgent = settings.adaptToMemoryPressure && pressure != .normal
            if let sinceLast, sinceLast < (urgent ? 6 : 20) * 3600 {
                denials.append("The VM was restarted \(TimeFormat.age(sinceLast)) ago; at most \(urgent ? "every six hours under memory pressure" : "once a day").")
            }
            // In its night window, or catching up after a night the Mac slept through.
            let hour = calendar.component(.hour, from: now)
            let inWindow = (0..<2).contains((hour - settings.vmRefreshHour + 24) % 24)
            let overdue = (sinceLast ?? .infinity) > 30 * 3600 && userIdleSeconds >= 20 * 60
            if !inWindow && !overdue && !urgent {
                denials.append("Outside the night window (\(settings.vmRefreshHour):00–\((settings.vmRefreshHour + 2) % 24):00) and not overdue.")
            }
            if report.excessBytes < settings.vmRefreshMinimumExcessBytes {
                denials.append("Only \(Bytes.format(report.excessBytes)) would come back; the threshold is \(Bytes.format(settings.vmRefreshMinimumExcessBytes)).")
            }
            if workingSessions > 0 {
                denials.append("\(workingSessions) agent session\(workingSessions == 1 ? " is" : "s are") working right now.")
            }
            if !report.kept.isEmpty {
                denials.append("A container marked to be left running is up: \(report.kept.map(\.name).joined(separator: ", ")). A VM restart cannot spare it.")
            }
        case .user, .cli:
            confirmations.append("All \(names.count) running containers go down for a minute or two and are started again afterwards.")
            if !report.kept.isEmpty {
                warnings.append("\(report.kept.count) container\(report.kept.count == 1 ? "" : "s") marked to be left running will be restarted too; a VM restart cannot spare any: \(report.kept.map(\.name).joined(separator: ", ")).")
            }
            if workingSessions > 0 {
                warnings.append("\(workingSessions) agent session\(workingSessions == 1 ? " is" : "s are") working right now and may be using these containers.")
            }
        }
        warnings.append("Data in volumes is kept. Work a container is doing at that moment is interrupted.")
        warnings.append("About \(Bytes.format(report.excessBytes)) is charged to the Mac beyond what the containers use; how much of it returns is measured afterwards, not promised.")
        let verdict: CleanupVerdict = !denials.isEmpty ? .denied : !confirmations.isEmpty ? .needsConfirmation : .allowed
        return VMRefreshDecision(verdict: verdict, reasons: denials.isEmpty ? confirmations : denials, warnings: warnings, containers: names)
    }

    public func approveVMRefresh(_ decision: VMRefreshDecision, confirmed: Bool, initiator: Initiator) -> ApprovedVMRefresh? {
        switch decision.verdict {
        case .denied: return nil
        case .needsConfirmation: guard confirmed, initiator == .user || initiator == .cli else { return nil }
        case .allowed: guard initiator == .automatic else { return nil }
        }
        return ApprovedVMRefresh(containers: decision.containers, initiator: initiator)
    }
}

public struct VMRefreshReport: Codable, Sendable {
    public var restarted: Bool
    /// Containers that were running before and are running again.
    public var back: [String]
    /// Containers that were running before and could not be started again.
    public var missing: [String]
    public var steps: [String]
    public var hostFootprintBefore: Int64 = 0
    public var hostFootprintAfter: Int64 = 0

    public var returnedBytes: Int64 { hostFootprintBefore - hostFootprintAfter }
}

/// Restarts Docker Desktop and brings back exactly the containers that were running.
public struct ContainerVMRefresher: Sendable {
    public typealias Runner = ContainerStopper.Runner

    let run: Runner
    let store: PepelStore?
    public var pollInterval: Duration = .seconds(3)
    public var readyTimeout: TimeInterval = 240

    public init(tools: ToolRunner, store: PepelStore?) {
        run = { arguments, timeout in tools.run("docker", arguments, timeout: timeout) }
        self.store = store
    }

    public init(store: PepelStore?, run: @escaping Runner) {
        self.run = run
        self.store = store
    }

    private func running() -> Set<String>? {
        guard let result = run(["ps", "--format", "{{.Names}}"], 10), result.status == 0 else { return nil }
        return Set(result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// - Parameter whileStopped: runs between stopping and starting Docker Desktop (used to
    ///   change its settings, which it only reads at start). Returns an error text, or nil.
    public func refresh(_ approved: ApprovedVMRefresh, whileStopped: (@Sendable () -> String?)? = nil) async -> VMRefreshReport {
        var report = VMRefreshReport(restarted: false, back: [], missing: [], steps: [])
        // The list is taken again right before the restart: it is what must come back.
        let before = running() ?? Set(approved.containers)
        report.steps.append("\(before.count) containers were running.")

        if let whileStopped {
            guard let stop = run(["desktop", "stop"], 300), stop.status == 0 else {
                report.steps.append("`docker desktop stop` failed; nothing was changed.")
                record(report, initiator: approved.initiator)
                return report
            }
            report.steps.append("Docker Desktop was stopped.")
            // Whatever happens to the change, Docker is started again.
            report.steps.append(whileStopped().map { "The change was not made: \($0)" } ?? "The change was written.")
            guard let start = run(["desktop", "start"], 300), start.status == 0 else {
                report.steps.append("`docker desktop start` failed; start Docker Desktop yourself. Containers were not started.")
                report.missing = before.sorted()
                record(report, initiator: approved.initiator)
                return report
            }
            report.restarted = true
            report.steps.append("Docker Desktop was started.")
        } else {
            guard let restart = run(["desktop", "restart"], 300), restart.status == 0 else {
                report.steps.append("`docker desktop restart` failed; nothing was changed.")
                report.missing = []
                record(report, initiator: approved.initiator)
                return report
            }
            report.restarted = true
            report.steps.append("Docker Desktop was restarted.")
        }

        let deadline = ContinuousClock.now + .seconds(readyTimeout)
        var now = running()
        while now == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: pollInterval)
            now = running()
        }
        guard let after = now else {
            report.steps.append("Docker did not answer within \(Int(readyTimeout)) seconds; containers were not started.")
            report.missing = before.sorted()
            record(report, initiator: approved.initiator)
            return report
        }
        // Containers with a restart policy are back on their own; the rest are started here.
        let toStart = before.subtracting(after).sorted()
        report.steps.append("\(before.intersection(after).count) came back on their own; starting \(toStart.count).")
        if !toStart.isEmpty { _ = run(["start"] + toStart, 300) }
        let final = running() ?? after
        report.back = before.intersection(final).sorted()
        report.missing = before.subtracting(final).sorted()
        report.steps.append(report.missing.isEmpty ? "All \(report.back.count) containers are running again." : "\(report.missing.count) did not start: \(report.missing.joined(separator: ", ")).")
        record(report, initiator: approved.initiator)
        return report
    }

    private func record(_ report: VMRefreshReport, initiator: Initiator) {
        store?.appendAudit(
            AuditEntry(
                kind: .container, initiator: initiator.rawValue, subject: "Docker Desktop VM",
                outcome: report.restarted ? (report.missing.isEmpty ? "restarted" : "restarted, \(report.missing.count) containers not back") : "restart failed",
                detail: ["steps": report.steps.joined(separator: " "), "missing": report.missing.joined(separator: ", ")]))
    }
}

extension CleanupPolicyEngine {
    /// Only a person starts a flush, also once the standing permission exists.
    /// Returns why it is refused, or nil when it may go ahead.
    public func cacheFlushDenial(initiator: Initiator) -> String? {
        switch initiator {
        case .user, .cli: return nil
        case .agent: return "Agents cannot have the file cache flushed."
        case .automatic: return "The file cache is only flushed when you ask. macOS gives cached memory up by itself under pressure; flushing on a timer would only slow file access."
        }
    }
}

// MARK: - VM memory limit

public struct VMLimitDecision: Codable, Sendable, Hashable {
    public var newLimitBytes: Int64
    public var currentLimitBytes: Int64
    public var verdict: CleanupVerdict
    public var reasons: [String]
    public var warnings: [String]
}

/// A new VM memory limit the policy engine cleared; cannot be built elsewhere.
public struct ApprovedVMLimit: Sendable {
    public let bytes: Int64
    init(bytes: Int64) { self.bytes = bytes }
}

extension CleanupPolicyEngine {
    /// Lowering the VM's memory limit is what keeps it from growing back; restarting alone only
    /// resets it. A limit too low gets containers killed inside the VM, so the floor is tied to
    /// the most they have been seen to use. Only a person can change it.
    public func evaluateVMLimit(_ report: ContainerReport, newLimitBytes: Int64, physicalMemoryBytes: Int64, initiator: Initiator) -> VMLimitDecision {
        var denials: [String] = []
        var confirmations: [String] = []
        var warnings: [String] = []
        if !report.product.lowercased().contains("docker desktop") { denials.append("The memory limit can only be changed for Docker Desktop; this is \(report.product).") }
        if initiator == .agent || initiator == .automatic { denials.append("Only you can change the VM's memory limit.") }
        if abs(newLimitBytes - report.vmLimitBytes) < (256 << 20) { denials.append("The limit is already \(Bytes.format(report.vmLimitBytes)).") }
        if newLimitBytes < report.minimumLimitBytes {
            denials.append(
                "The containers have used up to \(Bytes.format(max(report.usedByContainersBytes, report.peakUsedBytes))); below \(Bytes.format(report.minimumLimitBytes)) Linux would start killing them for lack of memory.")
        }
        if physicalMemoryBytes > 0, newLimitBytes > physicalMemoryBytes { denials.append("This Mac has \(Bytes.format(physicalMemoryBytes)) of memory.") }
        let names = report.groups.flatMap(\.containers).count
        confirmations.append("Docker Desktop is stopped and started again with the new limit; \(names) running container\(names == 1 ? " goes" : "s go") down for a minute or two and \(names == 1 ? "is" : "are") started again.")
        if newLimitBytes > report.vmLimitBytes { warnings.append("This raises the limit: the VM may grow to \(Bytes.format(newLimitBytes)).") }
        if report.peakUsedBytes == 0 { warnings.append("PEPEL has only today's reading of what the containers use; a busier day may need more.") }
        let verdict: CleanupVerdict = !denials.isEmpty ? .denied : .needsConfirmation
        return VMLimitDecision(
            newLimitBytes: newLimitBytes, currentLimitBytes: report.vmLimitBytes, verdict: verdict, reasons: denials.isEmpty ? confirmations : denials, warnings: warnings)
    }

    public func approveVMLimit(_ decision: VMLimitDecision, confirmed: Bool, initiator: Initiator) -> ApprovedVMLimit? {
        guard decision.verdict == .needsConfirmation, confirmed, initiator == .user || initiator == .cli else { return nil }
        return ApprovedVMLimit(bytes: decision.newLimitBytes)
    }
}
