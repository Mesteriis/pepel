import PEPELEngine
import SwiftUI

public struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    public init() {}

    private var statusColor: NSColor? {
        if model.settings.paused { return .systemGray }
        switch model.health {
        case .healthy: return NSColor(Theme.forest)
        case .attention: return NSColor(Theme.amber)
        case .critical: return NSColor(Theme.danger)
        }
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: AppImages.menuBar(status: statusColor))
            if let text = model.menuBarText {
                Text(text).monospacedDigit()
            }
        }
        .accessibilityLabel("PEPEL. \(model.healthSentence) \(model.menuBarText.map { L("Reclaimable: \($0)") } ?? "")")
    }
}

/// The compact dashboard behind the menu bar icon.
public struct PopoverView: View {
    @Environment(AppModel.self) private var model
    var openDashboard: (DashboardSection) -> Void

    public init(openDashboard: @escaping (DashboardSection) -> Void) {
        self.openDashboard = openDashboard
    }

    private var healthColor: Color {
        if model.settings.paused { return Theme.tertiary }
        switch model.health {
        case .healthy: return Theme.forest
        case .attention: return Theme.amber
        case .critical: return Theme.danger
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            metrics
            if model.isScanning { scanRow }
            primaryAction
            freeMemory
            dockerMemory
            quickActions
            footer
        }
        .padding(12)
        .frame(width: 348)
        .background(Theme.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppImages.glyph("Glyph", fallbackSymbol: "flame.fill", pointSize: 26))
            VStack(alignment: .leading, spacing: 1) {
                Text("PEPEL").font(.system(size: 13, weight: .bold)).kerning(1.2).foregroundStyle(Theme.text)
                HStack(spacing: 5) {
                    Circle().fill(healthColor).frame(width: 7, height: 7)
                    Text(model.healthSentence).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button {
                model.togglePause()
            } label: {
                Image(systemName: model.settings.paused ? "play.fill" : "pause.fill").font(.system(size: 11))
            }
            .buttonStyle(QuietButtonStyle())
            .help(model.settings.paused ? "Resume monitoring" : "Pause monitoring")
            .accessibilityLabel(model.settings.paused ? "Resume monitoring" : "Pause monitoring")
        }
    }

    private var metrics: some View {
        let t = model.live?.telemetry
        let day = model.growth?.day
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                MetricTile(
                    label: "Disk free", value: t.map { Bytes.format($0.diskAvailableBytes) } ?? "—",
                    detail: t.map { L("of \(Bytes.format($0.diskTotalBytes))") },
                    fraction: t.map { $0.diskTotalBytes > 0 ? Double($0.diskUsedBytes) / Double($0.diskTotalBytes) : 0 })
                MetricTile(
                    label: "Reclaimable now", value: model.reclaimableText,
                    detail: model.storage.map {
                        $0.reclaimableIsApproximate ? L("upper bound · scanned \(TimeFormat.ago($0.scan.finishedAt))") : L("scanned \(TimeFormat.ago($0.scan.finishedAt))")
                    } ?? L("Not scanned yet"),
                    tint: Theme.copper)
            }
            GridRow {
                MetricTile(
                    label: "Memory pressure", value: t.map { pressureTitle($0.pressure) } ?? "—",
                    detail: t.map { L("\(Bytes.format($0.compressedBytes)) compressed") }, tint: t.map { Theme.color(for: $0.pressure) } ?? Theme.text)
                MetricTile(label: "Swap", value: t.map { Bytes.format($0.swapUsedBytes) } ?? "—", detail: t.map { L("of \(Bytes.format($0.swapTotalBytes)) allocated") })
            }
            GridRow {
                MetricTile(
                    label: "Active builds", value: model.live.map { "\($0.activeBuildCount)" } ?? "—",
                    detail: model.live.map { L("\($0.agentSessions.count) agent sessions") })
                MetricTile(
                    label: "Abandoned", value: model.live.map { "\($0.abandoned.count)" } ?? "—",
                    detail: model.live.map { $0.abandoned.isEmpty ? L("No candidates") : L("up to \(Bytes.format($0.memory.proposalFootprintBytes))") },
                    tint: (model.live?.abandoned.isEmpty ?? true) ? Theme.text : Theme.amber)
            }
            GridRow {
                MetricTile(
                    label: "Storage growth · 24 h", value: day.map { Bytes.formatDelta($0.deltaBytes) } ?? "—",
                    detail: day.map { $0.coversWindow ? L("disk usage change") : L("over the last \(TimeFormat.age($0.actualSpan)) (history is shorter)") } ?? L("No history yet")
                )
                .gridCellColumns(2)
            }
        }
    }

    private var scanRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(model.scanProgress.map { $0.total > 0 ? "\($0.phase) \($0.completed)/\($0.total)" : $0.phase } ?? L("Scanning"))
                .font(.system(size: 11)).foregroundStyle(Theme.secondary).monospacedDigit()
            Spacer()
            Button("Cancel") { model.cancelScan() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
    }

    private var primaryAction: some View {
        Button {
            openDashboard(.cleanup)
        } label: {
            HStack {
                Image(systemName: "flame.fill")
                Text(model.storage == nil ? "Review cleanup" : "Review cleanup · \(model.reclaimableText)")
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(CopperButtonStyle())
        .keyboardShortcut(.defaultAction)
        .accessibilityHint("Opens the cleanup review. Nothing is removed until you confirm.")
    }

    /// One action for everything PEPEL can do to give memory back: shows what it would stop,
    /// then does it and reports the measured change.
    @ViewBuilder private var freeMemory: some View {
        if model.isReclaiming {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Freeing memory…").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
        } else if let plan = model.reclaimPlan {
            @Bindable var model = model
            VStack(alignment: .leading, spacing: 7) {
                Text(plan.steps.isEmpty ? "Nothing to free right now" : "Free memory").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                if plan.steps.isEmpty {
                    Text("No abandoned processes, sleeping agent sessions, unused containers or Docker VM slack. What is in memory is in use.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(plan.steps) { step in
                    Toggle(
                        isOn: Binding(
                            get: { model.reclaimSelection.contains(step.id) },
                            set: { if $0 { model.reclaimSelection.insert(step.id) } else { model.reclaimSelection.remove(step.id) } })
                    ) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(step.title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text)
                                Spacer(minLength: 0)
                                if step.estimatedBytes > 0 {
                                    Text("up to \(Bytes.format(step.estimatedBytes))").font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.copper)
                                }
                            }
                            let names = step.targets.prefix(3).joined(separator: ", ")
                            Text(step.targets.count > 3 ? L("\(names) and \(step.targets.count - 3) more") : names)
                                .font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(2)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .help(step.detail)
                }
                HStack {
                    Spacer()
                    Button(plan.steps.isEmpty ? "Close" : "Cancel") { model.cancelReclaim() }.buttonStyle(QuietButtonStyle())
                    if !plan.steps.isEmpty {
                        Button(plan.estimatedBytes(model.reclaimSelection) > 0 ? "Free up to \(Bytes.format(plan.estimatedBytes(model.reclaimSelection)))" : "Free memory") { model.confirmReclaim() }
                            .buttonStyle(CopperButtonStyle()).disabled(model.reclaimSelection.isEmpty)
                    }
                }
            }
            .panel(padding: 10)
        } else {
            Button {
                model.prepareReclaim()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "memorychip").frame(width: 14)
                    Text("Free memory")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(QuietButtonStyle())
            .help("Shows what PEPEL would stop to give memory back. Nothing happens until you confirm.")
            .accessibilityHint("Lists what would be stopped. Nothing happens until you confirm.")
            if let report = model.reclaimReport {
                let done = report.results.reduce(0) { $0 + $1.done }
                Text("Last time: memory used \(Bytes.format(report.before.memoryUsedBytes)) → \(Bytes.format(report.after.memoryUsedBytes)), free \(Bytes.format(report.before.freeBytes)) → \(Bytes.format(report.after.freeBytes)), swap \(Bytes.format(report.before.swapUsedBytes)) → \(Bytes.format(report.after.swapUsedBytes)); \(done) done.")
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Return the memory the Docker VM holds beyond what its containers use.
    @ViewBuilder private var dockerMemory: some View {
        if let containers = model.live?.containers {
            if model.isRefreshingVM {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Restarting the Docker VM; containers will be started again…").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            } else if let pending = model.pendingVMRefresh {
                VStack(alignment: .leading, spacing: 6) {
                    Text(pending.verdict == .denied ? "PEPEL will not restart the VM" : "Restart the Docker VM?").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                    ForEach((pending.reasons + pending.warnings).prefix(4), id: \.self) { line in
                        Text(line).font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Cancel") { model.pendingVMRefresh = nil }.buttonStyle(QuietButtonStyle())
                        Spacer()
                        if pending.verdict != .denied {
                            Button("Restart and bring containers back") { model.confirmVMRefresh() }.buttonStyle(CopperButtonStyle())
                        }
                    }
                }
                .panel(padding: 10)
            } else {
                Button {
                    model.requestVMRefresh()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "shippingbox").frame(width: 14)
                        Text("Return Docker memory")
                        Spacer(minLength: 0)
                        Text(containers.excessBytes > Bytes.gb ? "≈ \(Bytes.format(containers.excessBytes))" : "little to return")
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(containers.excessBytes > 4 * Bytes.gb ? Theme.copper : Theme.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(QuietButtonStyle())
                .help("Restarts the Docker VM and starts the same containers again. Asks first.")
                .accessibilityHint("Restarts the Docker virtual machine after confirmation.")
                if let done = model.vmRefreshReport, done.restarted {
                    let before = Bytes.format(done.hostFootprintBefore), after = Bytes.format(done.hostFootprintAfter)
                    Text(
                        done.missing.isEmpty
                            ? L("Last restart: \(before) → \(after)")
                            : L("Last restart: \(before) → \(after); \(done.missing.count) containers did not come back"))
                        .font(.system(size: 10)).foregroundStyle(done.missing.isEmpty ? Theme.tertiary : Theme.amber)
                }
            }
        }
    }

    private var quickActions: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                action("Scan now", "arrow.clockwise") { model.scanNow() }.disabled(model.isScanning)
                action("Processes", "memorychip") { openDashboard(.memory) }
            }
            GridRow {
                action("Build versions", "hammer") { openDashboard(.builds) }
                action("Full dashboard", "macwindow") { openDashboard(.overview) }
            }
        }
    }

    private func action(_ title: LocalizedStringKey, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 6) {
                Image(systemName: symbol).frame(width: 14)
                Text(title)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(QuietButtonStyle())
    }

    /// The pressure level as a figure ("Normal").
    private func pressureTitle(_ level: MemoryPressureLevel) -> String {
        switch level {
        case .normal: L("Normal")
        case .elevated: L("Elevated")
        case .critical: L("Critical")
        }
    }

    private var footer: some View {
        HStack {
            Text(model.cadence.isEmpty ? " " : "Monitoring: \(model.cadence)").font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                .keyboardShortcut("q")
        }
    }
}

/// What the menu bar item shows, for the AppKit status item that hosts it.
@MainActor
public enum MenuBarContent {
    public static func image(_ model: AppModel) -> NSImage {
        let status: NSColor
        if model.settings.paused {
            status = .systemGray
        } else {
            switch model.health {
            case .healthy: status = NSColor(Theme.forest)
            case .attention: status = NSColor(Theme.amber)
            case .critical: status = NSColor(Theme.danger)
            }
        }
        return AppImages.menuBar(status: status)
    }

    public static func title(_ model: AppModel) -> String { model.menuBarText ?? "" }

    public static func accessibilityLabel(_ model: AppModel) -> String {
        "PEPEL. \(model.healthSentence)" + (model.menuBarText.map { " \($0)" } ?? "")
    }
}
