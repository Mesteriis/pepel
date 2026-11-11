import Charts
import PEPELEngine
import SwiftUI

struct HistorySection: View {
    @Environment(AppModel.self) private var model
    @State private var kind: AuditKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "History", subtitle: "Recorded measurements only. Growth figures say how far back the data actually reaches.")
            growth
            chart
            log
        }
        .onAppear { model.refreshSecondary() }
    }

    private func figure(_ label: String, _ value: GrowthFigure?) -> some View {
        MetricTile(
            label: label, value: value.map { Bytes.formatDelta($0.deltaBytes) } ?? "—",
            detail: value.map { $0.coversWindow ? "disk usage change" : "only \(TimeFormat.age($0.actualSpan)) of history" } ?? "no history yet",
            tint: (value?.deltaBytes ?? 0) > 0 ? Theme.amber : Theme.forest)
    }

    private var growth: some View {
        HStack(spacing: 10) {
            figure("Last hour", model.growth?.hour)
            figure("Last day", model.growth?.day)
            figure("Last week", model.growth?.week)
            MetricTile(
                label: "Sudden spikes · 7 d", value: "\(model.growth?.spikes.count ?? 0)",
                detail: model.growth?.spikes.last.map { "latest \(Bytes.formatDelta($0.deltaBytes)) \(TimeFormat.ago($0.at))" } ?? "none recorded")
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("Disk usage and reclaimable storage · 7 days")
            if model.telemetryHistory.count < 2 {
                Text("The trend appears once PEPEL has recorded a few samples (one every five minutes while it runs).").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            } else {
                Chart {
                    ForEach(model.telemetryHistory) { point in
                        LineMark(x: .value("Time", point.timestamp), y: .value("GB", Double(point.diskUsed) / 1e9), series: .value("Series", "Disk used"))
                            .foregroundStyle(Theme.forest).interpolationMethod(.monotone)
                    }
                    ForEach(model.telemetryHistory.filter { $0.reclaimable != nil }) { point in
                        LineMark(x: .value("Time", point.timestamp), y: .value("GB", Double(point.reclaimable ?? 0) / 1e9), series: .value("Series", "Reclaimable"))
                            .foregroundStyle(Theme.copper).interpolationMethod(.monotone)
                    }
                }
                .chartYAxisLabel("GB")
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 170)
                HStack(spacing: 12) {
                    Label("Disk used", systemImage: "circle.fill").foregroundStyle(Theme.forest)
                    Label("Reclaimable (as of each scan)", systemImage: "circle.fill").foregroundStyle(Theme.copper)
                }
                .font(.system(size: 10))
            }
        }
        .panel()
    }

    private var log: some View {
        let entries = model.audit.filter { kind == nil || $0.kind == kind }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Caption("Audit log")
                Spacer()
                Picker("Kind", selection: $kind) {
                    Text("Everything").tag(AuditKind?.none)
                    Text("Cleanup").tag(AuditKind?.some(.cleanup))
                    Text("Previews").tag(AuditKind?.some(.cleanupPreview))
                    Text("Skipped").tag(AuditKind?.some(.cleanupDenied))
                    Text("Terminations").tag(AuditKind?.some(.termination))
                    Text("Scans").tag(AuditKind?.some(.scan))
                    Text("Agents").tag(AuditKind?.some(.agent))
                }
                .labelsHidden().frame(width: 150)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if entries.isEmpty {
                Text("Nothing recorded yet.").font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(12)
            }
            LazyVStack(spacing: 0) {
                ForEach(entries.prefix(200)) { entry in
                    Divider().overlay(Theme.stroke.opacity(0.6))
                    HStack(spacing: 10) {
                        Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.tertiary).frame(width: 118, alignment: .leading)
                        Badge(text: entry.kind.rawValue, tint: entry.kind == .cleanup || entry.kind == .termination ? Theme.copper : Theme.secondary).frame(width: 104, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.subject).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
                            Text(entry.outcome + (entry.detail["observedChange"].map { " · memory \($0)" } ?? "")).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Text(entry.initiator).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                        if entry.bytes > 0 { Text(Bytes.format(entry.bytes)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.text).frame(width: 66, alignment: .trailing) }
                        if entry.outcome == "trashed", let trashed = entry.detail["trashedTo"], PathUtil.exists(trashed) {
                            Button("Restore") { model.restore(entry) }.buttonStyle(CopperButtonStyle(prominent: false))
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                }
            }
        }
        .panel(padding: 0)
    }
}

struct SettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var newRule = ""
    @State private var newRuleKind = ProtectionKind.path
    @State private var newKeep = ""
    @State private var newKeepApp = ""
    @State private var budgetKind = ""
    @State private var budgetName = ""
    @State private var budgetGB = 4
    @State private var vmLimitGiB = 8
    @State private var overrideProject = ""

    var body: some View {
        let s = model.settings
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "Settings")
            group("Project roots", "Folders PEPEL searches for repositories. Nothing outside them, the known cache locations and DerivedData is examined.") {
                ForEach(s.projectRoots, id: \.self) { root in
                    HStack {
                        PathText(path: PathUtil.expand(root))
                        Spacer()
                        Button("Remove") { model.updateSettings { $0.projectRoots.removeAll { $0 == root } } }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
                if s.projectRoots.isEmpty { Text("No roots configured.").font(.system(size: 12)).foregroundStyle(Theme.amber) }
                HStack {
                    Button("Add folder…") { chooseFolder { path in model.updateSettings { if !$0.projectRoots.contains(path) { $0.projectRoots.append(path) } } } }.buttonStyle(QuietButtonStyle())
                    Button("Register single project…") { chooseFolder { path in model.updateSettings { if !$0.registeredProjects.contains(path) { $0.registeredProjects.append(path) } } } }.buttonStyle(QuietButtonStyle())
                    Button("Exclude folder…") { chooseFolder { path in model.updateSettings { if !$0.excludedPaths.contains(path) { $0.excludedPaths.append(path) } } } }.buttonStyle(QuietButtonStyle())
                }
                stepper("Look for repositories up to", s.discoveryDepth, 1...12, suffix: " folders deep") { v in model.updateSettings { $0.discoveryDepth = v } }
                ForEach(s.registeredProjects, id: \.self) { path in line("Registered", path) { model.updateSettings { $0.registeredProjects.removeAll { $0 == path } } } }
                ForEach(s.excludedPaths, id: \.self) { path in line("Excluded", path) { model.updateSettings { $0.excludedPaths.removeAll { $0 == path } } } }
            }

            group("Monitoring", "How much PEPEL does on its own.") {
                picker("Mode", selection: s.monitoringMode, options: [(.manual, "Manual"), (.notifyOnly, "Notify only"), (.automaticSafe, "Automatic safe cleanup")]) { value in model.updateSettings { $0.monitoringMode = value } }
                Text(modeHelp(s.monitoringMode)).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                toggle("Pause all monitoring", s.paused) { v in model.updateSettings { $0.paused = v } }
                toggle("Work less on battery", s.batteryAware) { v in model.updateSettings { $0.batteryAware = v } }
                toggle("Notifications", s.notificationsEnabled) { v in model.updateSettings { $0.notificationsEnabled = v } }
                HStack(spacing: 8) {
                    toggle("Quiet hours", s.quietHours.enabled) { v in model.updateSettings { $0.quietHours.enabled = v } }
                    stepper("from", s.quietHours.startHour, 0...23, suffix: ":00") { v in model.updateSettings { $0.quietHours.startHour = v } }
                    stepper("to", s.quietHours.endHour, 0...23, suffix: ":00") { v in model.updateSettings { $0.quietHours.endHour = v } }
                }
                picker("Menu bar shows", selection: s.menuBarMode, options: [(.reclaimable, "Reclaimable storage"), (.iconOnly, "Icon only"), (.memoryPressure, "Memory pressure"), (.activeBuilds, "Active builds")]) { value in model.updateSettings { $0.menuBarMode = value } }
                Toggle("Launch PEPEL at login", isOn: Binding(get: { LoginItem.isEnabled }, set: { model.setLaunchAtLogin($0) })).font(.system(size: 12)).toggleStyle(.checkbox)
                Text(model.loginItemStatus).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }

            group("Cleanup", "How approved items are removed.") {
                picker("Removal", selection: s.deletionMode, options: [(.automatic, "Safe: remove · Review: Trash"), (.trash, "Always Trash"), (.permanent, "Always remove permanently")]) { value in model.updateSettings { $0.deletionMode = value } }
                Text("Trashed items can be restored but free no space until the Trash is emptied. Permanent removal and tool cleanups cannot be undone.").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                stepper("Treat artifacts written in the last", s.recentWriteProtectionMinutes, 1...240, suffix: " min as in use") { v in model.updateSettings { $0.recentWriteProtectionMinutes = v } }
                stepper("Warn when disk space falls below", Int(s.lowDiskThresholdBytes / Bytes.gb), 5...500, step: 5, suffix: " GB") { v in model.updateSettings { $0.lowDiskThresholdBytes = Int64(v) * Bytes.gb } }
            }

            group("Build retention", "Defaults for every project. Active and pinned builds are always kept.") {
                stepper("Keep the last", s.defaultRetention.keepSuccessful, 1...20, suffix: " builds") { v in model.updateSettings { $0.defaultRetention.keepSuccessful = v } }
                stepper("Keep the last", s.defaultRetention.keepFailed, 0...20, suffix: " failed builds") { v in model.updateSettings { $0.defaultRetention.keepFailed = v } }
                stepper("Review artifacts older than", s.defaultRetention.reviewAfterHours, 1...720, step: 12, suffix: " hours") { v in model.updateSettings { $0.defaultRetention.reviewAfterHours = v } }
                stepper("Per-project build budget", Int((s.defaultRetention.budgetBytes ?? 0) / Bytes.gb), 1...1000, step: 5, suffix: " GB") { v in model.updateSettings { $0.defaultRetention.budgetBytes = Int64(v) * Bytes.gb } }
                stepper("Global build budget", Int(s.globalBuildBudgetBytes / Bytes.gb), 10...2000, step: 10, suffix: " GB") { v in model.updateSettings { $0.globalBuildBudgetBytes = Int64(v) * Bytes.gb } }
                toggle("Treat builds retention marks obsolete as safe (allows automatic cleanup of old generations)", s.retentionCandidatesAreSafe) { v in model.updateSettings { $0.retentionCandidatesAreSafe = v } }
                toggle("Always keep the last build that succeeded", s.defaultRetention.protectLastKnownGood) { v in model.updateSettings { $0.defaultRetention.protectLastKnownGood = v } }
                toggle("Mark builds obsolete by age alone", s.defaultRetention.maxAgeDays != nil) { v in model.updateSettings { $0.defaultRetention.maxAgeDays = v ? 30 : nil } }
                if let days = s.defaultRetention.maxAgeDays {
                    stepper("Obsolete after", days, 1...365, suffix: " days") { v in model.updateSettings { $0.defaultRetention.maxAgeDays = v } }
                }
                Divider().overlay(Theme.stroke)
                Text("Different rules for one project:").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                ForEach(s.projectRetention.keys.sorted(), id: \.self) { key in
                    if let policy = s.projectRetention[key] {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(model.projectName(key) ?? (key as NSString).lastPathComponent).font(.system(size: 12, weight: .medium))
                                Spacer()
                                Button("Remove") { model.updateSettings { $0.projectRetention[key] = nil } }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            }
                            HStack(spacing: 14) {
                                stepper("Keep", policy.keepSuccessful, 1...20, suffix: " builds") { v in model.updateSettings { $0.projectRetention[key]?.keepSuccessful = v } }
                                stepper("and", policy.keepFailed, 0...20, suffix: " failed") { v in model.updateSettings { $0.projectRetention[key]?.keepFailed = v } }
                                stepper("Budget", Int((policy.budgetBytes ?? 0) / Bytes.gb), 1...1000, step: 5, suffix: " GB") { v in model.updateSettings { $0.projectRetention[key]?.budgetBytes = Int64(v) * Bytes.gb } }
                            }
                        }
                    }
                }
                let candidates = (model.storage?.builds ?? []).filter { $0.attributed && s.projectRetention[$0.id] == nil }
                if !candidates.isEmpty {
                    HStack(spacing: 8) {
                        Picker("Project", selection: $overrideProject) {
                            Text("Choose a project").tag("")
                            ForEach(candidates) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().frame(width: 240)
                        Button("Add its own rules") {
                            let key = overrideProject
                            model.updateSettings { $0.projectRetention[key] = $0.defaultRetention }
                            overrideProject = ""
                        }
                        .buttonStyle(QuietButtonStyle()).disabled(overrideProject.isEmpty)
                    }
                }
            }

            group("Free memory", "How the Free memory action can be started without opening the menu, and what it may do without asking.") {
                toggle("Open Free memory with Control-Option-Command-M from anywhere", s.freeMemoryHotkey) { v in model.updateSettings { $0.freeMemoryHotkey = v } }
                toggle("Free memory whenever the screen is locked", s.freeMemoryOnLock) { v in model.updateSettings { $0.freeMemoryOnLock = v } }
                Text("On lock, and from the button on a memory pressure notification, PEPEL runs only the steps that are preselected in the Free memory plan, and never one that would ask for a password.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                stepper("Warn when memory is forecast to run short within", s.forecastWarnMinutes, 0...180, step: 5, suffix: " min (0 = never)") { v in model.updateSettings { $0.forecastWarnMinutes = v } }
                toggle("Under memory pressure, act sooner", s.adaptToMemoryPressure) { v in model.updateSettings { $0.adaptToMemoryPressure = v } }
                Text("Halves the waiting periods of the rules below under elevated pressure and quarters them under critical pressure (never under 30 minutes for an agent session), and lets the Docker VM restart outside its night window, at most every six hours. Only affects rules that are switched on.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let permission = model.fileCachePermission {
                        Text(
                            !permission.available
                                ? "Flushing the file cache is not available here."
                                : permission.granted
                                    ? "PEPEL may flush the file cache without asking for a password."
                                    : "The first file cache flush asks for an administrator once; after that PEPEL does not ask again."
                        )
                        .font(.system(size: 12)).foregroundStyle(Theme.text)
                        Spacer()
                        if permission.granted {
                            Button("Remove permission") { model.revokeFileCachePermission() }.buttonStyle(QuietButtonStyle())
                        }
                    }
                }
                .onAppear { model.refreshFileCachePermission() }
            }

            group("Agent sessions", "What happens to a session that has gone quiet. A working session is never touched.") {
                toggle("Suspend agent sessions that have gone quiet, instead of waiting to end them", s.freezeIdleAgents) { v in model.updateSettings { $0.freezeIdleAgents = v } }
                stepper("Suspend after", s.freezeAfterMinutes, 5...240, step: 5, suffix: " min of quiet") { v in model.updateSettings { $0.freezeAfterMinutes = v } }
                stepper("Look for waiting work every", s.freezePeekMinutes, 2...120, suffix: " min") { v in model.updateSettings { $0.freezePeekMinutes = v } }
                Text("A suspended session keeps everything and continues the moment its application comes to the front. In between PEPEL wakes it briefly to see whether work arrived (a message from another device, a finished task); if so it stays awake. Sessions PEPEL cannot tie to an application, such as ones inside tmux, are never suspended automatically. Quitting or pausing PEPEL wakes everything.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                toggle("Terminate agent sessions that are asleep (no disk writes, CPU bursts, new processes or builds)", s.terminateSleepingAgents) { v in model.updateSettings { $0.terminateSleepingAgents = v } }
                stepper("Call an agent session asleep after", s.agentSleepMinutes, 30...1440, step: 30, suffix: " min of quiet") { v in model.updateSettings { $0.agentSleepMinutes = v } }
                Text("A session waiting for your reply writes nothing either, so it is treated as asleep. Sessions of Claude Code and Codex can be resumed afterwards; text typed but not sent is lost.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                stepper("Inside an agent's server, call an older copy left behind after", s.serviceBranchIdleMinutes, 15...1440, step: 15, suffix: " min idle") { v in model.updateSettings { $0.serviceBranchIdleMinutes = v } }
                Divider().overlay(Theme.stroke)
                Text("PEPEL's note in agents' global instructions (explains that containers may stop and how to take a lease):").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                ForEach(model.instructionFiles) { file in
                    HStack {
                        Badge(text: file.installed ? "installed" : "no note", tint: file.installed ? Theme.forest : Theme.tertiary)
                        Text(file.agent).font(.system(size: 12)).frame(width: 96, alignment: .leading)
                        Text(file.path).font(Theme.mono).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                    }
                }
                HStack {
                    Button("Install or update the note") { model.installInstructions() }.buttonStyle(QuietButtonStyle())
                    Button("Remove it") { model.removeInstructions() }.buttonStyle(QuietButtonStyle()).disabled(!model.instructionFiles.contains { $0.installed })
                }
                .onAppear { model.refreshInstructionFiles() }
            }

            group("Applications", "Leftovers of applications that quit, and applications that stay open unused. Quitting an application is always the ordinary request and always asks you first.") {
                toggle("Terminate what an application leaves running after it quits", s.terminateAppLeftovers) { v in model.updateSettings { $0.terminateAppLeftovers = v } }
                stepper("Wait", s.appLeftoverGraceMinutes, 1...240, suffix: " min after the application quit") { v in model.updateSettings { $0.appLeftoverGraceMinutes = v } }
                Text("Covers helpers and child processes PEPEL saw the application start, or that run from inside its bundle. System-managed components, agent sessions and container runtimes are never included.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                stepper("List an open application as unused after", s.unusedApplicationHours, 1...168, suffix: " h without being in front") { v in model.updateSettings { $0.unusedApplicationHours = v } }
                stepper("Call a browser tab idle after", s.tabIdleMinutes, 5...720, step: 5, suffix: " min without CPU use") { v in model.updateSettings { $0.tabIdleMinutes = v } }
                Text("Never list as unused:").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                ForEach(s.keepApplications, id: \.self) { name in
                    HStack {
                        Badge(text: "keep", tint: Theme.copper)
                        Text(name).font(.system(size: 12)).foregroundStyle(Theme.text)
                        Spacer()
                        Button("Remove") { model.updateSettings { $0.keepApplications.removeAll { $0 == name } } }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
                HStack(spacing: 8) {
                    TextField("application name, for example Telegram", text: $newKeepApp).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(maxWidth: 320)
                    Button("Keep") {
                        let name = newKeepApp.trimmingCharacters(in: .whitespaces)
                        model.updateSettings { if !$0.keepApplications.contains(name) { $0.keepApplications.append(name) } }
                        newKeepApp = ""
                    }
                    .buttonStyle(QuietButtonStyle()).disabled(newKeepApp.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            group("Memory budgets", "A limit for what one owner may hold. Exceeding it raises an alert; PEPEL never ends anything because of a budget.") {
                ForEach(s.memoryBudgets) { budget in
                    HStack {
                        Text(budget.match).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                        Text(Bytes.format(budget.bytes)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.secondary)
                        if let over = model.live?.overBudget.filter({ o in model.live?.memoryOwners.first { $0.id == o.ownerID }.map(budget.applies) ?? false }), !over.isEmpty {
                            Badge(text: "\(over.count) over", tint: Theme.amber)
                        }
                        Spacer()
                        Button("Remove") { model.updateSettings { $0.memoryBudgets.removeAll { $0.id == budget.id } } }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
                if s.memoryBudgets.isEmpty { Text("No budgets.").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
                HStack(spacing: 8) {
                    Picker("For", selection: $budgetKind) {
                        Text("An owner by name").tag("")
                        Text("Every agent session").tag("kind:agentSession")
                        Text("Every application").tag("kind:application")
                        Text("Every project").tag("kind:project")
                    }
                    .labelsHidden().frame(width: 170)
                    if budgetKind.isEmpty {
                        TextField("owner name as shown in Memory, for example Dia", text: $budgetName).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(maxWidth: 260)
                    }
                    Stepper(value: $budgetGB, in: 1...256) { Text("\(budgetGB) GB").font(.system(size: 12)).monospacedDigit() }
                    Button("Add budget") {
                        let match = budgetKind.isEmpty ? budgetName.trimmingCharacters(in: .whitespaces) : budgetKind
                        let bytes = Int64(budgetGB) * Bytes.gb
                        model.updateSettings { s in
                            s.memoryBudgets.removeAll { $0.id == match.lowercased() }
                            s.memoryBudgets.append(MemoryBudget(match: match, bytes: bytes))
                        }
                        budgetName = ""
                    }
                    .buttonStyle(QuietButtonStyle()).disabled(budgetKind.isEmpty && budgetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            group("Containers", "Containers are stopped, never removed; volumes are never touched.") {
                toggle("Stop a project's containers when no agent session has worked in it", s.stopContainersOfIdleProjects) { v in model.updateSettings { $0.stopContainersOfIdleProjects = v } }
                stepper("A project is idle after", s.projectIdleGraceMinutes, 5...720, step: 5, suffix: " min without an agent session") { v in model.updateSettings { $0.projectIdleGraceMinutes = v } }
                toggle("Restart the Docker VM once a day to return its memory", s.refreshContainerVMNightly) { v in model.updateSettings { $0.refreshContainerVMNightly = v } }
                stepper("Start looking for a quiet moment at", s.vmRefreshHour, 0...23, suffix: ":00") { v in model.updateSettings { $0.vmRefreshHour = v } }
                stepper("Only when at least", Int(s.vmRefreshMinimumExcessBytes / Bytes.gb), 1...64, suffix: " GB would come back") { v in model.updateSettings { $0.vmRefreshMinimumExcessBytes = Int64(v) * Bytes.gb } }
                Text("All containers go down for about a minute and are started again. Skipped while an agent session is working or a kept container is running. If the Mac slept through the hour, it catches up at the next quiet moment.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                if let report = model.live?.containers, report.product.lowercased().contains("docker desktop") {
                    Divider().overlay(Theme.stroke)
                    Text("The VM may use up to \(Bytes.format(report.vmLimitBytes)). Containers use \(Bytes.format(report.usedByContainersBytes)) now"
                        + (report.peakUsedBytes > 0 ? ", \(Bytes.format(report.peakUsedBytes)) at most in the days PEPEL has watched" : "") + ". "
                        + "The lowest limit PEPEL accepts is \(Bytes.format(report.minimumLimitBytes))"
                        + (report.suggestedLimitBytes.map { "; it suggests \(Bytes.format($0))." } ?? "."))
                        .font(.system(size: 12)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Stepper(value: $vmLimitGiB, in: 2...256) { Text("New limit: \(vmLimitGiB) GiB").font(.system(size: 12)).monospacedDigit() }
                        Button("Change limit…") { model.requestVMLimit(gib: vmLimitGiB) }.buttonStyle(QuietButtonStyle()).disabled(model.isRefreshingVM)
                        if model.isRefreshingVM { ProgressView().controlSize(.small) }
                    }
                    .onAppear { vmLimitGiB = Int((report.suggestedLimitBytes ?? report.vmLimitBytes) >> 30) }
                    Text("Only a restart gives the VM's memory back, and only a lower limit keeps it from growing again. Changing it stops Docker Desktop, writes the setting and starts Docker and the same containers.")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Leave running, whatever happens (container or compose project names; a container labelled pepel.keep=true is always kept):")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                ForEach(s.keepContainers, id: \.self) { name in
                    HStack {
                        Badge(text: "keep", tint: Theme.copper)
                        Text(name).font(Theme.mono).foregroundStyle(Theme.text)
                        Spacer()
                        Button("Remove") { model.updateSettings { $0.keepContainers.removeAll { $0 == name } } }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
                HStack(spacing: 8) {
                    TextField("container or compose project name", text: $newKeep).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(maxWidth: 320)
                    Button("Keep running") {
                        let name = newKeep.trimmingCharacters(in: .whitespaces)
                        model.updateSettings { if !$0.keepContainers.contains(name) { $0.keepContainers.append(name) } }
                        newKeep = ""
                    }
                    .buttonStyle(QuietButtonStyle()).disabled(newKeep.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog(
                model.pendingVMLimit.map { "Change the VM memory limit to \(Bytes.format($0.newLimitBytes))?" } ?? "",
                isPresented: Binding(get: { model.pendingVMLimit != nil }, set: { if !$0 { model.pendingVMLimit = nil } }), titleVisibility: .visible
            ) {
                if model.pendingVMLimit?.verdict != .denied { Button("Change and restart Docker Desktop") { model.confirmVMLimit() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(((model.pendingVMLimit?.reasons ?? []) + (model.pendingVMLimit?.warnings ?? [])).joined(separator: "\n"))
            }

            group("Processes", "Automatic termination is off unless you enable it, and even then covers only verified, idle, orphaned build and test processes while memory pressure is elevated, and language servers whose editor has exited.") {
                toggle("Terminate verified abandoned build/test processes and orphaned language servers automatically", s.autoTerminateAbandoned) { v in model.updateSettings { $0.autoTerminateAbandoned = v } }
                stepper("Call a process idle after", s.idleMinutesBeforeAbandoned, 5...720, step: 5, suffix: " min without CPU activity") { v in model.updateSettings { $0.idleMinutesBeforeAbandoned = v } }
                stepper("Wait", s.gracefulTerminationSeconds, 2...120, suffix: " s for a graceful exit") { v in model.updateSettings { $0.gracefulTerminationSeconds = v } }
            }

            group("Protection rules", "Paths, projects and services PEPEL must leave alone. Credentials, agent state, git metadata, source code and model weights are protected without any rule.") {
                ForEach(model.protections) { rule in
                    HStack(spacing: 8) {
                        Badge(text: rule.kind.rawValue, tint: Theme.forest)
                        Text(rule.kind == .path || rule.kind == .pin || rule.kind == .project ? PathUtil.display(rule.value) : rule.value).font(Theme.mono).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                        if !rule.note.isEmpty { Text(rule.note).font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1) }
                        Spacer()
                        Button("Remove") { model.unprotect(rule) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
                if model.protections.isEmpty { Text("No custom rules.").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
                HStack(spacing: 8) {
                    Picker("Kind", selection: $newRuleKind) {
                        Text("Path").tag(ProtectionKind.path)
                        Text("Project").tag(ProtectionKind.project)
                        Text("Process name").tag(ProtectionKind.processName)
                        Text("Command contains").tag(ProtectionKind.command)
                        Text("Listening port").tag(ProtectionKind.port)
                    }
                    .labelsHidden().frame(width: 150)
                    TextField(newRuleKind == .port ? "8000" : newRuleKind == .processName ? "postgres" : newRuleKind == .command ? "uvicorn api:app" : "~/projects/keep-this", text: $newRule)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    Button("Add") {
                        model.protect(newRuleKind, newRule.trimmingCharacters(in: .whitespaces))
                        newRule = ""
                    }
                    .buttonStyle(QuietButtonStyle()).disabled(newRule.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            group("Permissions", "PEPEL runs with your normal user rights. It does not request Full Disk Access or Accessibility. Administrator rights are asked for once, only if you use the file cache flush.") {
                Text("Without Full Disk Access some folders cannot be read; they are reported as unreadable and counted as a lower bound. Processes of other users are not inspected. Notifications and the login item ask for approval the first time they are used.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func modeHelp(_ mode: MonitoringMode) -> String {
        switch mode {
        case .manual: "PEPEL samples memory and processes but scans storage only when you ask."
        case .notifyOnly: "PEPEL scans in the background and tells you what it finds. Nothing is removed without you."
        case .automaticSafe: "As above, and items classified safe are removed automatically when no build, agent session or lease involves them."
        }
    }

    private func group<Content: View>(_ title: String, _ subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            content()
        }
        .panel()
    }

    private func line(_ label: String, _ path: String, remove: @escaping @MainActor @Sendable () -> Void) -> some View {
        HStack {
            Badge(text: label)
            PathText(path: PathUtil.expand(path))
            Spacer()
            Button("Remove", action: remove).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
    }

    private func toggle(_ title: String, _ value: Bool, set: @escaping @MainActor @Sendable (Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { value }, set: set)).font(.system(size: 12)).toggleStyle(.checkbox)
    }

    private func stepper(_ prefix: String, _ value: Int, _ range: ClosedRange<Int>, step: Int = 1, suffix: String, set: @escaping @MainActor @Sendable (Int) -> Void) -> some View {
        Stepper(value: Binding(get: { value }, set: { set(min(range.upperBound, max(range.lowerBound, $0))) }), in: range, step: step) {
            Text("\(prefix) \(value)\(suffix)").font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.text)
        }
        .accessibilityValue("\(value)")
    }

    private func picker<T: Hashable & Sendable>(_ title: String, selection: T, options: [(T, String)], set: @escaping @MainActor @Sendable (T) -> Void) -> some View {
        Picker(title, selection: Binding(get: { selection }, set: set)) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
        .font(.system(size: 12)).frame(maxWidth: 420)
    }

    private func chooseFolder(_ done: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { done(url.path) }
    }
}
