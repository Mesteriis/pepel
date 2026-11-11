import Foundation

/// "Free memory": everything PEPEL can do to give memory back, in one pass.
///
/// There is no cache flushing and no memory ballooning here. Those change the "free" figure
/// without giving anything back that macOS would not hand over on demand anyway. Every step
/// stops something that really holds memory, goes through the same policy checks as when it is
/// done one by one, and the result is measured rather than estimated.
extension PepelEngine {
    public func reclaimPlan() async -> ReclaimPlan {
        let live = await refreshLive()
        var steps: [ReclaimStep] = []

        let abandoned = live.abandoned.filter { !$0.eligibility.isNever }
        if !abandoned.isEmpty {
            steps.append(
                ReclaimStep(
                    kind: .abandonedProcesses, title: "Abandoned developer processes",
                    detail: "Builds, tests and servers whose parent is gone and that have shown no activity.",
                    targets: abandoned.map { "\($0.process.name) (PID \($0.process.pid))" },
                    estimatedBytes: abandoned.reduce(0) { $0 + $1.subtreeFootprintBytes }, selectedByDefault: true))
        }

        let leftovers = live.leftovers.flatMap(\.processes).filter { !$0.eligibility.isNever }
        if !leftovers.isEmpty {
            steps.append(
                ReclaimStep(
                    kind: .appLeftovers, title: "Left running by applications that quit",
                    detail: "Helpers and child processes of applications that are no longer open.",
                    targets: leftovers.map { "\($0.process.name) (PID \($0.process.pid)), from \($0.leftoverOf ?? "an application")" },
                    estimatedBytes: leftovers.reduce(0) { $0 + $1.subtreeFootprintBytes }, selectedByDefault: true))
        }

        func describe(_ session: AgentSession) -> String {
            let project = session.projectID.map { ($0 as NSString).lastPathComponent } ?? "no project"
            let quiet = session.quietSince.map { ", quiet \(TimeFormat.age(Date().timeIntervalSince($0)))" } ?? ""
            return "\(session.kind.displayName) · \(project) (PID \(session.root.pid)\(quiet))"
        }
        let sessions = live.agentSessions.filter { !$0.isService }
        let sleeping = sessions.filter { $0.state == .sleeping }
        if !sleeping.isEmpty {
            steps.append(
                ReclaimStep(
                    kind: .sleepingAgents, title: "Sleeping agent sessions",
                    detail: "No sign of work for \(effectiveSettings.agentSleepMinutes) minutes. Ended with the tool servers they started; they can be resumed.",
                    targets: sleeping.map(describe), estimatedBytes: sleeping.reduce(0) { $0 + $1.footprintBytes }, selectedByDefault: true))
        }
        let idle = sessions.filter { $0.state == .idle }
        if !idle.isEmpty {
            steps.append(
                ReclaimStep(
                    kind: .idleAgents, title: "Idle agent sessions",
                    detail: "Not working right now, but quiet for less than \(effectiveSettings.agentSleepMinutes) minutes. One of them may be waiting for you.",
                    targets: idle.map(describe), estimatedBytes: idle.reduce(0) { $0 + $1.footprintBytes }, selectedByDefault: false))
        }

        // Suspending keeps everything, so it is offered for every quiet session whose application
        // is not the one in front.
        let front = frontmostPID()
        let processTree = ProcessTree(lastProcesses)
        let freezable = sessions.filter { session in
            guard session.state != .working, session.frozenSince == nil, session.activeBuildCount == 0, let root = processTree.process(session.root) else { return false }
            let owner = Self.ownerApp(of: root, tree: processTree)
            return owner != nil && owner?.pid != front
        }
        if !freezable.isEmpty {
            steps.append(
                ReclaimStep(
                    kind: .freezeAgents, title: "Suspend quiet agent sessions",
                    detail: "Paused, not ended: nothing is lost, and a session continues when its application comes to the front. macOS can then compress and swap out their memory first.",
                    targets: freezable.map(describe), estimatedBytes: 0, selectedByDefault: true))
        }

        let grown = live.growth.filter { $0.kind == .application }
        if !grown.isEmpty, applicationControl.isAvailable {
            steps.append(
                ReclaimStep(
                    kind: .grownApps, title: "Restart applications that have grown",
                    detail: "Asked to quit normally and opened again. An application may ask about unsaved changes; one that does not quit is left running.",
                    targets: grown.map { "\($0.name): \(Bytes.format($0.baselineBytes)) → \(Bytes.format($0.currentBytes)) since \(TimeFormat.ago($0.since))" },
                    estimatedBytes: grown.reduce(0) { $0 + $1.grownBytes }, selectedByDefault: false))
        }

        if !live.unusedApplications.isEmpty {
            steps.append(
                ReclaimStep(
                    kind: .unusedApps, title: "Quit applications you have not used",
                    detail: "Open, but not brought to the front for \(settings.unusedApplicationHours) hours and idle in the background. Asked to quit normally; one that does not quit is left running.",
                    targets: live.unusedApplications.map { "\($0.name) (\(Bytes.format($0.footprintBytes)), last used \(TimeFormat.ago($0.lastActive)))" },
                    estimatedBytes: live.unusedApplications.reduce(0) { $0 + $1.footprintBytes }, selectedByDefault: false))
        }

        if let containers = live.containers {
            let unused = containers.groups.filter { $0.projectID != nil && $0.agentSessions == 0 && !$0.stoppable.isEmpty }
            if !unused.isEmpty {
                steps.append(
                    ReclaimStep(
                        kind: .idleContainers, title: "Containers of projects no agent is working in",
                        detail: "Stopped, not removed. Frees memory inside the Docker VM; the Mac gets it back when the VM is restarted.",
                        targets: unused.map { "\($0.name) (\($0.stoppable.count) containers, \(Bytes.format($0.stoppable.reduce(0) { $0 + $1.memoryBytes })))" },
                        estimatedBytes: 0, selectedByDefault: true))
            }
            let working = sessions.filter { $0.state == .working }.count
            let wouldStop = unused.reduce(Int64(0)) { $0 + $1.stoppable.reduce(0) { $0 + $1.memoryBytes } }
            let returnable = containers.excessBytes + wouldStop
            if containers.product.lowercased().contains("docker desktop"), returnable >= 2 * Bytes.gb {
                steps.append(
                    ReclaimStep(
                        kind: .containerVM, title: "Restart the Docker VM",
                        detail: "All containers go down for about a minute and the ones still wanted are started again."
                            + (working > 0 ? " \(working) agent session\(working == 1 ? " is" : "s are") working right now and may be using them." : ""),
                        targets: ["Docker Desktop VM, charged \(Bytes.format(containers.hostFootprintBytes))"], estimatedBytes: returnable,
                        // On by default only when nobody is working and nothing kept would be restarted.
                        selectedByDefault: working == 0 && containers.kept.isEmpty))
            }
        }
        // Last, so it also clears what the steps above leave cached.
        let cached = live.telemetry.cachedFileBytes
        if fileCacheFlusher.isAvailable, cached >= Bytes.gb {
            steps.append(
                ReclaimStep(
                    kind: .fileCache, title: "Flush the file cache",
                    detail: "Turns cached file pages into free pages. "
                        + (fileCacheFlusher.hasPermission()
                            ? "Uses the permission you gave earlier, without a prompt."
                            : "Asks for your administrator password this once; after that PEPEL may flush without asking.")
                        + " It does not shrink what applications use, and macOS fills the cache again as files are read.",
                    targets: ["\(Bytes.format(cached)) of cached files become free"], estimatedBytes: 0, selectedByDefault: true))
        }
        return ReclaimPlan(steps: steps, telemetry: live.telemetry)
    }

    /// Carries out the selected steps. Each one is decided again by policy at this moment; a step
    /// policy refuses is reported, not forced.
    public func reclaim(_ selection: Set<String>, initiator: Initiator = .user) async -> ReclaimReport {
        let started = Date()
        let plan = await reclaimPlan()
        let before = plan.telemetry
        var results: [ReclaimStepResult] = []

        func terminate(_ identities: [ProcessIdentity], kind: ReclaimStepKind, title: String) async -> ReclaimStepResult {
            var done = 0
            var notes: [String] = []
            for identity in identities {
                switch await self.terminate(identity, confirmed: true, force: false, initiator: initiator) {
                case .completed(let report):
                    if report.exited { done += 1 } else { notes.append("\(report.name) (PID \(identity.pid)) did not exit.") }
                case .denied(let decision), .needsConfirmation(let decision):
                    notes.append("\(decision.target.process.name) (PID \(identity.pid)): \(decision.reasons.first ?? "refused").")
                case .notFound:
                    done += 1  // already gone
                }
            }
            return ReclaimStepResult(kind: kind, title: title, done: done, attempted: identities.count, notes: notes)
        }

        for step in plan.steps where selection.contains(step.id) {
            let live = self.live
            switch step.kind {
            case .abandonedProcesses:
                results.append(await terminate((live?.abandoned ?? []).filter { !$0.eligibility.isNever }.map(\.process.identity), kind: step.kind, title: step.title))
            case .appLeftovers:
                results.append(await terminate((live?.leftovers ?? []).flatMap(\.processes).filter { !$0.eligibility.isNever }.map(\.process.identity), kind: step.kind, title: step.title))
            case .sleepingAgents:
                results.append(await terminate((live?.agentSessions ?? []).filter { !$0.isService && $0.state == .sleeping }.map(\.root), kind: step.kind, title: step.title))
            case .idleAgents:
                // The user chose to end sessions that are idle but not yet asleep: for this pass
                // only, they are treated as asleep. Working sessions are never included.
                let idle = (live?.agentSessions ?? []).filter { !$0.isService && $0.state == .idle }
                manualSleepOverride = Dictionary(uniqueKeysWithValues: idle.map { ($0.root, $0.evidence + ["You asked PEPEL to free memory and included idle sessions."]) })
                results.append(await terminate(idle.map(\.root), kind: step.kind, title: step.title))
                manualSleepOverride = [:]
            case .freezeAgents:
                var done = 0
                var notes: [String] = []
                let candidates = (live?.agentSessions ?? []).filter { !$0.isService && $0.state != .working && $0.frozenSince == nil }
                for session in candidates {
                    guard let decision = await freeze(session.root, confirmed: true, initiator: initiator) else { continue }
                    if decision.verdict == .denied { notes.append("\(session.kind.displayName) (PID \(session.root.pid)): \(decision.reasons.first ?? "refused")") } else { done += 1 }
                }
                results.append(ReclaimStepResult(kind: step.kind, title: step.title, done: done, attempted: candidates.count, notes: notes))
            case .grownApps:
                var done = 0
                var notes: [String] = []
                let grown = (live?.growth ?? []).filter { $0.kind == .application }
                for growth in grown {
                    guard let report = await performApplication(.restart, bundlePath: String(growth.id.dropFirst(4)), confirmed: true, initiator: initiator) else { continue }
                    if report.quit { done += 1 }
                    notes.append(report.quit ? "\(growth.name): \(Bytes.format(report.footprintBefore)) → \(Bytes.format(report.footprintAfter))." : report.note)
                }
                results.append(ReclaimStepResult(kind: step.kind, title: step.title, done: done, attempted: grown.count, notes: notes))
            case .unusedApps:
                var done = 0
                var notes: [String] = []
                let unused = live?.unusedApplications ?? []
                for app in unused {
                    guard let report = await performApplication(.quit, bundlePath: app.bundlePath, confirmed: true, initiator: initiator) else { continue }
                    if report.quit { done += 1 } else { notes.append(report.note) }
                }
                results.append(ReclaimStepResult(kind: step.kind, title: step.title, done: done, attempted: unused.count, notes: notes))
            case .idleContainers:
                var done = 0, attempted = 0
                var notes: [String] = []
                for group in (live?.containers?.groups ?? []) where group.projectID != nil && group.agentSessions == 0 && !group.stoppable.isEmpty {
                    attempted += group.stoppable.count
                    if let result = await stopContainers(groupID: group.id, confirmed: true, initiator: initiator) {
                        done += result.report?.stopped.count ?? 0
                        if result.report == nil { notes.append("\(group.name): \(result.decision.reasons.first ?? "refused").") }
                        if let failed = result.report?.failed, !failed.isEmpty { notes.append("Not stopped: \(failed.joined(separator: ", ")).") }
                    }
                }
                results.append(ReclaimStepResult(kind: step.kind, title: step.title, done: done, attempted: attempted, notes: notes))
            case .fileCache:
                if let denial = policy.cacheFlushDenial(initiator: initiator) {
                    results.append(ReclaimStepResult(kind: step.kind, title: step.title, done: 0, attempted: 1, notes: [denial]))
                    break
                }
                let flusher = fileCacheFlusher
                let read = readTelemetry
                let cachedBefore = read()
                let outcome = await Task.detached(priority: .userInitiated) { flusher.flush() }.value
                let cachedAfter = read()
                var notes: [String] = []
                switch outcome {
                case .flushed:
                    notes.append("Cached files \(Bytes.format(cachedBefore.cachedFileBytes)) → \(Bytes.format(cachedAfter.cachedFileBytes)), free \(Bytes.format(cachedBefore.freeBytes)) → \(Bytes.format(cachedAfter.freeBytes)).")
                case .cancelled: notes.append("Not flushed: the administrator prompt was dismissed.")
                case .failed(let reason): notes.append("Not flushed: \(reason)")
                case .unavailable: notes.append("Not flushed: purge is not available.")
                }
                results.append(ReclaimStepResult(kind: step.kind, title: step.title, done: outcome == .flushed ? 1 : 0, attempted: 1, notes: notes))
            case .containerVM:
                if let result = await refreshContainerVM(confirmed: true, initiator: initiator) {
                    if let report = result.report {
                        var notes = ["Charged for the VM: \(Bytes.format(report.hostFootprintBefore)) before, \(Bytes.format(report.hostFootprintAfter)) after."]
                        if !report.missing.isEmpty { notes.append("Did not come back: \(report.missing.joined(separator: ", ")).") }
                        results.append(ReclaimStepResult(kind: step.kind, title: step.title, done: report.restarted ? 1 : 0, attempted: 1, notes: notes))
                    } else {
                        results.append(ReclaimStepResult(kind: step.kind, title: step.title, done: 0, attempted: 1, notes: result.decision.reasons))
                    }
                }
            }
        }

        // Let the system settle before the "after" reading.
        try? await Task.sleep(for: .seconds(3))
        let after = await refreshLive().telemetry
        let report = ReclaimReport(startedAt: started, finishedAt: Date(), before: before, after: after, results: results)
        store.appendAudit(
            AuditEntry(
                kind: .termination, initiator: initiator.rawValue, subject: "Free memory",
                outcome: "memory used \(Bytes.format(before.memoryUsedBytes)) → \(Bytes.format(after.memoryUsedBytes))", bytes: max(0, report.freedBytes),
                detail: [
                    "steps": results.map { "\($0.title): \($0.done)/\($0.attempted)" }.joined(separator: "; "),
                    "pressure": "\(before.pressure.rawValue) → \(after.pressure.rawValue)",
                    "swap": "\(Bytes.format(before.swapUsedBytes)) → \(Bytes.format(after.swapUsedBytes))",
                    "compressed": "\(Bytes.format(before.compressedBytes)) → \(Bytes.format(after.compressedBytes))",
                    "free": "\(Bytes.format(before.freeBytes)) → \(Bytes.format(after.freeBytes))",
                    "cachedFiles": "\(Bytes.format(before.cachedFileBytes)) → \(Bytes.format(after.cachedFileBytes))",
                ]))
        return report
    }

    /// Whether flushing the file cache is possible here, and whether it would prompt.
    public func fileCachePermission() -> (available: Bool, granted: Bool) {
        (fileCacheFlusher.isAvailable, fileCacheFlusher.isAvailable && fileCacheFlusher.hasPermission())
    }

    /// Removes the standing permission to flush the file cache. Only a person can ask for this.
    public func revokeFileCachePermission(initiator: Initiator) async -> FileCacheFlushOutcome {
        guard policy.cacheFlushDenial(initiator: initiator) == nil else { return .failed("Only you can change this permission.") }
        let flusher = fileCacheFlusher
        let outcome = await Task.detached(priority: .userInitiated) { flusher.revoke() }.value
        if outcome == .flushed {
            store.appendAudit(AuditEntry(kind: .termination, initiator: initiator.rawValue, subject: "File cache permission", outcome: "removed"))
        }
        return outcome
    }
}
