import PEPELEngine
import SwiftUI

struct MemorySection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmTabs = false
    @State private var search = ""
    @State private var showAgentOwned = false
    @State private var expandedOwners = false
    @State private var stopping: ContainerGroup?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let live = model.live {
                SectionTitle(title: "Memory", subtitle: live.memory.headline + ". " + live.memory.detail)
                composition(live.telemetry, developer: live.memory.developerFootprintBytes)
                owners(live)
                growth(live)
                unused(live)
                tabs(live)
                system(live)
                dormant(live)
                simulators(live)
                containers(live)
                if let report = model.terminationReport { terminationResult(report) }
                leftovers(live)
                candidates(live)
                HStack(alignment: .top, spacing: 10) {
                    consumers(live)
                    processes(live)
                }
            } else {
                SectionTitle(title: "Memory")
                EmptyState(symbol: "memorychip", title: "Sampling…", message: "Waiting for the first memory and process sample.")
            }
        }
        .confirmationDialog(
            model.pendingApplication.map { "\($0.action == .restart ? "Restart" : "Quit") \($0.name)?" } ?? "",
            isPresented: Binding(get: { model.pendingApplication != nil }, set: { if !$0 { model.pendingApplication = nil } }), titleVisibility: .visible
        ) {
            if model.pendingApplication?.verdict != .denied { Button(model.pendingApplication?.action == .quit ? "Quit" : "Restart") { model.confirmApplication() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(((model.pendingApplication?.reasons ?? []) + (model.pendingApplication?.warnings ?? [])).joined(separator: "\n"))
        }
    }

    /// Browser tab processes, with the idle ones offered for unloading.
    @ViewBuilder private func tabs(_ live: LiveState) -> some View {
        let idle = live.browserTabs.filter { $0.idleFor != nil }
        if !live.browserTabs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Caption("Browser tabs")
                    Spacer()
                    if !idle.isEmpty {
                        Text("\(Bytes.format(idle.reduce(0) { $0 + $1.footprintBytes })) in idle tabs").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Theme.amber)
                        Button("Unload \(idle.count) idle…") { confirmTabs = true }.buttonStyle(QuietButtonStyle())
                    }
                }
                ForEach(live.browserTabs.prefix(10)) { tab in
                    HStack(spacing: 10) {
                        Text(tab.browser).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text("tab process \(tab.root.pid) · " + (tab.idleFor.map { "idle \(TimeFormat.age($0))" } ?? "busy or newly seen")).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary)
                        Spacer()
                        Text(Bytes.format(tab.footprintBytes)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                    }
                }
                Text("Unloading ends the idle tab processes. The tabs stay in the tab strip and load again when you open them; unsent form input and scroll positions are lost. The tab in front and tabs playing something are busy and never included.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .panel()
            .confirmationDialog("Unload \(idle.count) idle browser tab process\(idle.count == 1 ? "" : "es")?", isPresented: $confirmTabs, titleVisibility: .visible) {
                Button("Unload") { model.unloadIdleTabs() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The tabs stay and load again when opened. Unsent form input and scroll positions are lost.")
            }
        }
    }

    /// Large macOS components; the ones the system restarts by itself get a button.
    @ViewBuilder private func system(_ live: LiveState) -> some View {
        if !live.systemProcesses.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Caption("Inside macOS services")
                ForEach(live.systemProcesses.prefix(8)) { item in
                    HStack(spacing: 10) {
                        Text(item.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .leading)
                        Text(item.note).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                        Spacer()
                        Text(Bytes.format(item.footprintBytes)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                        if let assessment = live.restartableSystem.first(where: { $0.process.identity == item.root }) {
                            Button("Restart…") { model.requestTermination(assessment) }.buttonStyle(QuietButtonStyle())
                        }
                    }
                    .help(item.note)
                }
                Text("macOS starts a restartable component again by itself within a second; a fresh copy starts small. The rest is shown so the group is not a black box.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .panel()
        }
    }

    /// Booted simulators and language servers nobody can talk to any more.
    @ViewBuilder private func simulators(_ live: LiveState) -> some View {
        if !live.simulators.isEmpty || !live.orphanedTools.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Caption("Simulators and orphaned tools")
                ForEach(live.simulators) { simulator in
                    HStack(spacing: 10) {
                        Text(simulator.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text("booted \(TimeFormat.ago(simulator.bootedAt)) · \(simulator.processCount) processes" + (simulator.inUse.map { " · " + $0 } ?? ""))
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                        Spacer()
                        Text(Bytes.format(simulator.footprintBytes)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                        Button("Shut down") { model.shutdownSimulator(simulator) }.buttonStyle(QuietButtonStyle())
                    }
                }
                ForEach(live.orphanedTools) { tool in
                    HStack(spacing: 10) {
                        Text(tool.process.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text("PID \(tool.process.pid) · its editor or agent has exited").font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                        Spacer()
                        Text(Bytes.format(tool.subtreeFootprintBytes)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                        Button("Review & terminate…") { model.requestTermination(tool) }.buttonStyle(QuietButtonStyle())
                    }
                    .help(tool.evidence.joined(separator: "\n"))
                }
            }
            .panel()
        }
    }

    /// Processes that live almost entirely in swap.
    @ViewBuilder private func dormant(_ live: LiveState) -> some View {
        if !live.dormant.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Caption("Living in swap")
                ForEach(live.dormant) { item in
                    HStack(spacing: 10) {
                        Text(item.process.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text("PID \(item.process.pid) · started \(TimeFormat.ago(item.process.identity.startDate)) · \(Bytes.format(item.process.residentBytes)) in RAM")
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary).lineLimit(1)
                        Spacer()
                        Text(Bytes.format(item.subtreeFootprintBytes)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                        if !item.eligibility.isNever {
                            Button("Review & terminate…") { model.requestTermination(item) }.buttonStyle(QuietButtonStyle())
                        }
                    }
                    .help(item.evidence.joined(separator: "\n"))
                }
                Text("A lot of memory charged, almost none of it in RAM, no CPU use. They cost little RAM but keep swap and compressed memory full. PEPEL does not know what they are for, so it only ends one when you say so.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .panel()
        }
    }

    /// Applications that are open but have not been used for hours.
    @ViewBuilder private func unused(_ live: LiveState) -> some View {
        if !live.unusedApplications.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Caption("Open but unused")
                ForEach(live.unusedApplications) { app in
                    HStack(spacing: 10) {
                        Text(app.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text("last in front \(TimeFormat.ago(app.lastActive))").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        Spacer()
                        Text(Bytes.format(app.footprintBytes)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                        Button("Keep") { model.updateSettings { $0.keepApplications.append(app.name) } }.buttonStyle(QuietButtonStyle())
                            .help("Never list \(app.name) here again.")
                        Button("Quit…") { model.requestApplication(.quit, bundlePath: app.bundlePath) }.buttonStyle(QuietButtonStyle())
                    }
                }
                Text("Not brought to the front for \(model.settings.unusedApplicationHours) hours and using almost no CPU. PEPEL only lists them; quitting is the ordinary request, so an application with unsaved changes will ask.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .panel()
        }
    }

    /// Owners whose memory kept rising while PEPEL watched, with a restart for applications.
    @ViewBuilder private func growth(_ live: LiveState) -> some View {
        if !live.growth.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Caption("Kept growing")
                ForEach(live.growth) { item in
                    HStack(spacing: 10) {
                        Text(item.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text("\(Bytes.format(item.baselineBytes)) → \(Bytes.format(item.currentBytes)) over \(TimeFormat.age(Date().timeIntervalSince(item.since)))")
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary)
                        Spacer()
                        Text("+\(Bytes.format(item.perHourBytes))/h").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.amber)
                        if item.kind == .application {
                            Button("Restart…") { model.requestApplication(.restart, bundlePath: String(item.id.dropFirst(4))) }.buttonStyle(QuietButtonStyle())
                        }
                    }
                }
                Text("Steady growth over at least two hours usually means a leak or an application that has been open for a long time. Restarting it returns what it accumulated.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .panel()
        }
    }

    private func composition(_ t: SystemTelemetry, developer: Int64) -> some View {
        let parts: [(String, Int64, Color)] = [
            ("App memory", t.appMemoryBytes, Theme.forest), ("Wired", t.wiredBytes, Theme.secondary), ("Compressed", t.compressedBytes, Theme.amber),
            ("Cached files", t.cachedFileBytes, Theme.forestDim), ("Free", t.freeBytes, Theme.raised),
        ]
        let total = CGFloat(max(1, t.memoryTotalBytes))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                stat("Pressure", t.pressure.rawValue.capitalized, Theme.color(for: t.pressure))
                stat("Used", Bytes.format(t.memoryUsedBytes), Theme.text)
                stat("Physical", Bytes.format(t.memoryTotalBytes), Theme.text)
                stat("Swap used", Bytes.format(t.swapUsedBytes), t.swapUsedBytes > t.memoryTotalBytes / 4 ? Theme.amber : Theme.text)
                stat("Developer processes", Bytes.format(developer), Theme.text)
                Spacer()
            }
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.0) { part in
                        Rectangle().fill(part.2).frame(width: max(1, proxy.size.width * CGFloat(part.1) / total)).help("\(part.0): \(Bytes.format(part.1))")
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            HStack(spacing: 12) {
                ForEach(parts, id: \.0) { part in
                    HStack(spacing: 4) {
                        Circle().fill(part.2).frame(width: 6, height: 6)
                        Text("\(part.0) \(Bytes.format(part.1))").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    }
                }
            }
            Text("Cached files are released on demand, so low free memory is normal. PEPEL never “cleans RAM”; it only helps stop processes nobody is using.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
        .panel()
    }

    /// Who holds the memory, with the part that macOS has already squeezed out of RAM.
    private func owners(_ live: LiveState) -> some View {
        let shown = Array(live.memoryOwners.prefix(expandedOwners ? 40 : 8))
        let scale = CGFloat(max(1, live.memoryOwners.first?.footprintBytes ?? 1))
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Caption("Where the memory went")
                Spacer()
                HStack(spacing: 10) {
                    HStack(spacing: 4) { Circle().fill(Theme.forest).frame(width: 6, height: 6); Text("in RAM") }
                    HStack(spacing: 4) { Circle().fill(Theme.amber).frame(width: 6, height: 6); Text("compressed or swapped (estimate)") }
                }
                .font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            Text(live.memoryExplanation).font(.system(size: 12)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            ForEach(shown) { owner in
                HStack(spacing: 10) {
                    Text(Bytes.format(owner.footprintBytes)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 66, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(owner.name).font(.system(size: 12)).lineLimit(1)
                            if let over = live.overBudget.first(where: { $0.ownerID == owner.id }) {
                                Badge(text: "over \(Bytes.format(over.budgetBytes)) budget", tint: Theme.amber)
                            }
                            if owner.kind == .application {
                                Menu {
                                    Button("Restart…") { model.requestApplication(.restart, bundlePath: String(owner.id.dropFirst(4))) }
                                    Button("Quit…") { model.requestApplication(.quit, bundlePath: String(owner.id.dropFirst(4))) }
                                } label: {
                                    Image(systemName: "ellipsis").font(.system(size: 10))
                                }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                .help("Ask \(owner.name) to quit, or to quit and open again.")
                                .accessibilityLabel("Actions for \(owner.name)")
                            }
                            Badge(text: ownerLabel(owner.kind), tint: owner.kind == .agentSession ? Theme.forest : Theme.secondary)
                            if owner.confidence != .verified { ConfidenceBadge(confidence: owner.confidence) }
                            Text("\(owner.processCount) process\(owner.processCount == 1 ? "" : "es")").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                            Spacer(minLength: 0)
                            if owner.notInRAMBytes > 50 * Bytes.mb {
                                Text("≈ \(Bytes.format(owner.notInRAMBytes)) not in RAM").font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.amber)
                            }
                        }
                        GeometryReader { proxy in
                            let total = proxy.size.width * CGFloat(owner.footprintBytes) / scale
                            let squeezed = owner.footprintBytes > 0 ? total * CGFloat(owner.notInRAMBytes) / CGFloat(owner.footprintBytes) : 0
                            HStack(spacing: 0) {
                                Rectangle().fill(Theme.forest).frame(width: max(1, total - squeezed))
                                Rectangle().fill(Theme.amber).frame(width: max(0, squeezed))
                            }
                            .clipShape(Capsule())
                        }
                        .frame(height: 4)
                    }
                }
                .foregroundStyle(Theme.text)
                .help(owner.detail + "\n" + owner.largest.map { "\($0.name) (PID \($0.identity.pid)): \(Bytes.format($0.footprintBytes))" }.joined(separator: "\n"))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(owner.name): \(Bytes.format(owner.footprintBytes)), \(owner.processCount) processes")
            }
            if live.memoryOwners.count > 8 {
                Button(expandedOwners ? "Show fewer" : "Show all \(live.memoryOwners.count) owners") { expandedOwners.toggle() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.copper)
            }
        }
        .panel()
    }

    /// Memory inside the container VM against what the host is charged for it.
    @ViewBuilder private func containers(_ live: LiveState) -> some View {
        if let report = live.containers {
            let scale = CGFloat(max(report.vmLimitBytes, report.hostFootprintBytes, 1))
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Caption("\(report.product): containers")
                    Spacer()
                    Text("read \(TimeFormat.ago(report.measuredAt))").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    if model.isRefreshingVM {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Restart VM to return memory…") { model.requestVMRefresh() }.buttonStyle(CopperButtonStyle(prominent: false))
                            .help("Restarts Docker Desktop and starts the same containers again. Asks first.")
                    }
                }
                Text(report.explanation).font(.system(size: 12)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                if let done = model.vmRefreshReport {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(done.restarted ? "VM restarted: charged \(Bytes.format(done.hostFootprintBefore)) before, \(Bytes.format(done.hostFootprintAfter)) after." : "The VM was not restarted.")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(done.restarted && done.missing.isEmpty ? Theme.forest : Theme.amber)
                        ForEach(done.steps, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(Theme.secondary) }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    bar("Used by containers", report.usedByContainersBytes, scale, Theme.forest)
                    bar("Virtual machine limit", report.vmLimitBytes, scale, Theme.secondary)
                    bar("Charged to this Mac", report.hostFootprintBytes, scale, Theme.amber)
                    if let suggested = report.suggestedLimitBytes { bar("A limit with 1.5× headroom", suggested, scale, Theme.copper) }
                }
                ForEach(report.groups.prefix(8)) { group in
                    HStack(spacing: 10) {
                        Text(Bytes.format(group.memoryBytes)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 66, alignment: .trailing)
                        Text(group.name).font(.system(size: 12)).lineLimit(1)
                        Text("\(group.containers.count) container\(group.containers.count == 1 ? "" : "s")").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                        if let project = model.projectName(group.projectID) { Badge(text: project, tint: Theme.forest) }
                        if group.projectID == nil {
                            Text("not tied to a project").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                        } else if group.agentSessions > 0 {
                            Badge(text: "\(group.agentSessions) agent session\(group.agentSessions == 1 ? "" : "s")", tint: Theme.forest)
                        } else if let idle = group.idleSince {
                            Badge(text: "no agent for \(TimeFormat.age(Date().timeIntervalSince(idle)))", tint: Theme.amber)
                        }
                        if !group.containers.filter(\.isKept).isEmpty {
                            Badge(text: group.stoppable.isEmpty ? "kept running" : "\(group.containers.count - group.stoppable.count) kept", tint: Theme.copper)
                        }
                        Spacer(minLength: 0)
                        Text(String(format: "%.1f%% CPU", group.cpuPercent)).font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.secondary)
                        if !group.stoppable.isEmpty {
                            Button("Stop") { stopping = group }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.copper)
                        }
                    }
                    .foregroundStyle(Theme.text)
                    .help(group.containers.map { "\($0.name): \(Bytes.format($0.memoryBytes))\($0.isKept ? " — kept" : "")" }.joined(separator: "\n"))
                }
                Text("The limit is set in \(report.product) › Settings › Resources; PEPEL does not change it. Containers are stopped, never removed. \(report.total - report.running) stopped containers use no memory.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .panel()
            .confirmationDialog(
                "Stop \(stopping?.stoppable.count ?? 0) containers of \(stopping?.name ?? "")?", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
                titleVisibility: .visible
            ) {
                Button("Stop containers") { if let group = stopping { model.stopContainers(group) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("They are stopped, not removed: containers and volumes stay, and `docker compose start` brings them back. Containers marked to be kept are left running.")
            }
            .confirmationDialog(
                "Restart the Docker VM?", isPresented: Binding(get: { model.pendingVMRefresh != nil }, set: { if !$0 { model.pendingVMRefresh = nil } }), titleVisibility: .visible
            ) {
                if model.pendingVMRefresh?.verdict != .denied { Button("Restart and bring containers back") { model.confirmVMRefresh() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(((model.pendingVMRefresh?.reasons ?? []) + (model.pendingVMRefresh?.warnings ?? [])).joined(separator: "\n"))
            }
        }
    }

    private func bar(_ label: String, _ bytes: Int64, _ scale: CGFloat, _ tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.secondary).frame(width: 170, alignment: .leading)
            GeometryReader { proxy in
                Capsule().fill(tint).frame(width: max(2, proxy.size.width * CGFloat(bytes) / scale))
            }
            .frame(height: 5)
            Text(Bytes.format(bytes)).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Theme.text).frame(width: 66, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(Bytes.format(bytes))")
    }

    /// What applications that have quit left running.
    @ViewBuilder private func leftovers(_ live: LiveState) -> some View {
        if !live.leftovers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Caption("Left running by applications that quit")
                    Spacer()
                    Text(model.settings.terminateAppLeftovers ? "terminated automatically after \(model.settings.appLeftoverGraceMinutes) min" : "reported only")
                        .font(.system(size: 10)).foregroundStyle(model.settings.terminateAppLeftovers ? Theme.amber : Theme.tertiary)
                }
                ForEach(live.leftovers) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(group.appName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            Text("quit \(TimeFormat.ago(group.quitAt))").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            Spacer()
                            Text(Bytes.format(group.footprintBytes)).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(Theme.text)
                        }
                        ForEach(group.processes) { leftover in
                            HStack(spacing: 8) {
                                Text(Bytes.format(leftover.subtreeFootprintBytes)).font(.system(size: 11, weight: .medium)).monospacedDigit().frame(width: 62, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(leftover.process.shortCommand).font(Theme.mono).foregroundStyle(Theme.text).lineLimit(1)
                                    Text("PID \(leftover.process.pid)\(leftover.descendantCount > 0 ? " · \(leftover.descendantCount) child processes" : "") · \(leftover.evidence.dropFirst().first ?? "")")
                                        .font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if leftover.eligibility.isNever {
                                    Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.tertiary)
                                        .help({ if case .never(let reason) = leftover.eligibility { return reason } else { return "" } }())
                                } else {
                                    Button("Review & terminate…") { model.requestTermination(leftover) }.buttonStyle(CopperButtonStyle(prominent: false))
                                }
                            }
                            .foregroundStyle(Theme.text)
                            .help(leftover.evidence.joined(separator: "\n"))
                        }
                    }
                }
                Text("macOS frees a quit application's own memory by itself. Only what keeps running holds any, and only stopping it gives that memory back.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .panel()
        }
    }

    private func ownerLabel(_ kind: MemoryOwnerKind) -> String {
        switch kind {
        case .virtualMachine: "VM"
        case .agentSession: "agent"
        case .application: "app"
        case .project: "project"
        case .developerTool: "dev tool"
        case .system: "system"
        case .other: "other"
        }
    }

    private func stat(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Caption(label)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    private func terminationResult(_ report: TerminationReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(report.exited ? "\(report.name) (PID \(report.target.pid)) exited" : "\(report.name) (PID \(report.target.pid)) is still running", systemImage: report.exited ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(report.exited ? Theme.forest : Theme.amber)
                Spacer()
                Button("Dismiss") { model.terminationReport = nil }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            ForEach(report.steps, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(Theme.secondary) }
            Text("Measured: memory used \(Bytes.format(report.before.memoryUsedBytes)) → \(Bytes.format(report.after.memoryUsedBytes)) (\(Bytes.formatDelta(report.observedMemoryChange))), pressure \(report.before.pressure.rawValue) → \(report.after.pressure.rawValue). The process tree held \(Bytes.format(report.footprintBefore)); other activity also moves these numbers.")
                .font(.system(size: 11)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
        }
        .panel()
    }

    private func candidates(_ live: LiveState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("Abandoned-process candidates")
            if live.abandoned.isEmpty {
                let unknown = live.assessments.filter { $0.lifecycle == .unknown && $0.agentAncestor == nil }.count
                Text("None. PEPEL only proposes a process when its parent is gone and it has shown no CPU activity for \(model.settings.idleMinutesBeforeAbandoned) minutes of observation." + (unknown > 0 ? " \(unknown) process\(unknown == 1 ? " has" : "es have") not been observed long enough to judge." : ""))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(live.abandoned) { candidate in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(candidate.process.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                        Text("PID \(candidate.process.pid)").font(Theme.mono).foregroundStyle(Theme.tertiary)
                        Badge(text: candidate.lifecycle == .abandonedSubprocess ? "abandoned subprocess" : "suspicious orphan", tint: Theme.amber)
                        ConfidenceBadge(confidence: candidate.confidence)
                        Spacer()
                        Text(Bytes.format(candidate.subtreeFootprintBytes)).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(Theme.text)
                        Button("Review & terminate…") { model.requestTermination(candidate) }.buttonStyle(CopperButtonStyle(prominent: false))
                            .disabled(candidate.eligibility.isNever)
                    }
                    Text(candidate.process.displayCommand).font(Theme.mono).foregroundStyle(Theme.secondary).lineLimit(2)
                    ForEach(candidate.evidence, id: \.self) { line in
                        Label(line, systemImage: "circle.fill").labelStyle(BulletLabelStyle()).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .panel()
    }

    private func consumers(_ live: LiveState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption("Largest memory consumers")
            ForEach(live.memory.topConsumers) { consumer in
                HStack(spacing: 8) {
                    Text(Bytes.format(consumer.footprintBytes)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 66, alignment: .trailing)
                    Text(consumer.name).font(.system(size: 12)).lineLimit(1)
                    if consumer.isDeveloperWorkload { Badge(text: "dev", tint: Theme.forest) }
                    Spacer(minLength: 0)
                    if let growth = consumer.growthBytes, abs(growth) > 50 * Bytes.mb {
                        Text(Bytes.formatDelta(growth)).font(.system(size: 10)).monospacedDigit().foregroundStyle(growth > 0 ? Theme.amber : Theme.forest)
                            .help("Change in footprint while PEPEL has been watching")
                    }
                }
                .foregroundStyle(Theme.text)
            }
            Text("Shown for context. Size alone is never a reason to stop a process.").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
        }
        .panel()
        .frame(width: 330)
    }

    private func processes(_ live: LiveState) -> some View {
        let visible = live.assessments
            .filter { showAgentOwned || $0.agentAncestor == nil || $0.role == .buildTool || $0.role == .testRunner }
            .filter { search.isEmpty || $0.process.displayCommand.lowercased().contains(search.lowercased()) || (model.projectName($0.projectID)?.lowercased().contains(search.lowercased()) ?? false) }
            .sorted { $0.process.footprintBytes > $1.process.footprintBytes }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Caption("Developer processes (\(visible.count) of \(live.assessments.count))")
                Spacer()
                Toggle("Agent helpers", isOn: $showAgentOwned).toggleStyle(.checkbox).font(.system(size: 11))
                TextField("Filter", text: $search).textFieldStyle(.roundedBorder).font(.system(size: 11)).frame(width: 130)
            }
            ForEach(visible.prefix(60)) { a in
                HStack(spacing: 8) {
                    Text(Bytes.format(a.process.footprintBytes)).font(.system(size: 11, weight: .medium)).monospacedDigit().frame(width: 58, alignment: .trailing)
                    Badge(text: lifecycleLabel(a.lifecycle), tint: lifecycleTint(a.lifecycle)).frame(width: 96, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(a.process.shortCommand).font(Theme.mono).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                        Text("PID \(a.process.pid) · \(a.role.rawValue) · \(model.projectName(a.projectID) ?? "no project")\(a.cpuPercent.map { String(format: " · %.1f%% CPU", $0) } ?? "")\(a.process.listeningPorts.isEmpty ? "" : " · :" + a.process.listeningPorts.map(String.init).joined(separator: ","))")
                            .font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if !a.eligibility.isNever {
                        Button {
                            model.requestTermination(a)
                        } label: {
                            Image(systemName: "xmark.circle").font(.system(size: 12))
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.tertiary).help("Review termination…").accessibilityLabel("Review termination of \(a.process.name)")
                    } else {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.tertiary)
                            .help({ if case .never(let reason) = a.eligibility { return reason } else { return "" } }())
                    }
                }
                .foregroundStyle(Theme.text)
                .help(a.evidence.joined(separator: "\n"))
            }
            if visible.isEmpty { Text("No developer processes match.").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
        }
        .panel()
    }

    private func lifecycleLabel(_ l: LifecycleClass) -> String {
        switch l {
        case .agentSession: "agent"
        case .activeBuildOrTest: "active build"
        case .activeDevService: "dev service"
        case .backgroundService: "background"
        case .abandonedSubprocess: "abandoned"
        case .suspiciousOrphan: "orphan"
        case .unknown: "unknown"
        }
    }

    private func lifecycleTint(_ l: LifecycleClass) -> Color {
        switch l {
        case .agentSession, .activeBuildOrTest, .activeDevService: Theme.forest
        case .backgroundService: Theme.secondary
        case .abandonedSubprocess, .suspiciousOrphan: Theme.amber
        case .unknown: Theme.tertiary
        }
    }
}
