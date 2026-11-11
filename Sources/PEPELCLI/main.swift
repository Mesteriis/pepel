import Foundation
import PEPELEngine

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
let environment = ProcessInfo.processInfo.environment
// PEPEL_HOME / PEPEL_SUPPORT_DIR point the CLI at a fixture tree instead of the real home.
let appPaths = AppPaths(home: environment["PEPEL_HOME"] ?? NSHomeDirectory(), supportDirectory: environment["PEPEL_SUPPORT_DIR"])

if ["help", "--help", "-h"].contains(arguments.command) {
    print(Out.help)
    exit(0)
}

let engine: PepelEngine
do {
    engine = try PepelEngine(paths: appPaths)
} catch {
    Out.error("cannot open PEPEL's database: \(error)")
    exit(1)
}

/// Uses the last scan when it is recent, otherwise scans now.
func currentStorage(maxAge: TimeInterval = 3600, force: Bool = false) async -> StorageState {
    if !force, let storage = await engine.storage, Date().timeIntervalSince(storage.scan.finishedAt) < maxAge {
        await engine.reevaluateStorage()
        return await engine.storage ?? storage
    }
    let showProgress = isatty(STDERR_FILENO) != 0 && !arguments.json
    let state = await engine.scan { progress in
        guard showProgress else { return }
        let counter = progress.total > 0 ? " \(progress.completed)/\(progress.total)" : ""
        FileHandle.standardError.write(Data("\r\u{1B}[K\(progress.phase)\(counter)".utf8))
    }
    if showProgress { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
    return state
}

func size(_ item: StorageItem) -> String {
    (item.size?.isApproximate ?? false ? "≤ " : "") + Bytes.format(item.reclaimableBytes)
}

func growthText(_ figure: GrowthFigure?) -> String {
    guard let figure else { return "no history yet" }
    return Bytes.formatDelta(figure.deltaBytes) + (figure.coversWindow ? "" : " (over the last \(TimeFormat.age(figure.actualSpan)); history is shorter than the window)")
}

func printPlan(_ plan: CleanupPlan, home: String) {
    let order: [CleanupVerdict] = [.allowed, .needsConfirmation, .denied]
    let titles: [CleanupVerdict: String] = [.allowed: "SAFE — can be cleaned", .needsConfirmation: "REVIEW — needs your decision", .denied: "BLOCKED — will not be touched"]
    for verdict in order {
        let group = plan.decisions.filter { $0.verdict == verdict }.sorted { $0.item.reclaimableBytes > $1.item.reclaimableBytes }
        guard !group.isEmpty else { continue }
        print("\n\(titles[verdict]!)  (\(group.count) items, up to \(Bytes.format(plan.bytes(verdict))))")
        Out.table(
            ["SIZE", "ACTION", "ITEM", "PATH", "WHY"],
            group.prefix(arguments.flags.contains("all") ? 10_000 : 40).map {
                [size($0.item), verdict == .denied ? "—" : $0.action.summary, Out.truncate($0.item.title, 34), Out.truncate(PathUtil.display($0.item.path, home: home), 60), $0.reasons.first ?? $0.item.safetyReason]
            })
        if group.count > 40, !arguments.flags.contains("all") { print("… \(group.count - 40) more (use --all)") }
    }
}

func printReport(_ report: CleanupReport) {
    for outcome in report.outcomes {
        let text: String
        switch outcome.status {
        case .removed: text = "removed"
        case .trashed: text = "moved to Trash"
        case .toolRan: text = "cleaned by tool"
        case .wouldApply: text = "would: \(outcome.action.summary.lowercased())"
        case .skipped(let reason): text = "skipped — \(reason)"
        case .failed(let reason): text = "FAILED — \(reason)"
        }
        let place = outcome.path.hasPrefix("tool://") ? "" : "  " + Out.truncate(PathUtil.display(outcome.path, home: appPaths.home), 64)
        print("  \(Bytes.format(outcome.estimatedBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(Out.truncate(outcome.title, 34).padding(toLength: 34, withPad: " ", startingAt: 0)) \(text)\(place)")
    }
    if report.dryRun {
        print("\nDry run: nothing was removed. Up to \(Bytes.format(report.estimatedBytes)) would be affected.")
    } else {
        print("\n\(report.succeededCount) of \(report.outcomes.count) items cleaned (estimated up to \(Bytes.format(report.estimatedBytes))).")
        print("Observed change in available disk space: \(Bytes.formatDelta(report.observedFreedBytes)). Trashed items free space only when the Trash is emptied.")
    }
}

switch arguments.command {
case "status":
    let summary = await engine.statusSummary()
    if arguments.json { Out.json(summary); break }
    let live = await engine.live
    print("Disk        \(Bytes.format(summary.diskAvailableBytes)) available of \(Bytes.format(summary.diskTotalBytes))")
    if let reclaimable = summary.reclaimableBytes, let scanned = summary.lastScan {
        print("Reclaimable \(summary.reclaimableIsApproximate ? "up to " : "")\(Bytes.format(reclaimable))  (scanned \(TimeFormat.ago(scanned)))")
    } else {
        print("Reclaimable not scanned yet — run `pepel scan`")
    }
    print("Memory      pressure \(summary.memoryPressure.rawValue), swap \(Bytes.format(summary.swapUsedBytes)), compressed \(Bytes.format(live?.telemetry.compressedBytes ?? 0))")
    print("Builds      \(summary.activeBuilds) active")
    print("Processes   \(summary.abandonedProcesses) abandoned candidate\(summary.abandonedProcesses == 1 ? "" : "s"), \(summary.agentSessions) agent session\(summary.agentSessions == 1 ? "" : "s")")
    print("Growth 24h  \(growthText(engine.store.diskGrowth(window: 86_400)))")
    for alert in await engine.alerts() { print("! \(alert.title): \(alert.message)") }

case "scan":
    let state = await currentStorage(force: true)
    if arguments.json { Out.json(state); break }
    let seconds = state.scan.finishedAt.timeIntervalSince(state.scan.startedAt)
    print("Scanned \(state.items.count) artifacts in \(state.projects.count) projects in \(String(format: "%.1f", seconds))s.")
    print("Safe \(Bytes.format(state.safeBytes)) · Review \(Bytes.format(state.reviewBytes)) · Protected \(Bytes.format(state.scan.bytes(.protected)))")
    print("Reclaimable and not in use: \(state.reclaimableIsApproximate ? "up to " : "")\(Bytes.format(state.reclaimableBytes))\n")
    Out.table(
        ["SIZE", "CLASS", "CATEGORY", "ITEM", "PATH"],
        state.items.prefix(arguments.flags.contains("all") ? 100_000 : 30).map {
            [size($0), $0.safety.rawValue + (state.inUse[$0.id] != nil ? "*" : ""), $0.category.displayName, Out.truncate($0.title, 36), Out.truncate(PathUtil.display($0.path, home: appPaths.home), 70)]
        })
    if state.items.contains(where: { state.inUse[$0.id] != nil }) { print("* in use right now") }
    for issue in state.scan.issues { print("note [\(issue.analyzerID)]: \(issue.message)") }

case "projects":
    let state = await currentStorage()
    if arguments.json { Out.json(state.projectUsage); break }
    Out.table(
        ["PROJECT", "KINDS", "BRANCHES", "ARTIFACTS", "RECLAIMABLE", "GROWTH", "PROCS", "AGENTS"],
        state.projectUsage.map {
            [
                Out.truncate($0.name, 28), $0.kinds.map(\.rawValue).filter { $0 != "git" }.joined(separator: ","),
                Out.truncate($0.branches.joined(separator: ","), 24) + ($0.roots.count > 1 ? " (\($0.roots.count) trees)" : ""),
                Bytes.format($0.artifactBytes), Bytes.format($0.reclaimableBytes), $0.growth.map { Bytes.formatDelta($0.deltaBytes) } ?? "—",
                String($0.processCount), String($0.agentCount),
            ]
        })

case "builds":
    let state = await currentStorage()
    if arguments.json { Out.json(state.builds); break }
    if state.builds.isEmpty { print("No build artifacts found.") }
    for summary in state.builds {
        print("\n" + summary.narrative)
        Out.table(
            ["SIZE", "SYSTEM", "CONFIG", "BRANCH", "MODIFIED", "STATUS", "VERDICT", "WHY"],
            summary.generations.map {
                [
                    Bytes.format($0.sizeBytes), $0.system.displayName, Out.truncate($0.configuration ?? "—", 26), Out.truncate($0.branch ?? "—", 18),
                    TimeFormat.ago($0.timestamp), $0.status.rawValue, $0.isActive ? "active" : $0.verdict.isCandidate ? "candidate" : "keep",
                    $0.activeReason ?? $0.verdict.reason,
                ]
            })
    }
    print("\nAll build outputs: \(Bytes.format(state.buildTotalBytes)) of a \(Bytes.format(state.globalBuildBudgetBytes)) global budget.")

case "apps":
    let live = await engine.refreshLive()
    let apps = live.memoryOwners.filter { $0.kind == .application }
    guard let verb = arguments.positional.first, ["restart", "quit"].contains(verb) else {
        Out.table(["CHARGED", "IN RAM", "PROCS", "APPLICATION"], apps.map { [Bytes.format($0.footprintBytes), Bytes.format($0.residentBytes), String($0.processCount), $0.name] })
        print("\n`pepel apps restart <name>` asks an application to quit and opens it again; `pepel apps quit <name>` only asks it to quit.")
        break
    }
    let wanted = arguments.positional.dropFirst().joined(separator: " ").lowercased()
    guard let app = apps.first(where: { $0.name.lowercased() == wanted }) ?? apps.first(where: { $0.name.lowercased().hasPrefix(wanted) && !wanted.isEmpty }) else {
        Out.error("no running application named '\(wanted)'; see `pepel apps`"); exit(1)
    }
    let action: ApplicationAction = verb == "restart" ? .restart : .quit
    let bundle = String(app.id.dropFirst(4))
    guard let decision = await engine.applicationDecision(action, bundlePath: bundle, initiator: .cli) else { Out.error("\(app.name) is not running any more"); exit(1) }
    print("\(app.name): \(Bytes.format(app.footprintBytes)) charged, \(app.processCount) processes")
    for line in decision.reasons + decision.warnings { print("  ! \(line)") }
    guard decision.verdict != .denied else { print("PEPEL will not \(verb) \(app.name)."); exit(3) }
    guard arguments.flags.contains("yes") || Out.confirm("\(verb.capitalized) \(app.name)?") else { print("Nothing was done."); break }
    if let report = await engine.performApplication(action, bundlePath: bundle, confirmed: true, initiator: .cli) {
        print(report.note)
        if report.quit { print("Charged: \(Bytes.format(report.footprintBefore)) before, \(Bytes.format(report.footprintAfter)) after.") }
    }

case "memory" where arguments.positional.first == "growth":
    let live = await engine.refreshLive()
    let growth = await engine.memoryGrowth(owners: live.memoryOwners)
    if arguments.json { Out.json(growth); break }
    if growth.isEmpty {
        print("Nothing has grown steadily. PEPEL records what each application, agent session and tool holds every five minutes and needs at least two hours of readings.")
        break
    }
    Out.table(
        ["WAS", "NOW", "GREW", "PER HOUR", "WATCHED FOR", "KIND", "OWNER"],
        growth.map { [Bytes.format($0.baselineBytes), Bytes.format($0.currentBytes), Bytes.format($0.grownBytes), Bytes.format($0.perHourBytes), TimeFormat.age(Date().timeIntervalSince($0.since)), $0.kind.rawValue, $0.name] })
    print("\nAn application can be restarted with `pepel apps restart <name>`.")

case "memory":
    let live = await engine.refreshLive()
    if arguments.json {
        struct MemoryReport: Encodable { var advice: MemoryAdvice, explanation: String, owners: [MemoryOwner] }
        Out.json(MemoryReport(advice: live.memory, explanation: live.memoryExplanation, owners: live.memoryOwners))
        break
    }
    let t = live.telemetry
    print("\(live.memory.headline). \(live.memory.detail)\n")
    print("Where it went: \(live.memoryExplanation)\n")
    Out.table(
        ["CHARGED", "IN RAM", "NOT IN RAM", "PROCS", "KIND", "OWNER"],
        live.memoryOwners.prefix(arguments.flags.contains("all") ? 10_000 : 16).map {
            [
                Bytes.format($0.footprintBytes), Bytes.format($0.residentBytes), $0.notInRAMBytes > 50 * Bytes.mb ? "≈ " + Bytes.format($0.notInRAMBytes) : "—",
                String($0.processCount), $0.kind.rawValue, $0.name + ($0.confidence == .verified ? "" : " (\($0.confidence.rawValue))"),
            ]
        })
    print("\n“Charged” is what the kernel bills to the owner, including compressed and swapped pages; “in RAM” is resident now.\n")
    print("Physical \(Bytes.format(t.memoryTotalBytes)) · App \(Bytes.format(t.appMemoryBytes)) · Wired \(Bytes.format(t.wiredBytes)) · Compressed \(Bytes.format(t.compressedBytes)) · Cached files \(Bytes.format(t.cachedFileBytes)) · Swap \(Bytes.format(t.swapUsedBytes))")
    print("Developer processes hold \(Bytes.format(live.memory.developerFootprintBytes)).\n")
    print("Largest single processes:")
    Out.table(["FOOTPRINT", "PID", "DEV", "PROCESS"], live.memory.topConsumers.map { [Bytes.format($0.footprintBytes), String($0.identity.pid), $0.isDeveloperWorkload ? "yes" : "", $0.name] })

case "processes":
    let live = await engine.refreshLive()
    let shown = arguments.flags.contains("all") ? live.assessments : live.assessments.filter { $0.role != .container || $0.lifecycle.isAbandonedCandidate }
    if arguments.json { Out.json(shown); break }
    Out.table(
        ["PID", "ROLE", "LIFECYCLE", "CONF", "MEMORY", "AGE", "PROJECT", "COMMAND"],
        shown.sorted { $0.subtreeFootprintBytes > $1.subtreeFootprintBytes }.map {
            [
                String($0.process.pid), $0.role.rawValue, $0.lifecycle.rawValue, $0.confidence.rawValue, Bytes.format($0.process.footprintBytes),
                TimeFormat.age(Date().timeIntervalSince($0.process.identity.startDate)),
                Out.truncate($0.projectID.map { ($0 as NSString).lastPathComponent } ?? "—", 20),
                Out.truncate($0.process.displayCommand, 70),
            ]
        })
    let abandoned = live.abandoned
    print("\n\(shown.count) developer processes, \(abandoned.count) abandoned candidate\(abandoned.count == 1 ? "" : "s").")
    for a in abandoned {
        print("\nPID \(a.process.pid) \(a.process.name) — \(a.lifecycle.rawValue) (\(a.confidence.rawValue))")
        for line in a.evidence { print("  · \(line)") }
    }
    if shown.contains(where: { $0.lifecycle == .unknown }) {
        print("\nProcesses marked unknown have not been observed long enough to judge. Keep PEPEL running, or check again later.")
    }

case "containers":
    guard let report = await engine.inspectContainers() else {
        print("No container runtime answered. Docker is not installed, or its daemon is not running.")
        break
    }
    let containerSettings = await engine.currentSettings()
    if arguments.positional.first == "keep" || arguments.positional.first == "unkeep" {
        guard arguments.positional.count > 1 else { Out.error("usage: pepel containers keep|unkeep <container or compose project>"); exit(2) }
        let name = arguments.positional[1], adding = arguments.positional.first == "keep"
        let updated = try? await engine.update { settings in
            settings.keepContainers.removeAll { $0 == name }
            if adding { settings.keepContainers.append(name) }
        }
        print("PEPEL leaves these running: " + ((updated?.keepContainers.isEmpty ?? true) ? "(none; containers labelled pepel.keep=true are always left running)" : updated!.keepContainers.joined(separator: ", ")))
        break
    }
    if arguments.positional.first == "limit" {
        guard let report = await engine.inspectContainers() else { Out.error("no container runtime answered"); exit(1) }
        guard arguments.positional.count > 1 else {
            print("\(report.product): the VM may use up to \(Bytes.format(report.vmLimitBytes)). Containers use \(Bytes.format(report.usedByContainersBytes)) now\(report.peakUsedBytes > 0 ? ", \(Bytes.format(report.peakUsedBytes)) at most in the days PEPEL has watched" : "").")
            print("Lowest limit PEPEL accepts: \(Bytes.format(report.minimumLimitBytes)). " + (report.suggestedLimitBytes.map { "Suggested: \(Bytes.format($0)) — `pepel containers limit \($0 >> 30)`." } ?? "The current limit is already close to what is needed."))
            break
        }
        guard let gib = Double(arguments.positional[1]), gib > 0 else { Out.error("usage: pepel containers limit [<GiB>] [--yes]"); exit(2) }
        let bytes = Int64(gib * Double(1 << 30))
        guard let decision = await engine.vmLimitDecision(bytes, initiator: .cli) else { Out.error("no container runtime answered"); exit(1) }
        print("VM memory limit: \(Bytes.format(decision.currentLimitBytes)) → \(Bytes.format(bytes))")
        for line in decision.reasons + decision.warnings { print("  ! \(line)") }
        guard decision.verdict != .denied else { print("PEPEL will not set this limit."); exit(3) }
        guard arguments.flags.contains("yes") || Out.confirm("Change the limit and restart Docker Desktop?") else { print("Nothing was changed."); break }
        if let report = await engine.setContainerVMLimit(bytes, confirmed: true, initiator: .cli)?.report {
            for step in report.steps { print("  \(step)") }
            print("Charged to the Mac for the VM: \(Bytes.format(report.hostFootprintBefore)) before, \(Bytes.format(report.hostFootprintAfter)) after.")
        } else {
            print("Not changed: the restart was refused.")
        }
        break
    }
    if arguments.positional.first == "refresh-vm" {
        guard let (decision, before) = await engine.vmRefreshDecision(initiator: .cli) else { Out.error("no container runtime answered"); exit(1) }
        print("\(before.product): \(decision.containers.count) containers use \(Bytes.format(before.usedByContainersBytes)); the Mac is charged \(Bytes.format(before.hostFootprintBytes)) for the VM.")
        for line in decision.reasons + decision.warnings { print("  ! \(line)") }
        guard decision.verdict != .denied else { print("PEPEL will not restart the VM."); exit(3) }
        guard arguments.flags.contains("yes") || Out.confirm("Restart Docker Desktop and start the same containers again?") else { print("Nothing was restarted."); break }
        if let report = await engine.refreshContainerVM(confirmed: true, initiator: .cli)?.report {
            for step in report.steps { print("  \(step)") }
            print("Charged to the Mac for the VM: \(Bytes.format(report.hostFootprintBefore)) before, \(Bytes.format(report.hostFootprintAfter)) after (\(Bytes.formatDelta(-report.returnedBytes))). Measured about 20 seconds after Docker came back.")
        }
        break
    }
    if arguments.positional.first == "stop" {
        guard arguments.positional.count > 1 else { Out.error("usage: pepel containers stop <compose project> [--yes]"); exit(2) }
        let name = arguments.positional[1]
        guard let decision = await engine.containerStopDecision(groupID: name, initiator: .cli) else { Out.error("no running compose project named '\(name)'"); exit(1) }
        print("\(decision.group.name): \(decision.group.containers.count) containers using \(Bytes.format(decision.group.memoryBytes))")
        for line in decision.reasons + decision.warnings { print("  ! \(line)") }
        guard decision.verdict != .denied else { print("PEPEL will not stop these containers."); exit(3) }
        guard arguments.flags.contains("yes") || Out.confirm("Stop them?") else { print("Nothing was stopped."); break }
        if let report = await engine.stopContainers(groupID: name, confirmed: true, initiator: .cli)?.report {
            print("Stopped \(report.stopped.count) container\(report.stopped.count == 1 ? "" : "s")\(report.failed.isEmpty ? "" : "; failed: " + report.failed.joined(separator: ", ")).")
            print("They used \(Bytes.format(report.memoryBytes)) inside the VM. The Mac gets that back only when the VM releases it.")
        }
        break
    }
    if arguments.json { Out.json(report); break }
    print(report.explanation + "\n")
    Out.table(
        ["MEMORY", "CPU", "CONTAINERS", "COMPOSE PROJECT", "PEPEL PROJECT", "AGENT SESSIONS", "STATUS"],
        report.groups.map { group in
            let status: String
            if !group.containers.isEmpty, group.stoppable.isEmpty {
                status = "kept running (keep list or pepel.keep label)"
            } else if group.projectID == nil {
                status = "not tied to a project; left alone"
            } else if group.agentSessions > 0 {
                status = "in use"
            } else if let idle = group.idleSince {
                let waited = Date().timeIntervalSince(idle)
                let grace = TimeInterval(containerSettings.projectIdleGraceMinutes) * 60
                status = "no agent for \(TimeFormat.age(waited))" + (containerSettings.stopContainersOfIdleProjects ? (waited >= grace ? " → stopping" : " → stops in \(TimeFormat.age(grace - waited))") : "")
            } else {
                status = "—"
            }
            return [Bytes.format(group.memoryBytes), String(format: "%.1f%%", group.cpuPercent), String(group.containers.count), Out.truncate(group.name, 30), group.projectID.map { ($0 as NSString).lastPathComponent } ?? "—", String(group.agentSessions), status]
        })
    print("\nContainers of a project with no agent session for \(containerSettings.projectIdleGraceMinutes) minutes are \(containerSettings.stopContainersOfIdleProjects ? "stopped automatically (never removed)" : "only reported; `pepel containers stop <project>` stops them by hand").")
    if arguments.flags.contains("all") {
        print("")
        Out.table(
            ["MEMORY", "CPU", "CONTAINER", "COMPOSE PROJECT"],
            report.groups.flatMap(\.containers).sorted { $0.memoryBytes > $1.memoryBytes }.map {
                [Bytes.format($0.memoryBytes), String(format: "%.1f%%", $0.cpuPercent), Out.truncate($0.name, 44), $0.composeProject ?? "—"]
            })
    }
    print("\n\(report.total - report.running) more container\(report.total - report.running == 1 ? " is" : "s are") stopped and use no memory.")
    print("The limit is set in \(report.product) › Settings › Resources; PEPEL does not change it. `pepel containers refresh-vm` restarts the VM to return its memory.")

case "free" where arguments.positional.first == "permission":
    let state = await engine.fileCachePermission()
    if arguments.flags.contains("revoke") {
        switch await engine.revokeFileCachePermission(initiator: .cli) {
        case .flushed: print("Removed. The next cache flush will ask for an administrator again.")
        case .cancelled: print("Not removed: the administrator prompt was dismissed.")
        case .failed(let reason): print("Not removed: \(reason)")
        case .unavailable: print("Flushing the file cache is not available here.")
        }
    } else if !state.available {
        print("Flushing the file cache is not available here.")
    } else {
        print(state.granted
            ? "PEPEL may flush the file cache without asking (rule: \(FileCacheFlusher.rulePath)). Remove it with `pepel free permission --revoke`."
            : "Not granted yet. The first cache flush asks for an administrator once and installs a rule allowing only `/usr/sbin/purge`.")
    }

case "free":
    let plan = await engine.reclaimPlan()
    if arguments.json, !arguments.flags.contains("yes") { Out.json(plan); break }
    let t = plan.telemetry
    print("Memory now: \(Bytes.format(t.memoryUsedBytes)) used of \(Bytes.format(t.memoryTotalBytes)), pressure \(t.pressure.rawValue), \(Bytes.format(t.compressedBytes)) compressed, swap \(Bytes.format(t.swapUsedBytes)).\n")
    guard !plan.steps.isEmpty else { print("Nothing to free: no abandoned processes, sleeping sessions, unused containers or VM slack."); break }
    var selection = plan.defaultSelection
    if arguments.flags.contains("all") { selection = Set(plan.steps.map(\.id)) }
    for step in plan.steps {
        let on = selection.contains(step.id)
        print("[\(on ? "x" : " ")] \(step.title)\(step.estimatedBytes > 0 ? " — up to \(Bytes.format(step.estimatedBytes))" : "")")
        print("    \(step.detail)")
        for target in step.targets.prefix(8) { print("    · \(target)") }
        if step.targets.count > 8 { print("    · … and \(step.targets.count - 8) more") }
    }
    if arguments.flags.contains("no-cache") { selection.remove("fileCache") }
    print("\nSelected steps could return up to \(Bytes.format(plan.estimatedBytes(selection))) from what they stop. Unselected steps are included with --all; --no-cache skips the cache flush.")
    guard !selection.isEmpty else { print("Nothing is selected by default; use --all to include the optional steps."); break }
    guard arguments.flags.contains("yes") || Out.confirm("Free memory now?") else { print("Nothing was done. Run `pepel free --yes` to carry out the selected steps."); break }
    let report = await engine.reclaim(selection, initiator: .cli)
    if arguments.json { Out.json(report); break }
    print("")
    for result in report.results {
        print("\(result.title): \(result.done) of \(result.attempted)")
        for note in result.notes { print("    \(note)") }
    }
    print("\nMeasured: memory used \(Bytes.format(report.before.memoryUsedBytes)) → \(Bytes.format(report.after.memoryUsedBytes)) (\(Bytes.formatDelta(-report.freedBytes))), compressed \(Bytes.format(report.before.compressedBytes)) → \(Bytes.format(report.after.compressedBytes)), swap \(Bytes.format(report.before.swapUsedBytes)) → \(Bytes.format(report.after.swapUsedBytes)), free \(Bytes.format(report.before.freeBytes)) → \(Bytes.format(report.after.freeBytes)), cached files \(Bytes.format(report.before.cachedFileBytes)) → \(Bytes.format(report.after.cachedFileBytes)), pressure \(report.before.pressure.rawValue) → \(report.after.pressure.rawValue).")

case "leftovers":
    let live = await engine.refreshLive()
    if arguments.json { Out.json(live.leftovers); break }
    let settings = await engine.currentSettings()
    if live.leftovers.isEmpty {
        print("Nothing is left running by applications that have quit (PEPEL only knows about quits it observed).")
    }
    for group in live.leftovers {
        print("\n\(group.appName) quit \(TimeFormat.ago(group.quitAt)) and left \(group.processes.count) process\(group.processes.count == 1 ? "" : "es") holding \(Bytes.format(group.footprintBytes)):")
        Out.table(
            ["PID", "MEMORY", "CHILDREN", "CAN TERMINATE", "COMMAND"],
            group.processes.map {
                let can: String
                switch $0.eligibility {
                case .never: can = "no"
                case .approvalRequired: can = "with approval"
                case .automaticEligible: can = settings.terminateAppLeftovers ? "automatically" : "yes"
                }
                return [String($0.process.pid), Bytes.format($0.subtreeFootprintBytes), String($0.descendantCount), can, Out.truncate($0.process.shortCommand, 80)]
            })
    }
    print("\nLeftovers are \(settings.terminateAppLeftovers ? "terminated automatically \(settings.appLeftoverGraceMinutes) minutes after the application quit" : "only reported; use `pepel terminate <pid>`, or enable terminateAppLeftovers").")
    print("macOS frees a quit application's own memory by itself; only what keeps running holds any.")

case "agents" where arguments.positional.first == "instructions":
    let settings = await engine.currentSettings()
    func describe(_ outcome: AgentInstructions.Outcome) -> String {
        switch outcome {
        case .installed: "added"
        case .updated: "updated"
        case .unchanged: "already current"
        case .removed: "removed"
        case .absent: "not present"
        case .skipped(let why): "skipped — \(why)"
        }
    }
    if arguments.flags.contains("install") {
        for (target, outcome) in AgentInstructions.install(home: appPaths.home, settings: settings, backupDirectory: appPaths.supportDirectory + "/instruction-backups") {
            print("\(target.agent.displayName.padding(toLength: 12, withPad: " ", startingAt: 0)) \(PathUtil.display(target.path, home: appPaths.home)): \(describe(outcome))")
        }
        print("The first version of each changed file is kept in \(PathUtil.display(appPaths.supportDirectory, home: appPaths.home))/instruction-backups.")
    } else if arguments.flags.contains("remove") {
        for (target, outcome) in AgentInstructions.remove(home: appPaths.home) {
            print("\(target.agent.displayName.padding(toLength: 12, withPad: " ", startingAt: 0)) \(PathUtil.display(target.path, home: appPaths.home)): \(describe(outcome))")
        }
    } else {
        for (target, installed) in AgentInstructions.status(home: appPaths.home) {
            print("\(target.agent.displayName.padding(toLength: 12, withPad: " ", startingAt: 0)) \(PathUtil.display(target.path, home: appPaths.home)): \(installed ? "note installed" : "no note")")
        }
        print("\nThe note PEPEL would add (`pepel agents instructions --install`, `--remove` to take it out):\n")
        print(AgentInstructions.block(settings: settings))
    }

case "freeze":
    guard let pid = arguments.positional.first.flatMap({ Int32($0) }) else { Out.error("usage: pepel freeze <pid of an agent session>"); exit(2) }
    let live = await engine.refreshLive()
    guard let session = live.agentSessions.first(where: { $0.root.pid == pid }) else { Out.error("PID \(pid) is not the root of an agent session. See `pepel agents`."); exit(1) }
    guard let decision = await engine.freeze(session.root, confirmed: true, initiator: .cli) else { Out.error("The session is gone."); exit(1) }
    for line in decision.warnings { print("Note: \(line)") }
    if decision.verdict == .denied {
        print("Not suspended: \(decision.reasons.joined(separator: " "))")
        exit(1)
    }
    print("Suspended \(session.kind.displayName) (PID \(pid)) with its \(session.processCount - 1) helper processes. Wake it with `pepel thaw \(pid)`.")

case "thaw":
    if arguments.flags.contains("all") {
        print("Woke \(engine.thawAll(reason: "asked from the command line")) suspended session(s).")
    } else if let pid = arguments.positional.first.flatMap({ Int32($0) }), let tree = engine.frozenTrees().first(where: { $0.root.pid == pid }) {
        engine.thaw(tree.root, reason: "asked from the command line")
        print("Woke \(tree.name) (PID \(pid)).")
    } else {
        let trees = engine.frozenTrees()
        if trees.isEmpty { print("Nothing is suspended.") }
        for tree in trees {
            print("\(tree.root.pid)  \(tree.name)  suspended \(TimeFormat.age(Date().timeIntervalSince(tree.frozenAt))) ago, \(tree.members.count) processes, wakes \(tree.ownerAppName.map { "when \($0) comes to the front" } ?? "by hand")")
        }
        if !trees.isEmpty { print("\n`pepel thaw <pid>` wakes one, `pepel thaw --all` wakes all.") }
    }

case "agents":
    let live = await engine.refreshLive()
    if arguments.json { Out.json(live.agentSessions); break }
    let settings = await engine.currentSettings()
    if live.agentSessions.isEmpty { print("No agent sessions are running.") }
    Out.table(
        ["PID", "AGENT", "STATE", "QUIET FOR", "MEMORY", "PROCS", "PROJECT", "WHY"],
        live.agentSessions.map {
            [
                String($0.root.pid), $0.kind.displayName + ($0.isService ? " (server)" : ""), $0.frozenSince == nil ? $0.state.rawValue : "suspended",
                $0.quietSince.map { TimeFormat.age(Date().timeIntervalSince($0)) } ?? "—", Bytes.format($0.footprintBytes),
                String($0.processCount), Out.truncate($0.projectID.map { ($0 as NSString).lastPathComponent } ?? "—", 18),
                Out.truncate($0.evidence.first ?? "", 90),
            ]
        })
    if !live.agentHelpers.isEmpty {
        let duplicated = live.agentHelpers.reduce(Int64(0)) { $0 + $1.duplicatedBytes }
        print("\nThe same helper started once per session (\(Bytes.format(duplicated)) held by the extra copies):")
        Out.table(
            ["COPIES", "SESSIONS", "MEMORY", "EXTRA COPIES", "HELPER"],
            live.agentHelpers.prefix(15).map { [String($0.copies), String($0.sessions), Bytes.format($0.footprintBytes), Bytes.format($0.duplicatedBytes), Out.truncate($0.id, 80)] })
        print("PEPEL cannot merge them: each session starts its own. Closing idle sessions, or running such a server once and connecting sessions to it over HTTP, is what frees this.")
    }
    let asleep = live.agentSessions.filter { $0.state == .sleeping }
    print("\nSessions asleep for \(settings.agentSleepMinutes) minutes are \(settings.terminateSleepingAgents ? "terminated automatically" : "only reported (automatic termination is off)"). \(asleep.count) asleep now, holding \(Bytes.format(asleep.reduce(0) { $0 + $1.footprintBytes })).")

case "cleanup":
    let state = await currentStorage()
    let wantSafe = arguments.flags.contains("safe")
    let wantReview = arguments.flags.contains("review")
    let plan = await engine.cleanupPlan(initiator: .cli)
    if !wantSafe && !wantReview {
        if arguments.json { Out.json(plan); break }
        printPlan(plan, home: appPaths.home)
        print("\nRevalidating each item as the executor would (dry run)…")
        let report = await engine.executeCleanup(plan, confirmed: Set(plan.decisions.map(\.id)), dryRun: true)
        printReport(report)
        print("Run `pepel cleanup --safe` to remove safe items, or `pepel cleanup --review` to decide on the rest.")
        break
    }
    _ = state
    var confirmed = Set<String>()
    if wantReview {
        guard isatty(STDIN_FILENO) != 0 else { Out.error("--review is interactive and needs a terminal"); exit(2) }
        for decision in plan.decisions.filter({ $0.verdict == .needsConfirmation }).sorted(by: { $0.item.reclaimableBytes > $1.item.reclaimableBytes }) {
            print("\n\(decision.item.title) — \(size(decision.item))\n  \(PathUtil.display(decision.item.path, home: appPaths.home))\n  \(decision.item.explanation)")
            for reason in decision.reasons + decision.warnings { print("  ! \(reason)") }
            if Out.confirm("  \(decision.action.summary)?") { confirmed.insert(decision.id) }
        }
    }
    let allowed = plan.decisions.filter { $0.verdict == .allowed }
    let runSafe = wantSafe && !allowed.isEmpty
    if runSafe && !arguments.flags.contains("yes") {
        printPlan(CleanupPlan(id: plan.id, createdAt: plan.createdAt, initiator: plan.initiator, decisions: allowed), home: appPaths.home)
        guard Out.confirm("\nClean these \(allowed.count) safe items?") else { print("Nothing was removed."); break }
    }
    var selected = plan
    selected.decisions = plan.decisions.filter { (runSafe && $0.verdict == .allowed) || confirmed.contains($0.id) }
    guard !selected.decisions.isEmpty else { print("Nothing to clean."); break }
    let report = await engine.executeCleanup(selected, confirmed: confirmed, dryRun: false)
    if arguments.json { Out.json(report) } else { printReport(report) }

case "terminate":
    guard let pid = arguments.positional.first.flatMap(Int32.init) else { Out.error("usage: pepel terminate <pid> [--force] [--yes]"); exit(2) }
    let live = await engine.refreshLive()
    guard let target = live.assessments.first(where: { $0.process.pid == pid }) ?? live.leftovers.flatMap(\.processes).first(where: { $0.process.pid == pid }) else {
        Out.error("PID \(pid) is not a developer process PEPEL manages (or does not exist)")
        exit(1)
    }
    guard let decision = await engine.terminationDecision(target.process.identity, initiator: .cli) else { exit(1) }
    print("\(target.process.name) (PID \(pid)) — \(target.lifecycle.rawValue), \(target.confidence.rawValue)\n  \(target.process.displayCommand)")
    for line in target.evidence { print("  · \(line)") }
    for line in decision.reasons + decision.warnings { print("  ! \(line)") }
    guard decision.verdict != .denied else { print("PEPEL will not terminate this process."); exit(3) }
    let force = arguments.flags.contains("force")
    guard arguments.flags.contains("yes") || Out.confirm("Send SIGTERM\(force ? " (and SIGKILL if it does not exit)" : "")?") else { print("Nothing was signalled."); break }
    switch await engine.terminate(target.process.identity, confirmed: true, force: force, initiator: .cli) {
    case .completed(let report):
        for step in report.steps { print("  \(step)") }
        print("Memory used before \(Bytes.format(report.before.memoryUsedBytes)), after \(Bytes.format(report.after.memoryUsedBytes)) (observed change \(Bytes.formatDelta(report.observedMemoryChange))). Pressure \(report.before.pressure.rawValue) → \(report.after.pressure.rawValue).")
        print("The process tree held \(Bytes.format(report.footprintBefore)); that is not a guarantee of memory made available.")
    case .denied(let d), .needsConfirmation(let d): print("Not terminated: \(d.reasons.joined(separator: " "))")
    case .notFound: print("The process is gone.")
    }

case "protect", "pin":
    guard let value = arguments.positional.first else { Out.error("usage: pepel \(arguments.command) <path>"); exit(2) }
    let kind = arguments.command == "pin" ? ProtectionKind.pin : ProtectionKind(rawValue: arguments.options["kind"] ?? "path") ?? .path
    do {
        let rule = try await engine.protect(kind, value: value, note: arguments.options["note"] ?? "")
        print("Protected (\(rule.kind.rawValue)): \(rule.value)")
    } catch { Out.error("\(error)"); exit(1) }

case "unprotect", "unpin":
    guard let value = arguments.positional.first else { Out.error("usage: pepel \(arguments.command) <path>"); exit(2) }
    let canonical = PathUtil.canonical(value, home: appPaths.home)
    let matches = engine.protections().filter { $0.value == canonical || $0.value == value || $0.id == value }
    guard !matches.isEmpty else { Out.error("no such protection"); exit(1) }
    for rule in matches { try? await engine.unprotect(id: rule.id) }
    print("Removed \(matches.count) protection\(matches.count == 1 ? "" : "s").")

case "protections":
    let rules = engine.protections()
    if arguments.json { Out.json(rules); break }
    if rules.isEmpty { print("No protection rules. Credentials, agent state, source code and git metadata are always protected.") }
    Out.table(["KIND", "VALUE", "NOTE"], rules.map { [$0.kind.rawValue, PathUtil.display($0.value, home: appPaths.home), $0.note] })

case "history":
    let limit = Int(arguments.options["limit"] ?? "") ?? 40
    let entries = engine.store.audit(limit: limit)
    let growth = engine.growth()
    if arguments.json {
        struct History: Encodable { var growth: GrowthState, audit: [AuditEntry] }
        Out.json(History(growth: growth, audit: entries))
        break
    }
    print("Disk usage growth — last hour: \(growthText(growth.hour)) · day: \(growthText(growth.day)) · week: \(growthText(growth.week))")
    for spike in growth.spikes.suffix(5) { print("Spike: \(Bytes.formatDelta(spike.deltaBytes)) at \(spike.at.formatted(date: .abbreviated, time: .shortened))") }
    print("")
    Out.table(
        ["WHEN", "KIND", "BY", "SUBJECT", "OUTCOME", "SIZE"],
        entries.map { [$0.timestamp.formatted(date: .numeric, time: .shortened), $0.kind.rawValue, $0.initiator, Out.truncate($0.subject, 40), Out.truncate($0.outcome, 60), $0.bytes > 0 ? Bytes.format($0.bytes) : ""] })

case "run":
    guard !arguments.passthrough.isEmpty else { Out.error("usage: pepel run [--enforce-budget] -- <build command>"); exit(2) }
    let cwd = FileManager.default.currentDirectoryPath
    _ = await engine.refreshProjects()
    let project = await engine.knownProjects().sorted { $0.id.count > $1.id.count }.first { PathUtil.isInside(PathUtil.canonical(cwd), root: $0.id) }
    if let project, let storage = await engine.storage, let summary = storage.builds.first(where: { $0.id == project.groupID }), summary.nearBudget {
        Out.error(summary.narrative)
        if summary.overBudget, arguments.flags.contains("enforce-budget") {
            Out.error("build not started: the project is over its build budget. Run `pepel cleanup --review` or raise the budget.")
            exit(75)
        }
    }
    let status = BuildWrapper(store: engine.store).run(
        command: arguments.passthrough, workingDirectory: cwd, projectID: project?.id, branch: project?.git?.branch,
        commit: project?.git?.headCommit.map { String($0.prefix(12)) })
    exit(status)

case "agent":
    guard let op = arguments.positional.first else {
        print("Operations: " + AgentAPIService.operations.joined(separator: ", "))
        break
    }
    var args: [String: String] = [:]
    for pair in arguments.positional.dropFirst() {
        guard let eq = pair.firstIndex(of: "=") else { Out.error("arguments are key=value"); exit(2) }
        args[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
    }
    do {
        let token = try APIToken.loadOrCreate(at: appPaths.token)
        let data: Data
        do {
            data = try LocalAPIClient(socketPath: appPaths.socket, token: token).send(op: op, args: args)
        } catch let error as APIError where error.message == "unreachable" {
            // The app is not running: apply the same narrow operation directly to the shared store.
            data = try await engine.makeAgentService().handle(op: op, args: args)
        }
        print(String(decoding: data, as: UTF8.self))
    } catch { Out.error("\(error)"); exit(1) }

case "roots":
    if let action = arguments.positional.first, arguments.positional.count > 1 {
        let path = arguments.positional[1]
        _ = try? await engine.update { settings in
            settings.projectRoots.removeAll { $0 == path }
            if action == "add" { settings.projectRoots.append(path) }
        }
    }
    let settings = await engine.currentSettings()
    if arguments.json { Out.json(settings.projectRoots) } else { settings.projectRoots.forEach { print($0) } }

case "config":
    if arguments.positional.first == "set", arguments.positional.count == 3 {
        let key = arguments.positional[1], raw = arguments.positional[2]
        let current = await engine.currentSettings()
        guard var object = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(current))) as? [String: Any], object[key] != nil else {
            Out.error("unknown setting '\(key)'")
            exit(2)
        }
        // Values are JSON (true, 42, ["~/code"]); anything else is taken as a string.
        object[key] = (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])) ?? raw
        guard let data = try? JSONSerialization.data(withJSONObject: object), let updated = try? JSONDecoder().decode(PepelSettings.self, from: data) else {
            Out.error("'\(raw)' is not a valid value for \(key)")
            exit(2)
        }
        _ = try? await engine.update { $0 = updated }
    }
    Out.json(await engine.currentSettings())

case "analyzers":
    struct Row: Encodable { var id: String, name: String, detection: String }
    let rows = engine.coordinator.analyzers.map { Row(id: $0.id, name: $0.displayName, detection: $0.detection) }
    if arguments.json { Out.json(rows) } else { for row in rows { print("\(row.id)\n  \(row.name)\n  \(row.detection)\n") } }

default:
    Out.error("unknown command '\(arguments.command)'\n")
    print(Out.help)
    exit(2)
}
