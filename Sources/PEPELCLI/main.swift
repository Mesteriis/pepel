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

case "projects" where arguments.positional.first == "ignored":
    _ = await currentStorage()
    if arguments.positional.dropFirst().first == "trash" {
        guard let given = arguments.positional.dropFirst(2).first else { Out.error("usage: pepel projects ignored trash <path> [--yes]"); exit(2) }
        let path = PathUtil.canonical(PathUtil.expand(given))
        guard arguments.flags.contains("yes") || Out.confirm("Move \(PathUtil.display(path, home: appPaths.home)) to the Trash?") else { print("Nothing was moved."); break }
        if let refusal = await engine.trashIgnoredFolder(path, confirmed: true, initiator: .cli) { print("Not moved: \(refusal)"); exit(3) }
        print("Moved to the Trash. Space is freed when the Trash is emptied.")
        break
    }
    print("Asking git about each project…")
    let found = await engine.ignoredFolders()
    if arguments.json { Out.json(found); break }
    guard !found.isEmpty else { print("No folder of 500 MB or more that git ignores and PEPEL does not already know."); break }
    Out.table(["SIZE", "CHANGED", "", "PROJECT", "WHERE"], found.prefix(40).map { [Bytes.format($0.bytes), $0.lastUse.map { TimeFormat.ago($0) } ?? "—", $0.looksLikeData ? "data?" : "", Out.truncate($0.projectName, 24), PathUtil.display($0.path, home: appPaths.home)] })
    print("\n\(found.count) folders, \(Bytes.format(found.reduce(0) { $0 + $1.bytes })). Git ignores them, but they may be data rather than output: `pepel projects ignored trash <path>` moves one to the Trash.")

case "projects" where arguments.positional.first == "stale":
    _ = await currentStorage()
    let settings = await engine.currentSettings()
    let days = arguments.options["days"].flatMap { Int($0) } ?? settings.staleProjectDays
    let stale = await engine.staleProjects(days: days)
    if arguments.json { Out.json(stale); break }
    guard !stale.isEmpty else { print("No project with removable artifacts has been left untouched for \(days) days."); break }
    let total = stale.reduce(Int64(0)) { $0 + $1.bytes }
    if arguments.positional.dropFirst().first == "clean" {
        print("\(stale.count) projects untouched for \(days)+ days hold \(Bytes.format(total)) of environments, dependencies and build output.")
        guard arguments.flags.contains("yes") || Out.confirm("Remove these artifacts? Source, git data and configuration are not touched.") else { print("Nothing was removed."); break }
        if let report = await engine.cleanStaleProjects(days: days, confirmed: true, initiator: .cli) {
            print("Removed \(report.succeededCount) of \(report.outcomes.count) items. Disk available: \(Bytes.format(report.diskAvailableBefore)) → \(Bytes.format(report.diskAvailableAfter)).")
            for outcome in report.outcomes where !outcome.status.succeeded { print("  kept \(PathUtil.display(outcome.path, home: appPaths.home)): \(outcome.status)") }
        }
        break
    }
    Out.table(
        ["ARTIFACTS", "ITEMS", "LAST TOUCHED", "PROJECT"],
        stale.prefix(arguments.flags.contains("all") ? 10_000 : 30).map { [Bytes.format($0.bytes), String($0.itemIDs.count), TimeFormat.ago($0.lastActivity), PathUtil.display($0.id, home: appPaths.home)] })
    print("\n\(stale.count) projects, \(Bytes.format(total)). `pepel projects stale clean` removes their environments, dependencies and build output (--days N to change the age).")
    print("Automatic daily removal is \(settings.cleanStaleProjects ? "on" : "off") (cleanStaleProjects). Exclude a project with `pepel protect <path> --kind project`.")

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
    if arguments.positional.first == "windowless" {
        let verb = arguments.positional.dropFirst().first
        let apps = await engine.windowlessApps()
        if verb == "on" || verb == "off" {
            let wanted = arguments.positional.dropFirst(2).joined(separator: " ").lowercased()
            guard let app = apps.first(where: { $0.name.lowercased() == wanted || $0.bundleID.lowercased() == wanted }) else {
                Out.error("no such application in the list; see `pepel apps windowless`"); exit(1)
            }
            try await engine.setQuitWhenWindowless(app.bundleID, verb == "on")
            let minutes = await engine.currentSettings().windowlessQuitMinutes
            print(verb == "on" ? "\(app.name) will be quit after \(minutes) min with no window, when it is not in front and not busy." : "\(app.name) is left alone.")
            break
        }
        if arguments.json { Out.json(apps); break }
        let minutes = await engine.currentSettings().windowlessQuitMinutes
        Out.table(
            ["QUIT", "NOW", "SEEN WITHOUT WINDOWS", "APPLICATION", "BUNDLE ID"],
            apps.map {
                [
                    $0.quitWhenWindowless ? "yes" : "", $0.windowlessNow ? "no window" : $0.running ? "open" : "",
                    $0.timesSeen > 0 ? "\($0.timesSeen)×, last \($0.lastSeen.map { TimeFormat.ago($0) } ?? "—")" : $0.known ? "known to" : "", $0.name, $0.bundleID,
                ]
            })
        print("\n`pepel apps windowless on|off <name>` decides for one. A chosen app is quit normally after \(minutes) min with no window (windowlessQuitMinutes), when it is not in front and not busy.")
        break
    }
    if arguments.positional.first == "caches" || arguments.positional.first == "leftovers" {
        let settings = await engine.currentSettings()
        let days = arguments.options["days"].flatMap { Int($0) } ?? settings.appCacheUnusedDays
        if arguments.positional.first == "leftovers" {
            if arguments.positional.dropFirst().first == "trash" {
                guard arguments.flags.contains("yes") || Out.confirm("Move what removed applications left behind to the Trash?") else { print("Nothing was moved."); break }
                let result = await engine.trashApplicationLeftovers(confirmed: true, initiator: .cli)
                print(result.denial.map { "Not done: \($0)" } ?? result.report.map { "Moved \($0.removed.count) folders (\(Bytes.format($0.bytes))) to the Trash\($0.kept.isEmpty ? "" : "; \($0.kept.count) could not be moved")." } ?? "")
                break
            }
            print("Measuring…")
            let data = await engine.applicationData()
            if arguments.json { Out.json(data.leftovers); break }
            guard !data.leftovers.isEmpty else { print("Nothing left by removed applications has been untouched for \(settings.leftoverDays) days."); break }
            Out.table(["SIZE", "LAST USED", "WHERE"], data.leftovers.map { [Bytes.format($0.bytes), $0.lastUse.map { TimeFormat.ago($0) } ?? "—", PathUtil.display($0.path, home: appPaths.home)] })
            print("\n\(Bytes.format(data.leftovers.reduce(0) { $0 + $1.bytes })) in folders named after applications that are no longer installed. `pepel apps leftovers trash` moves them to the Trash.")
            break
        }
        if arguments.positional.dropFirst().first == "clean" {
            let unknown = arguments.flags.contains("unknown")
            guard arguments.flags.contains("yes") || Out.confirm("Remove application caches unused for \(days) days\(unknown ? ", including ones PEPEL cannot tie to an application" : "")?") else { print("Nothing was removed."); break }
            let result = await engine.cleanApplicationCaches(days: days, includeUnknown: unknown, confirmed: true, initiator: .cli)
            print(result.denial.map { "Not done: \($0)" } ?? result.report.map { "Removed \($0.removed.count) caches, \(Bytes.format($0.bytes))\($0.kept.isEmpty ? "" : "; \($0.kept.count) could not be removed")." } ?? "")
            break
        }
        print("Measuring…")
        let data = await engine.applicationData()
        if arguments.json { Out.json(data.caches); break }
        Out.table(
            ["SIZE", "LAST USED", "APPLICATION", "CACHE"],
            data.caches.prefix(arguments.flags.contains("all") ? 10_000 : 30).map { [Bytes.format($0.bytes), $0.lastUse.map { TimeFormat.ago($0) } ?? "—", $0.owner.rawValue, $0.name] })
        func total(_ owners: Set<ApplicationDataOwner>) -> Int64 { data.caches.filter { owners.contains($0.owner) && $0.unused(days: days) }.reduce(0) { $0 + $1.bytes } }
        print("\nUnused for \(days)+ days: \(Bytes.format(total([.installed, .removed]))) of applications that are not running or are gone; \(Bytes.format(total([.unknown]))) that PEPEL cannot tie to an application.")
        print("`pepel apps caches clean` removes the first group; add --unknown for the second. Automatic daily cleaning is \(settings.cleanAppCaches ? "on" : "off") (cleanAppCaches).")
        break
    }
    if arguments.positional.first == "tabs" {
        let settings = await engine.currentSettings()
        let idle = live.browserTabs.filter { $0.idleFor != nil }
        if arguments.positional.dropFirst().first == "unload" {
            guard !idle.isEmpty else { print("No browser tab process has been idle for \(settings.tabIdleMinutes) minutes (PEPEL needs to have watched it that long)."); break }
            print("\(idle.count) idle tab processes hold \(Bytes.format(idle.reduce(0) { $0 + $1.footprintBytes })). The tabs stay and load again when opened; unsent form input and scroll positions are lost.")
            guard arguments.flags.contains("yes") || Out.confirm("Unload them?") else { print("Nothing was unloaded."); break }
            var done = 0
            for item in live.idleTabs {
                if case .completed(let report) = await engine.terminate(item.process.identity, confirmed: true, force: false, initiator: .cli), report.exited { done += 1 }
            }
            print("Unloaded \(done) of \(live.idleTabs.count).")
            break
        }
        if arguments.json { Out.json(live.browserTabs); break }
        if live.browserTabs.isEmpty { print("No browser tab process holds 150 MB or more."); break }
        Out.table(
            ["PID", "CHARGED", "IN RAM", "IDLE", "BROWSER"],
            live.browserTabs.map { [String($0.root.pid), Bytes.format($0.footprintBytes), Bytes.format($0.residentBytes), $0.idleFor.map { TimeFormat.age($0) } ?? "busy or newly seen", $0.browser] })
        print("\n`pepel apps tabs unload` unloads the idle ones (after \(settings.tabIdleMinutes) minutes without CPU use).")
        break
    }
    if arguments.positional.first == "unused" {
        let settings = await engine.currentSettings()
        if arguments.json { Out.json(live.unusedApplications); break }
        if live.unusedApplications.isEmpty {
            print("No application has been open and unused for \(settings.unusedApplicationHours) hours. PEPEL counts from when it first saw an application or last saw it in front.")
        } else {
            Out.table(
                ["CHARGED", "IN RAM", "LAST IN FRONT", "CPU, LAST HOUR", "APPLICATION"],
                live.unusedApplications.map { [Bytes.format($0.footprintBytes), Bytes.format($0.residentBytes), TimeFormat.ago($0.lastActive), $0.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—", $0.name] })
            print("\n`pepel apps quit <name>` asks one to quit. Add a name to keepApplications in the settings to never list it.")
        }
        break
    }
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

case "simulators":
    let live = await engine.refreshLive()
    if arguments.positional.first == "shutdown" {
        let targets = arguments.flags.contains("all") ? live.simulators : live.simulators.filter { sim in arguments.positional.dropFirst().contains { $0 == sim.udid || $0.lowercased() == sim.name.lowercased() } }
        guard !targets.isEmpty else { Out.error("usage: pepel simulators shutdown <udid or name>|--all"); exit(2) }
        for simulator in targets { print(await engine.shutdownSimulator(udid: simulator.udid, initiator: .cli).note) }
        break
    }
    if arguments.json { Out.json(live.simulators); break }
    if live.simulators.isEmpty { print("No simulator is booted."); break }
    Out.table(
        ["MEMORY", "PROCS", "BOOTED", "NAME", "UDID", "IN USE"],
        live.simulators.map { [Bytes.format($0.footprintBytes), String($0.processCount), TimeFormat.ago($0.bootedAt), $0.name, $0.udid, $0.inUse ?? "nothing suggests it"] })
    print("\n`pepel simulators shutdown <udid or name>` (or --all) shuts one down; devices and their data stay.")

case "memory" where arguments.positional.first == "swap":
    let live = await engine.refreshLive()
    if arguments.json { Out.json(live.swap); break }
    print(live.swap?.explanation ?? "Swap files cannot be read here.")
    if let swap = live.swap, swap.fileCount > 0, let oldest = swap.oldestFile { print("The oldest swap file was last written \(TimeFormat.ago(oldest)).") }

case "memory" where arguments.positional.first == "forecast":
    let live = await engine.refreshLive()
    if arguments.json { Out.json(live.forecast); break }
    print(live.forecast?.sentence() ?? "No forecast: memory in use has not been rising steadily over the last hour and a half (PEPEL needs at least 20 minutes of readings, taken every five minutes).")

case "memory" where arguments.positional.first == "system":
    let live = await engine.refreshLive()
    if arguments.positional.dropFirst().first == "restart" {
        let wanted = arguments.positional.dropFirst(2).first?.lowercased()
        let targets = live.restartableSystem.filter { wanted == nil ? arguments.flags.contains("all") : $0.process.name.lowercased() == wanted }
        guard !targets.isEmpty else { Out.error("usage: pepel memory system restart <name>|--all (only components listed as restartable)"); exit(2) }
        for target in targets {
            print("\(target.process.name) (\(Bytes.format(target.subtreeFootprintBytes))): \(target.evidence.last ?? "")")
            guard arguments.flags.contains("yes") || Out.confirm("Restart \(target.process.name)?") else { continue }
            if case .completed(let report) = await engine.terminate(target.process.identity, confirmed: true, force: false, initiator: .cli) {
                let again = await engine.refreshLive().systemProcesses.first { $0.name == target.process.name }
                print(report.exited ? "Restarted. It holds \(again.map { Bytes.format($0.footprintBytes) } ?? "under 300 MB") now." : "It did not exit.")
            } else {
                print("PEPEL will not restart it.")
            }
        }
        break
    }
    if arguments.json { Out.json(live.systemProcesses); break }
    if live.systemProcesses.isEmpty { print("No system process of yours holds 300 MB or more."); break }
    Out.table(
        ["PID", "CHARGED", "IN RAM", "", "PROCESS", "NOTE"],
        live.systemProcesses.map { [String($0.root.pid), Bytes.format($0.footprintBytes), Bytes.format($0.residentBytes), $0.restartable ? "restartable" : "", $0.name, Out.truncate($0.note, 80)] })
    print("\n`pepel memory system restart <name>` restarts a restartable one; macOS starts it again by itself.")

case "memory" where arguments.positional.first == "swapped":
    let live = await engine.refreshLive()
    if arguments.json { Out.json(live.dormant); break }
    if live.dormant.isEmpty { print("No process of yours holds 500 MB or more with almost none of it in RAM while doing nothing."); break }
    Out.table(
        ["PID", "CHARGED", "IN RAM", "STARTED", "CPU", "PROCESS"],
        live.dormant.map {
            [
                String($0.process.pid), Bytes.format($0.subtreeFootprintBytes), Bytes.format($0.process.residentBytes), TimeFormat.ago($0.process.identity.startDate),
                $0.cpuPercent.map { String(format: "%.2f%%", $0) } ?? "—", Out.truncate($0.process.shortCommand, 70),
            ]
        })
    print("\nThese cost little RAM but fill swap and compressed memory. `pepel terminate <pid>` ends one after showing what PEPEL knows about it.")

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
    if let forecast = live.forecast { print("Forecast: \(forecast.sentence())\n") }
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
    if arguments.positional.first == "pause" || arguments.positional.first == "unpause" {
        guard arguments.positional.count > 1 else { Out.error("usage: pepel containers pause|unpause <compose project> [--yes]"); exit(2) }
        let name = arguments.positional[1]
        if arguments.positional.first == "unpause" {
            _ = await engine.inspectContainers()
            let resumed = await engine.resumeContainers(groupID: name, reason: "asked from the command line")
            print(resumed.isEmpty ? "Nothing in '\(name)' was paused." : "Resumed \(resumed.count) container\(resumed.count == 1 ? "" : "s"): \(resumed.joined(separator: ", ")).")
            break
        }
        guard let decision = await engine.containerStopDecision(groupID: name, initiator: .cli) else { Out.error("no running compose project named '\(name)'"); exit(1) }
        print("\(decision.group.name): \(decision.group.pausable.count) containers to pause")
        for line in decision.reasons + decision.warnings { print("  ! \(line)") }
        guard decision.verdict != .denied else { print("PEPEL will not pause these containers."); exit(3) }
        guard arguments.flags.contains("yes") || Out.confirm("Pause them?") else { print("Nothing was paused."); break }
        if let report = await engine.stopContainers(groupID: name, confirmed: true, initiator: .cli, action: .pause)?.report {
            print("Paused \(report.stopped.count) container\(report.stopped.count == 1 ? "" : "s")\(report.failed.isEmpty ? "" : "; failed: " + report.failed.joined(separator: ", ")). They keep their memory inside the VM and continue with `pepel containers unpause \(name)`, or by themselves when an agent session starts in the project.")
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
            } else if !group.paused.isEmpty {
                status = "\(group.paused.count) paused; resume when an agent returns"
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
    print("The limit is set in \(report.product) › Settings › Resources; `pepel containers limit <GiB>` lowers it. `pepel containers refresh-vm` restarts the VM to return its memory.")

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

case "agents" where arguments.positional.first == "servers":
    let live = await engine.refreshLive()
    if arguments.positional.dropFirst().first == "clean" {
        guard !live.staleBranches.isEmpty else { print("Nothing inside agent servers looks left behind."); break }
        for item in live.staleBranches { print("  \(item.process.pid)  \(Bytes.format(item.subtreeFootprintBytes))  \(Out.truncate(item.process.shortCommand, 80))") }
        print("An open conversation that still uses one of these loses its tools until the application starts them again.")
        guard arguments.flags.contains("yes") || Out.confirm("End these \(live.staleBranches.count) old copies?") else { print("Nothing was ended."); break }
        var ended = 0
        for item in live.staleBranches {
            if case .completed(let report) = await engine.terminate(item.process.identity, confirmed: true, force: false, initiator: .cli), report.exited { ended += 1 }
        }
        print("Ended \(ended) of \(live.staleBranches.count).")
        break
    }
    if arguments.json { Out.json(live.serviceBranches); break }
    if live.serviceBranches.isEmpty { print("No agent server has started anything."); break }
    Out.table(
        ["PID", "MEMORY", "PROCS", "STARTED", "IDLE", "COPIES", "", "SERVER", "PROGRAM"],
        live.serviceBranches.map {
            [
                String($0.root.pid), Bytes.format($0.footprintBytes), String($0.processCount), TimeFormat.ago($0.startedAt),
                $0.idleFor.map { TimeFormat.age($0) } ?? "—", String($0.copies), $0.isStale ? "old copy" : ($0.copies > 1 ? "newest" : ""), $0.serviceName,
                Out.truncate($0.signature, 60),
            ]
        })
    let stale = live.serviceBranches.filter(\.isStale)
    print(stale.isEmpty ? "\nNothing looks left behind." : "\n\(stale.count) old copies hold \(Bytes.format(stale.reduce(0) { $0 + $1.footprintBytes })). `pepel agents servers clean` ends them after asking.")

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
            ["COPIES", "SESSIONS", "MEMORY", "EXTRA COPIES", "IN QUIET SESSIONS", "HELPER"],
            live.agentHelpers.prefix(15).map {
                [
                    String($0.copies), String($0.sessions), Bytes.format($0.footprintBytes), Bytes.format($0.duplicatedBytes),
                    $0.quietCopies == 0 ? "—" : "\($0.quietCopies) · \(Bytes.format($0.quietBytes))", Out.truncate($0.id, 70),
                ]
            })
        let quiet = live.agentHelpers.reduce(Int64(0)) { $0 + $1.quietBytes }
        print("PEPEL cannot merge them: each session starts its own. \(Bytes.format(quiet)) of it sits in sessions that are not working; suspending or ending those (`pepel free`) stops it. Running such a server once and connecting sessions to it over HTTP removes the copies for good.")
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

case "disk":
    let settings = await engine.currentSettings()
    if arguments.positional.first == "map" {
        // The whole disk by default, measured folder by folder like the dashboard's map.
        let given = arguments.positional.dropFirst().first.map { PathUtil.expand($0) }
        let target = given.map { $0 == "/" ? "/" : PathUtil.canonical($0) } ?? "/"
        let scanner = DiskMapScanner(home: appPaths.home)
        let quiet = arguments.json
        guard let level = await scanner.measure(target, includeGuarded: arguments.flags.contains("guarded"), update: { partial in
            if !quiet, partial.pending > 0 { FileHandle.standardError.write(Data("\r\(partial.pending) folders left, \(Bytes.format(partial.bytes)) so far   ".utf8)) }
        }).first(where: { $0.path == target }) else { Out.error("'\(target)' could not be read"); exit(1) }
        if !quiet { FileHandle.standardError.write(Data("\r                                              \r".utf8)) }
        if arguments.json { Out.json(level); break }
        let limit = Int(arguments.options["limit"] ?? "") ?? 30
        print("\(PathUtil.display(target, home: appPaths.home)): \(Bytes.format(level.bytes)) in \(level.nodes.count) items\n")
        Out.table(
            ["SIZE", "SHARE", "FILES", "", "NAME"],
            level.nodes.prefix(limit).map { node in
                [
                    node.kind == .restricted ? "—" : Bytes.format(node.bytes), node.kind == .restricted ? "" : String(format: "%.1f%%", Double(node.bytes) / Double(max(1, level.bytes)) * 100),
                    node.fileCount > 0 ? node.fileCount.formatted() : "", node.kind == .restricted ? "not read" : node.kind == .folder ? "folder" : node.kind == .file ? "file" : "",
                    Out.truncate(node.name, 60),
                ]
            })
        print("\n`pepel disk map <folder>` opens one. Folders macOS guards are not read unless named or --guarded is given.")
        break
    }
    if arguments.positional.first == "files" {
        let days = arguments.options["days"].flatMap { Int($0) } ?? 90
        print("Walking your home folder (Library, caches and agents' folders are left out)…")
        let report = await engine.largeFiles(days: days, includeGuarded: arguments.flags.contains("guarded"))
        if arguments.json { Out.json(report); break }
        print("\(report.filesSeen.formatted()) entries looked at.\n")
        print("Not opened for \(days)+ days, 500 MB or more: \(report.old.count) files, \(Bytes.format(report.oldBytes))")
        Out.table(["SIZE", "LAST OPENED", "WHERE"], report.old.prefix(25).map { [Bytes.format($0.bytes), TimeFormat.ago($0.lastUse), PathUtil.display($0.path, home: appPaths.home)] })
        print("\nIdentical copies, 100 MB or more: \(report.duplicates.count) groups; removing all but one copy would free up to \(Bytes.format(report.duplicateBytes)) (copies Finder made may be clones that share space).")
        for group in report.duplicates.prefix(10) {
            print("  \(Bytes.format(group[0].bytes)) × \(group.count)")
            for file in group { print("      \(PathUtil.display(file.path, home: appPaths.home))") }
        }
        print("\nPEPEL only reports these. Folders macOS guards are left out unless --guarded is given.")
        break
    }
    if arguments.positional.first == "tidy" {
        let shotDays = arguments.options["screenshots"].flatMap { Int($0) } ?? settings.screenshotDays
        let days = arguments.options["days"].flatMap { Int($0) } ?? settings.downloadDays
        let items = await engine.tidyItems(screenshotDays: shotDays, downloadDays: days)
        let going = items.filter { $0.keptBecause == nil }
        if arguments.positional.dropFirst().first == "clean" {
            guard !going.isEmpty else { print("Nothing to take."); break }
            let how = arguments.flags.contains("delete") ? TidyAction.delete : settings.tidyAction
            print("\(going.count) items, \(Bytes.format(going.reduce(0) { $0 + $1.bytes })) would be \(how == .trash ? "moved to the Trash" : "removed for good").")
            guard arguments.flags.contains("yes") || Out.confirm("Go ahead?") else { print("Nothing was done."); break }
            let result = await engine.runTidy(screenshots: true, downloads: true, confirmed: true, initiator: .cli, action: how)
            print(result.denial.map { "Not done: \($0)" } ?? "\(how == .trash ? "Moved to the Trash" : "Removed"): \(result.removed) items, \(Bytes.format(result.bytes)).")
            break
        }
        if arguments.json { Out.json(items); break }
        Out.table(
            ["SIZE", "LAST USED", "WHAT", "", "NAME"],
            items.prefix(40).map { [Bytes.format($0.bytes), TimeFormat.ago($0.lastUse), $0.kind.rawValue, $0.keptBecause.map { Out.truncate($0, 40) } ?? "would go", Out.truncate($0.name, 50)] })
        print("\nScreenshots older than \(shotDays) day(s) and downloads unused for \(days) days: \(going.count) items, \(Bytes.format(going.reduce(0) { $0 + $1.bytes })). They go to the \(settings.tidyAction == .trash ? "Trash" : "bin for good").")
        print("`pepel disk tidy clean` does it (--delete to skip the Trash). Daily: screenshots \(settings.tidyScreenshots ? "on" : "off"), downloads \(settings.tidyDownloads ? "on" : "off") (tidyScreenshots, tidyDownloads). Kept kinds: \(settings.tidyKeepExtensions.joined(separator: ", ")).")
        break
    }
    if arguments.positional.first == "backups" {
        let keep = arguments.options["keep"].flatMap { Int($0) } ?? settings.toolBackupsKeep
        let days = arguments.options["days"].flatMap { Int($0) } ?? settings.toolBackupsDays
        if arguments.positional.dropFirst().first == "clean" {
            let doomed = await engine.toolBackups(keep: keep, days: days).filter { !$0.kept }
            guard !doomed.isEmpty else { print("Nothing to remove when keeping the newest \(keep) of each set and anything younger than \(days) days."); break }
            print("\(doomed.count) backups, \(Bytes.format(doomed.reduce(0) { $0 + $1.bytes })) would be removed. The live agent history is not touched.")
            guard arguments.flags.contains("yes") || Out.confirm("Remove them?") else { print("Nothing was removed."); break }
            let result = await engine.cleanToolBackups(keep: keep, days: days, confirmed: true, initiator: .cli)
            if let denial = result.denial { print("Not done: \(denial)"); exit(3) }
            print("Removed \(result.removed). Free space measured: +\(Bytes.format(result.bytes)); less than their size when they shared blocks with the live files.")
            for note in result.skipped { print("  kept: \(note)") }
            break
        }
        let backups = await engine.toolBackups(keep: keep, days: days)
        if arguments.json { Out.json(backups); break }
        guard !backups.isEmpty else { print("No Clausona backups found."); break }
        Out.table(
            ["SIZE", "MADE", "", "SET", "BACKUP"],
            backups.map { [Bytes.format($0.bytes), TimeFormat.ago($0.createdAt), $0.kept ? "kept" : "would go", $0.set, Out.truncate(($0.path as NSString).lastPathComponent, 46)] })
        let doomed = backups.filter { !$0.kept }
        print("\nKeeping the newest \(keep) of each set and anything younger than \(days) days, \(doomed.count) would go: \(Bytes.format(doomed.reduce(0) { $0 + $1.bytes })).")
        print("`pepel disk backups clean [--keep N] [--days D]` removes them. Daily rule: \(settings.cleanToolBackups ? "on" : "off") (cleanToolBackups, toolBackupsKeep, toolBackupsDays).")
        break
    }
    if arguments.positional.first == "images" {
        if arguments.positional.dropFirst().first == "delete" {
            let ids = Array(arguments.positional.dropFirst(2))
            guard !ids.isEmpty else { Out.error("usage: pepel disk images delete <api/tag/abi> … [--yes]"); exit(2) }
            guard arguments.flags.contains("yes") || Out.confirm("Delete \(ids.joined(separator: ", "))? Android Studio or sdkmanager downloads one again when needed.") else { print("Nothing was deleted."); break }
            for id in ids { print("\(id): \(await engine.deleteSystemImage(id, confirmed: true, initiator: .cli).map { "not deleted, \($0)" } ?? "deleted")") }
            break
        }
        let images = await engine.androidSystemImages()
        if arguments.json { Out.json(images); break }
        guard !images.isEmpty else { print("No Android system images found."); break }
        Out.table(["SIZE", "IMAGE", "USED BY"], images.map { [Bytes.format($0.bytes), $0.id, $0.usedBy.isEmpty ? "no emulator" : Out.truncate($0.usedBy.joined(separator: ", "), 70)] })
        let unused = images.filter { $0.usedBy.isEmpty }
        let settings = await engine.currentSettings()
        print("\n\(unused.count) not used by any emulator, \(Bytes.format(unused.reduce(0) { $0 + $1.bytes })). `pepel disk images delete <image>` removes one; daily rule: \(settings.cleanUnusedSystemImages ? "on" : "off") (cleanUnusedSystemImages).")
        break
    }
    if arguments.positional.first == "emulators" {
        let verb = arguments.positional.dropFirst().first
        if verb == "keep" || verb == "unkeep" {
            let names = Array(arguments.positional.dropFirst(2))
            guard !names.isEmpty else { Out.error("usage: pepel disk emulators keep|unkeep <name> …"); exit(2) }
            _ = try await engine.update { s in
                for name in names {
                    s.keepEmulators.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
                    if verb == "keep" { s.keepEmulators.append(name) }
                }
            }
            print(verb == "keep" ? "The daily rule will never delete \(names.joined(separator: ", "))." : "\(names.joined(separator: ", ")) no longer kept.")
            break
        }
        if verb == "delete" {
            let names = Array(arguments.positional.dropFirst(2))
            guard !names.isEmpty else { Out.error("usage: pepel disk emulators delete <name> … [--yes]"); exit(2) }
            guard arguments.flags.contains("yes") || Out.confirm("Delete \(names.joined(separator: ", ")) for good? Apps and data inside are lost.") else { print("Nothing was deleted."); break }
            for name in names {
                let refusal = await engine.deleteAndroidEmulator(name, confirmed: true, initiator: .cli)
                print("\(name): \(refusal.map { "not deleted, \($0)" } ?? "deleted")")
            }
            break
        }
        let emulators = await engine.androidEmulators()
        if arguments.json { Out.json(emulators); break }
        guard !emulators.isEmpty else { print("No Android emulators in ~/.android/avd."); break }
        let candidates = Set(await engine.emulatorRuleCandidates().map(\.name))
        Out.table(
            ["SIZE", "LAST USED", "", "TARGET", "NAME"],
            emulators.map { emulator in
                let kept = settings.keepEmulators.contains { $0.caseInsensitiveCompare(emulator.name) == .orderedSame }
                return [
                    Bytes.format(emulator.bytes), emulator.lastUse.map { TimeFormat.ago($0) } ?? "—",
                    emulator.running ? "running" : kept ? "kept" : candidates.contains(emulator.name) ? "rule would delete" : "",
                    emulator.target ?? "—", emulator.name,
                ]
            })
        print("\n\(emulators.count) emulators, \(Bytes.format(emulators.reduce(0) { $0 + $1.bytes })). `pepel disk emulators delete <name>` deletes one, as Android Studio does; apps and data inside are lost.")
        print("Daily rule: \(settings.cleanAndroidEmulators ? "on" : "off") (cleanAndroidEmulators), after \(settings.emulatorUnusedDays) days without a start (emulatorUnusedDays); `pepel disk emulators keep <name>` excludes one.")
        break
    }
    if arguments.positional.first == "temp" {
        let days = arguments.options["days"].flatMap { Int($0) } ?? settings.tempDays
        print("Looking through the temporary folder…")
        let entries = await engine.tempEntries(days: days)
        if arguments.json { Out.json(entries); break }
        let removable = entries.filter { $0.keptBecause == nil }
        print("\(PathUtil.display(appPaths.temporaryDirectory, home: appPaths.home)): \(entries.count) entries, \(Bytes.format(entries.reduce(0) { $0 + $1.bytes })). Unused for \(days)+ days: \(removable.count) entries, \(Bytes.format(removable.reduce(0) { $0 + $1.bytes })).\n")
        Out.table(
            ["SIZE", "LAST USED", "", "NAME"],
            entries.prefix(15).map { [Bytes.format($0.bytes), TimeFormat.ago($0.lastUse), $0.keptBecause == nil ? "would go" : Out.truncate($0.keptBecause ?? "", 46), Out.truncate($0.name, 50)] })
        guard arguments.positional.dropFirst().first == "clean" else {
            print("\n`pepel disk temp clean` removes what is unused (--days N to change the age). Automatic daily cleaning is \(settings.cleanTempFiles ? "on" : "off") (cleanTempFiles).")
            break
        }
        guard !removable.isEmpty else { print("\nNothing to remove."); break }
        guard arguments.flags.contains("yes") || Out.confirm("Remove \(removable.count) entries unused for \(days) days?") else { print("Nothing was removed."); break }
        let result = await engine.cleanTemp(days: days, confirmed: true, initiator: .cli)
        print(result.denial.map { "Not done: \($0)" } ?? "Removed \(result.removed) entries, \(Bytes.format(result.bytes)).")
        break
    }
    if arguments.positional.first == "logs" {
        let days = arguments.options["days"].flatMap { Int($0) } ?? settings.logDays
        let found = await engine.oldLogs(days: days)
        print("\(found.count) log files in ~/Library/Logs are older than \(days) days and larger than 1 MB: \(Bytes.format(found.bytes)). Agents' own logs are not counted.")
        guard arguments.positional.dropFirst().first == "clean", found.count > 0 else { break }
        guard arguments.flags.contains("yes") || Out.confirm("Remove them?") else { print("Nothing was removed."); break }
        let result = await engine.removeOldLogs(days: days, confirmed: true, initiator: .cli)
        print(result.denial.map { "Not done: \($0)" } ?? "Removed \(result.removed) files, \(Bytes.format(result.bytes)).")
        break
    }
    let live = await engine.refreshLive()
    let t = live.telemetry
    print("Disk: \(Bytes.format(t.diskAvailableBytes)) available of \(Bytes.format(t.diskTotalBytes)).")
    print(engine.diskForecast()?.sentence() ?? "No forecast: the disk has not been filling steadily, or PEPEL has less than two days of readings.")
    print("\nMeasuring other large places…")
    let places = await engine.otherPlaces()
    if arguments.json { Out.json(places); break }
    Out.table(
        ["SIZE", "LAST USED", "", "WHAT", "WHERE"],
        places.prefix(arguments.flags.contains("all") ? 10_000 : 25).map { [Bytes.format($0.bytes), $0.lastUse.map { TimeFormat.ago($0) } ?? "—", $0.kept ? "kept" : "", Out.truncate($0.title, 44), PathUtil.display($0.path, home: appPaths.home)] })
    print("\nPEPEL shows these and does not remove them: each has its own way of being managed. See also `pepel docker`, `pepel caches`, `pepel apps caches`, `pepel projects stale`, `pepel disk logs`.")

case "caches":
    let settings = await engine.currentSettings()
    let days = arguments.options["days"].flatMap { Int($0) } ?? settings.cacheUnusedDays
    if arguments.positional.first == "trim" {
        let chosen = Set(arguments.positional.dropFirst())
        let ids: Set<String>? = chosen.isEmpty || chosen.contains("all") ? nil : chosen
        if let ids, let unknown = ids.first(where: { id in !CacheTrimmer.caches.contains { $0.id == id } }) { Out.error("no cache named '\(unknown)'; see `pepel caches`"); exit(2) }
        guard arguments.flags.contains("yes") || Out.confirm("Remove what has not been used for \(days) days from \(ids.map { $0.sorted().joined(separator: ", ") } ?? "all tool caches")?") else { print("Nothing was removed."); break }
        let result = await engine.trimCaches(ids: ids, days: days, limitGB: arguments.options["limit"].flatMap { Int($0) }, confirmed: true, initiator: .cli)
        if let denial = result.denial { print("Not done: \(denial)"); exit(3) }
        if let report = result.report {
            for step in report.steps { print("\(step.title): \(Bytes.format(step.bytes)) in \(step.removed) entries") }
            print(report.steps.isEmpty ? "Nothing in them has been unused for \(days) days." : "Removed \(Bytes.format(report.bytes)). Disk available: \(Bytes.format(report.diskAvailableBefore)) → \(Bytes.format(report.diskAvailableAfter)).")
        }
        break
    }
    print("Measuring tool caches…")
    let caches = await engine.managedCaches(days: days)
    if arguments.json { Out.json(caches); break }
    Out.table(
        ["ID", "SIZE", "UNUSED \(days)+ DAYS", "ENTRIES", "CACHE", "WHERE"],
        caches.map { [$0.id, Bytes.format($0.totalBytes), Bytes.format($0.staleBytes), "\($0.staleCount) of \($0.fileCount)", $0.title, PathUtil.display($0.path, home: appPaths.home)] })
    print("\nTotal \(Bytes.format(caches.reduce(0) { $0 + $1.totalBytes })), of which \(Bytes.format(caches.reduce(0) { $0 + $1.staleBytes })) has not been used for \(days) days.")
    print("`pepel caches trim [<id> …]` removes only that part (--days N to change the age; --limit GB also cuts each cache down to that size, least recently used first).")
    print("Automatic daily trimming is \(settings.trimCaches ? "on" : "off") (trimCaches); size limit per cache: \(settings.cacheSizeLimitGB > 0 ? "\(settings.cacheSizeLimitGB) GB" : "none") (cacheSizeLimitGB). Gradle cleans its own caches and is left to it.")

case "docker":
    let settings = await engine.currentSettings()
    let days = arguments.options["days"].flatMap { Int($0) } ?? settings.dockerUnusedDays
    if arguments.positional.first == "volumes" {
        guard let volumes = await engine.namedVolumes() else { Out.error("Docker did not answer"); exit(1) }
        if arguments.json { Out.json(volumes); break }
        guard !volumes.isEmpty else { print("Every named volume is mounted by a container."); break }
        Out.table(
            ["SIZE", "CREATED", "PROJECT", "PROJECT FOLDER", "VOLUME"],
            volumes.map {
                [
                    Bytes.format($0.bytes), $0.createdAt.map { TimeFormat.ago($0) } ?? "—", $0.project ?? "—",
                    $0.projectState == .gone ? "gone: " + PathUtil.display($0.projectFolder ?? "", home: appPaths.home) : $0.projectState == .present ? "on this Mac" : "—",
                    Out.truncate($0.name, 48),
                ]
            })
        let gone = volumes.filter { $0.projectState == .gone }
        print("\n\(volumes.count) named volumes no container mounts, \(Bytes.format(volumes.reduce(0) { $0 + $1.bytes })); \(gone.count) belong to a project whose folder is gone (\(Bytes.format(gone.reduce(0) { $0 + $1.bytes }))).")
        print("PEPEL never removes named volumes. To remove one yourself: docker volume rm <volume>")
        break
    }
    if arguments.positional.first == "compact" {
        let outcome = engine.dockerDiskCompact()
        print(outcome.done ? "Trimmed: \(outcome.note)" : "Not compacted: \(outcome.note)")
        break
    }
    guard let (report, plan) = await engine.dockerCleanupPlan(days: days) else { Out.error("Docker did not answer"); exit(1) }
    if arguments.positional.first == "clean" {
        let wanted = arguments.positional.dropFirst().first ?? "all"
        let kinds: Set<DockerCleanKind>
        switch wanted {
        case "all": kinds = [.containers, .images, .buildCache, .networks]
        case "containers": kinds = [.containers]
        case "images": kinds = [.images]
        case "cache": kinds = [.buildCache]
        case "networks": kinds = [.networks]
        case "volumes": kinds = [.volumes]
        default: Out.error("usage: pepel docker clean [all|containers|images|cache|networks|volumes] [--days N] [--yes]"); exit(2)
        }
        for kind in DockerCleanKind.allCases where kinds.contains(kind) && kind != .networks {
            print("\(kind.title): \(plan.count(kind)), \(Bytes.format(plan.bytes(kind)))")
        }
        if kinds.contains(.volumes) {
            for volume in plan.volumes.sorted(by: { $0.sizeBytes > $1.sizeBytes }).prefix(15) {
                print("  \(Bytes.format(volume.sizeBytes))  \(volume.isAnonymous ? "anonymous " + String(volume.name.prefix(12)) : volume.name)\(volume.composeProject.map { " (\($0))" } ?? "")")
            }
            print("Only anonymous volumes that no container mounts: what removed containers left behind. Named volumes are never removed by PEPEL. This cannot be undone.")
        }
        guard kinds.contains(where: { plan.count($0) > 0 }) || kinds.contains(.networks) else { print("Nothing has been unused for \(days) days."); break }
        guard arguments.flags.contains("yes") || Out.confirm("Remove these from Docker?") else { print("Nothing was removed."); break }
        let result = await engine.cleanDocker(kinds: kinds, days: days, confirmed: true, initiator: .cli)
        if let denial = result.denial { print("Not done: \(denial)"); exit(3) }
        if let done = result.report {
            for step in done.steps {
                print("\(step.kind.title): \(step.removed) of \(step.attempted)")
                for note in step.notes { print("    \(note)") }
            }
            print("Docker reports \(Bytes.format(done.dockerBytesBefore)) → \(Bytes.format(done.dockerBytesAfter)). Its disk image on this Mac: \(Bytes.format(done.diskImageBefore)) → \(Bytes.format(done.diskImageAfter)) (\(Bytes.formatDelta(-done.freedOnDisk))).")
            print(done.compacted ? "Trimmed: \(done.compactNote)" : "Not trimmed: \(done.compactNote)")
        }
        break
    }
    if arguments.json {
        struct Both: Encodable { var report: DockerDiskReport, plan: DockerCleanupPlan }
        Out.json(Both(report: report, plan: plan))
        break
    }
    let stopped = report.containers.filter { !$0.isRunning }
    print("Docker's disk image takes \(Bytes.format(report.diskImageBytes)) on this Mac" + (report.diskImageLimitBytes > 0 ? " and may grow to \(Bytes.format(report.diskImageLimitBytes)). Lowering that limit in Docker Desktop deletes the disk image with everything in it, so PEPEL does not change it." : ".") + "\n")
    Out.table(
        ["KIND", "HAS", "SIZE", "UNUSED \(days)+ DAYS", "WOULD FREE"],
        [
            ["Stopped containers", String(stopped.count), Bytes.format(stopped.reduce(0) { $0 + $1.sizeBytes }), String(plan.containers.count), Bytes.format(plan.bytes(.containers))],
            ["Images", String(report.images.count), Bytes.format(report.imageBytes), String(plan.images.count), Bytes.format(plan.bytes(.images))],
            ["Build cache", String(report.buildCache.count), Bytes.format(report.buildCacheBytes), String(plan.buildCacheEntries), Bytes.format(plan.bytes(.buildCache))],
            ["Volumes", String(report.volumes.count), Bytes.format(report.volumeBytes), String(plan.volumes.count) + " anonymous, unmounted", Bytes.format(plan.bytes(.volumes))],
        ])
    for line in plan.skipped { print("  · \(line)") }
    print("\n`pepel docker clean` removes containers, images, build cache and networks unused for \(days) days (--days N to change), then trims the disk image.")
    print("`pepel docker volumes` lists named volumes no container mounts (a report).")
    print("`pepel docker clean volumes` is separate and takes anonymous volumes only; named volumes are never removed. Automatic daily cleanup is \(settings.dockerAutoClean ? "on" : "off") (dockerAutoClean).")

case "journal":
    let journal = engine.journal
    let files = journal.files()
    if arguments.positional.first == "path" { print(journal.directory); break }
    let days = arguments.options["days"].flatMap { Double($0) } ?? 7
    let digest = engine.journalDigest(days: days)
    if arguments.json { Out.json(digest); break }
    let settings = await engine.currentSettings()
    print("Journal: \(PathUtil.display(journal.directory, home: appPaths.home)) — \(files.count) day\(files.count == 1 ? "" : "s"), \(Bytes.format(files.reduce(0) { $0 + $1.bytes })), \(settings.journalEnabled ? "a reading every five minutes while the PEPEL app runs, kept \(settings.journalRetentionDays) days" : "switched off").")
    guard digest.samples > 0, let from = digest.from, let to = digest.to else { print("No readings in the last \(Int(days)) days yet."); break }
    func range(_ r: JournalDigest.Range) -> String { "\(Bytes.format(r.min)) – \(Bytes.format(r.max)), average \(Bytes.format(r.average))" }
    func percent(_ shares: [String: Double]) -> String { shares.sorted { $0.value > $1.value }.map { "\($0.key) \(Int(($0.value * 100).rounded()))%" }.joined(separator: ", ") }
    print("\n\(digest.samples) readings from \(from.formatted(date: .abbreviated, time: .shortened)) to \(to.formatted(date: .abbreviated, time: .shortened)).\n")
    print("Memory in use  \(range(digest.used))")
    print("Wired          \(range(digest.wired))")
    print("Compressed     \(range(digest.compressed))")
    print("Swap           \(range(digest.swap))")
    print("Pressure       \(percent(digest.pressure))")
    print("\nWho held memory (average while present):")
    Out.table(
        ["AVERAGE", "PEAK", "CHANGE", "PRESENT", "KIND", "OWNER"],
        digest.owners.prefix(12).map { [Bytes.format($0.memory.average), Bytes.format($0.memory.max), Bytes.formatDelta($0.change), "\(Int(($0.presence * 100).rounded()))%", $0.kind, Out.truncate($0.name, 40)] })
    print("\nAgents: \(digest.agentSessions.min)–\(digest.agentSessions.max) sessions at a time (average \(digest.agentSessions.average)), holding \(range(digest.agentMemory)). States: \(percent(digest.agentStates)).")
    Out.table(
        ["AVERAGE", "PEAK", "PRESENT", "KIND", "AGENT · PROJECT"],
        digest.agents.prefix(12).map { [Bytes.format($0.memory.average), Bytes.format($0.memory.max), "\(Int(($0.presence * 100).rounded()))%", $0.kind, Out.truncate($0.name, 50)] })
    if digest.browsers.isEmpty {
        print("\nBrowsers: none seen.")
    } else {
        print("\nBrowsers: \(digest.browserTabs.min)–\(digest.browserTabs.max) tab processes of 150 MB or more; idle ones held \(range(digest.idleTabMemory)).")
        Out.table(["AVERAGE", "PEAK", "CHANGE", "PRESENT", "BROWSER"], digest.browsers.map { [Bytes.format($0.memory.average), Bytes.format($0.memory.max), Bytes.formatDelta($0.change), "\(Int(($0.presence * 100).rounded()))%", $0.name] })
    }
    if !digest.actions.isEmpty { print("\nWhat PEPEL did: " + digest.actions.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key) ×\($0.value)" }.joined(separator: ", ") + ".") }
    if digest.forecasts > 0 { print("A shortage was forecast in \(digest.forecasts) reading\(digest.forecasts == 1 ? "" : "s").") }

case "plan":
    // What the daily rules will act on next; `leave` takes an item out, `forget` puts it back.
    let verb = arguments.positional.first
    if verb == "leave" || verb == "forget", arguments.positional.count >= 2 {
        var key = arguments.positional.dropFirst().joined(separator: " ")
        if key.hasPrefix("/") || key.hasPrefix("~") { key = RuleAction.pathKey(PathUtil.canonical(key, home: appPaths.home)) }
        let settings = try await engine.setLeftAlone([key], verb == "leave")
        print(verb == "leave" ? "The daily rules will leave \(key) alone." : "The daily rules may act on \(key) again.")
        print("Leave-alone list: \(settings.leaveAlone.count) item\(settings.leaveAlone.count == 1 ? "" : "s").")
        break
    } else if verb != nil {
        Out.error("usage: pepel plan [leave <id or path> | forget <id or path>]"); exit(2)
    }
    if isatty(STDERR_FILENO) != 0 && !arguments.json { FileHandle.standardError.write(Data("Looking at what each rule would touch…\r".utf8)) }
    _ = await engine.refreshLive()
    let plan = await engine.actionPlan()
    if isatty(STDERR_FILENO) != 0 && !arguments.json { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
    if arguments.json { Out.json(plan); break }
    for note in plan.notes { print(note) }
    if plan.actions.isEmpty { print("No daily rule has anything to do right now."); break }
    print("Next 24 hours: \(plan.actions.count) item\(plan.actions.count == 1 ? "" : "s"), up to \(Bytes.format(plan.bytes)).\n")
    Out.table(
        ["WHEN", "RULE", "SIZE", "DOES", "ITEM", "ID (for leave)"],
        plan.actions.prefix(arguments.flags.contains("all") ? 10_000 : 60).map {
            let wait = $0.due.timeIntervalSinceNow
            return [wait < 120 ? "next pass" : "in " + TimeFormat.age(wait), $0.rule.title, Bytes.format($0.bytes), $0.verb, Out.truncate($0.title, 40), Out.truncate($0.id.hasPrefix("path:") ? PathUtil.display(String($0.id.dropFirst(5)), home: appPaths.home) : $0.id, 60)]
        })
    if plan.actions.count > 60, !arguments.flags.contains("all") { print("… \(plan.actions.count - 60) more (use --all)") }
    print("\n`pepel plan leave <id or path>` keeps the rules off one item.")

case "restore":
    if let first = arguments.positional.first {
        guard let id = Int64(first) else { Out.error("usage: pepel restore [<number>]"); exit(2) }
        if let problem = engine.restoreTrashed(id: id) { Out.error(problem); exit(1) }
        print("Put back.")
        break
    }
    let days = arguments.options["days"].flatMap { Int($0) } ?? 14
    let center = engine.restoreCenter(days: days)
    if arguments.json { Out.json(center); break }
    if center.restorable.isEmpty {
        print("Nothing PEPEL moved to the Trash in the last \(days) days is waiting there.")
    } else {
        print("Can be put back (`pepel restore <number>`):")
        Out.table(["NUMBER", "SIZE", "WHEN", "BY", "FROM"], center.restorable.map { ["\($0.id)", Bytes.format($0.bytes), TimeFormat.ago($0.at), $0.source, Out.truncate(PathUtil.display($0.originalPath, home: appPaths.home), 70)] })
    }
    if !center.gone.isEmpty { print("\n\(center.gone.count) trashed item\(center.gone.count == 1 ? " is" : "s are") no longer in the Trash, or their place is taken again.") }
    if !center.removed.isEmpty {
        print("\nRemoved for good (rebuilt or downloaded again when needed):")
        Out.table(["SIZE", "WHEN", "WHAT"], center.removed.prefix(30).map { [Bytes.format($0.bytes), TimeFormat.ago($0.timestamp), Out.truncate($0.subject, 80)] })
    }

case "self":
    // Two readings a second apart give the CPU share.
    _ = await engine.selfUsage()
    try? await Task.sleep(for: .seconds(1))
    let usage = await engine.selfUsage()
    if arguments.json { Out.json(usage); break }
    if usage.processes.isEmpty { print("The PEPEL app is not running."); break }
    Out.table(["PID", "MEMORY", "CPU", "PROCESS"], usage.processes.map { ["\($0.pid)", Bytes.format($0.footprintBytes), $0.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "—", $0.name] })
    print(usage.heavyTasks.isEmpty ? "\nNo heavy job is running." : "\nRunning: " + usage.heavyTasks.joined(separator: ", ") + ".")
    let settings = await engine.currentSettings()
    if let warning = usage.warning(memoryLimitMB: settings.selfMemoryWarnMB) { print(warning) }

case "startup":
    let verb = arguments.positional.first
    if verb == "disable" || verb == "enable", arguments.positional.count == 2 {
        let label = arguments.positional[1], on = verb == "enable"
        guard let item = await engine.startupItems().first(where: { $0.label == label }) else { Out.error("no startup item is called \(label)"); exit(1) }
        if let refusal = item.managementRefusal { Out.error(refusal); exit(1) }
        let question = on
            ? "Switch \(label) on? It is loaded now and starts as its property list says (\(item.schedule))."
            : "Switch \(label) off?\(item.isRunning ? " It stops now (\(Bytes.format(item.footprintBytes)))." : "") It will not start at login; the property list stays."
        guard arguments.flags.contains("yes") || Out.confirm(question) else { print("Nothing changed."); break }
        if let problem = await engine.setStartupItem(label, enabled: on, confirmed: true, initiator: .cli) { Out.error(problem); exit(1) }
        print(on ? "\(label) is switched on." : "\(label) is switched off.")
        break
    } else if verb != nil {
        Out.error("usage: pepel startup [disable|enable <label>] [--yes]"); exit(2)
    }
    let items = await engine.startupItems()
    if arguments.json { Out.json(items); break }
    let running = items.filter(\.isRunning)
    print("\(items.filter { !$0.disabled }.count) start on their own, \(running.count) running now, holding \(Bytes.format(running.reduce(0) { $0 + $1.footprintBytes })).")
    for kind in StartupItem.Kind.allCases {
        let group = items.filter { $0.kind == kind }
        guard !group.isEmpty else { continue }
        print("\n\(kind.title.uppercased())")
        Out.table(
            ["STATE", "MEMORY", "STARTS", "OWNER", "LABEL"],
            group.map {
                [$0.disabled ? "off" : $0.isRunning ? "running" : $0.loaded ? "loaded" : "—", $0.isRunning && $0.processCount > 0 ? Bytes.format($0.footprintBytes) : "", $0.schedule, Out.truncate($0.owner, 28), $0.label]
            })
    }
    print("\nApps that open at login are listed in System Settings › General › Login Items.")

case "login":
    // macOS registers a login item only for the app itself; the app applies this setting as soon as it sees it.
    if let verb = arguments.positional.first {
        guard verb == "on" || verb == "off" else { Out.error("usage: pepel login [on|off]"); exit(2) }
        _ = try await engine.update { $0.launchAtLogin = verb == "on" }
    }
    let on = await engine.currentSettings().launchAtLogin
    if arguments.json { Out.json(["launchAtLogin": on]); break }
    print(on ? "PEPEL starts when you log in." : "PEPEL does not start at login.")
    if arguments.positional.first != nil {
        print("The running PEPEL app registers the change with macOS within a few seconds; if macOS asks, approve it in System Settings › General › Login Items.")
    }

case "preset":
    let settings = await engine.currentSettings()
    guard let name = arguments.positional.first else {
        print("Rule set: \(SettingsPreset.matching(settings)?.title ?? "custom (tuned by hand)").\n")
        for preset in SettingsPreset.allCases { print("  \(preset.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) \(preset.summary)") }
        print("\n`pepel preset <name>` shows what would change and asks before switching.")
        break
    }
    guard let preset = SettingsPreset(rawValue: name.lowercased()) else { Out.error("unknown rule set '\(name)'; one of careful, normal, aggressive"); exit(2) }
    let changes = preset.changes(from: settings)
    if changes.isEmpty { print("The rules are already at \(preset.title)."); break }
    print("\(preset.title): \(preset.summary)\n")
    for change in changes { print("  \(change)") }
    guard arguments.flags.contains("yes") || Out.confirm("Switch to \(preset.title)?") else { print("Nothing changed."); break }
    _ = try await engine.update { preset.apply(to: &$0) }
    print("Switched to \(preset.title).")

case "summary":
    let configured = await engine.currentSettings().summaryFrequency
    let hours = arguments.options["hours"].flatMap { Double($0) } ?? (configured == .daily ? 24 : 24 * 7)
    let summary = await engine.summary(hours: hours)
    if arguments.json { Out.json(summary); break }
    print("Last \(TimeFormat.age(hours * 3600)): \(summary.headline)\n")
    for line in summary.done { print("  · \(line)") }
    if !summary.open.isEmpty {
        print("\nStill there:")
        for line in summary.open { print("  · \(line)") }
    }

case "budget":
    var settings = await engine.currentSettings()
    let verb = arguments.positional.first
    if verb == "set", arguments.positional.count >= 3, let gb = Double(arguments.positional.last ?? ""), gb > 0 {
        let match = arguments.positional.dropFirst().dropLast().joined(separator: " ")
        settings = try await engine.update { s in
            s.memoryBudgets.removeAll { $0.id == match.lowercased() }
            s.memoryBudgets.append(MemoryBudget(match: match, bytes: Int64(gb * Double(Bytes.gb))))
        }
        print("Budget for \(match): \(Bytes.format(Int64(gb * Double(Bytes.gb)))).")
    } else if verb == "remove", arguments.positional.count >= 2 {
        let match = arguments.positional.dropFirst().joined(separator: " ")
        settings = try await engine.update { $0.memoryBudgets.removeAll { $0.id == match.lowercased() } }
        print("Removed the budget for \(match).")
    } else if verb != nil {
        Out.error("usage: pepel budget [set <owner name or kind:agentSession> <GB> | remove <name>]"); exit(2)
    }
    let live = await engine.refreshLive()
    if arguments.json { Out.json(live.overBudget); break }
    if settings.memoryBudgets.isEmpty {
        print("No memory budgets. `pepel budget set <owner> <GB>` sets one for an owner from `pepel memory` (by name), or for every owner of a kind with kind:agentSession, kind:application, kind:project.")
        break
    }
    Out.table(["BUDGET", "FOR"], settings.memoryBudgets.map { [Bytes.format($0.bytes), $0.match] })
    if live.overBudget.isEmpty {
        print("\nNothing is over its budget.")
    } else {
        print("\nOver budget:")
        Out.table(["HOLDS", "BUDGET", "OVER BY", "KIND", "OWNER"], live.overBudget.map { [Bytes.format($0.footprintBytes), Bytes.format($0.budgetBytes), Bytes.format($0.excessBytes), $0.kind.rawValue, $0.name] })
    }

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
