import Foundation

public struct DockerCleanResult: Sendable {
    /// Why nothing was done, when policy refused.
    public var denial: String?
    public var plan: DockerCleanupPlan?
    public var report: DockerCleanupReport?
}

/// Disk cleaning that goes beyond single artifacts: what Docker keeps, with ages.
extension PepelEngine {
    nonisolated func dockerDisk() -> DockerDisk {
        if let run = containerRunner { return DockerDisk(run: run) }
        return DockerDisk(tools: tools, home: paths.home)
    }

    /// Compose projects an agent session is working in right now, and what must be left alone.
    func dockerExclusions() -> (keep: Set<String>, active: Set<String>) {
        let active = Set((live?.containers?.groups ?? []).filter { $0.agentSessions > 0 }.map(\.id))
        return (Set(settings.keepContainers), active)
    }

    /// Asks Docker what it keeps on disk (a few seconds) and what a cleanup would remove.
    public func dockerCleanupPlan(days: Int? = nil) async -> (report: DockerDiskReport, plan: DockerCleanupPlan)? {
        if live == nil { await refreshLive() }
        let disk = dockerDisk()
        guard let report = await Task.detached(priority: .utility, operation: { disk.report() }).value else { return nil }
        lastDockerDisk = report
        let exclusions = dockerExclusions()
        return (report, DockerCleanupPlan.make(report, days: days ?? settings.dockerUnusedDays, keep: exclusions.keep, activeProjects: exclusions.active))
    }

    /// Removes what the plan names for the chosen kinds, then hands the freed space back to the Mac.
    public func cleanDocker(kinds: Set<DockerCleanKind>, days: Int? = nil, confirmed: Bool, initiator: Initiator, compact: Bool = true) async -> DockerCleanResult {
        if let denial = policy.dockerCleanDenial(kinds: kinds, confirmed: confirmed, initiator: initiator, settings: settings) {
            store.appendAudit(AuditEntry(kind: .cleanupDenied, initiator: initiator.rawValue, subject: "Docker cleanup", outcome: denial))
            return DockerCleanResult(denial: denial)
        }
        // Decided again from a reading taken now, not from the one that was shown.
        guard let (_, plan) = await dockerCleanupPlan(days: days) else { return DockerCleanResult(denial: "Docker did not answer.") }
        let disk = dockerDisk()
        let report = await Task.detached(priority: .utility) { disk.clean(plan, kinds: kinds, compact: compact) }.value
        let freed = max(report.freedOnDisk, 0)
        store.appendAudit(
            AuditEntry(
                kind: .cleanup, initiator: initiator.rawValue, subject: "Docker: " + report.steps.map { "\($0.kind.title.lowercased()) \($0.removed)/\($0.attempted)" }.joined(separator: ", "),
                outcome: "removed", bytes: max(freed, report.dockerBytesBefore - report.dockerBytesAfter),
                detail: [
                    "unusedForDays": "\(plan.days)", "dockerBefore": Bytes.format(report.dockerBytesBefore), "dockerAfter": Bytes.format(report.dockerBytesAfter),
                    "diskImageBefore": Bytes.format(report.diskImageBefore), "diskImageAfter": Bytes.format(report.diskImageAfter), "compact": report.compactNote,
                ]))
        lastDockerDisk = nil
        return DockerCleanResult(plan: plan, report: report)
    }

    /// At most once a day: what can be rebuilt or pulled again and has not been used for the configured time.
    func autoCleanDocker(now: Date = Date()) async -> DockerCleanupReport? {
        guard settings.dockerAutoClean, live?.containers != nil || containerRunner != nil else { return nil }
        let last = store.value("docker.lastAutoClean").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
        guard now.timeIntervalSince(last) >= 20 * 3600 else { return nil }
        try? store.setValue(String(now.timeIntervalSince1970), for: "docker.lastAutoClean")
        guard let (_, plan) = await dockerCleanupPlan(), plan.reproducibleBytes >= Bytes.gb else { return nil }
        return await cleanDocker(kinds: [.containers, .images, .buildCache, .networks], confirmed: false, initiator: .automatic).report
    }

    /// Trims the Docker VM's filesystem so its disk image on the Mac shrinks.
    public nonisolated func dockerDiskCompact() -> (done: Bool, note: String) { dockerDisk().compact() }
}
