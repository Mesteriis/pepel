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

case "agents":
    let live = await engine.refreshLive()
    if arguments.json { Out.json(live.agentSessions); break }
    let settings = await engine.currentSettings()
    if live.agentSessions.isEmpty { print("No agent sessions are running.") }
    Out.table(
        ["PID", "AGENT", "STATE", "QUIET FOR", "MEMORY", "PROCS", "PROJECT", "WHY"],
        live.agentSessions.map {
            [
                String($0.root.pid), $0.kind.displayName + ($0.isService ? " (server)" : ""), $0.state.rawValue,
                $0.quietSince.map { TimeFormat.age(Date().timeIntervalSince($0)) } ?? "—", Bytes.format($0.footprintBytes),
                String($0.processCount), Out.truncate($0.projectID.map { ($0 as NSString).lastPathComponent } ?? "—", 18),
                Out.truncate($0.evidence.first ?? "", 90),
            ]
        })
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
    guard let target = live.assessments.first(where: { $0.process.pid == pid }) else {
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
