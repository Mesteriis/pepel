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
        .accessibilityLabel("PEPEL. \(model.healthSentence) \(model.menuBarText.map { "Reclaimable: \($0)" } ?? "")")
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
                    detail: t.map { "of \(Bytes.format($0.diskTotalBytes))" },
                    fraction: t.map { $0.diskTotalBytes > 0 ? Double($0.diskUsedBytes) / Double($0.diskTotalBytes) : 0 })
                MetricTile(
                    label: "Reclaimable now", value: model.reclaimableText,
                    detail: model.storage.map { "\($0.reclaimableIsApproximate ? "upper bound · " : "")scanned \(TimeFormat.ago($0.scan.finishedAt))" } ?? "Not scanned yet",
                    tint: Theme.copper)
            }
            GridRow {
                MetricTile(
                    label: "Memory pressure", value: t.map { $0.pressure.rawValue.capitalized } ?? "—",
                    detail: t.map { "\(Bytes.format($0.compressedBytes)) compressed" }, tint: t.map { Theme.color(for: $0.pressure) } ?? Theme.text)
                MetricTile(label: "Swap", value: t.map { Bytes.format($0.swapUsedBytes) } ?? "—", detail: t.map { "of \(Bytes.format($0.swapTotalBytes)) allocated" })
            }
            GridRow {
                MetricTile(
                    label: "Active builds", value: model.live.map { "\($0.activeBuildCount)" } ?? "—",
                    detail: model.live.map { "\($0.agentSessions.count) agent session\($0.agentSessions.count == 1 ? "" : "s")" })
                MetricTile(
                    label: "Abandoned", value: model.live.map { "\($0.abandoned.count)" } ?? "—",
                    detail: model.live.map { $0.abandoned.isEmpty ? "No candidates" : "up to \(Bytes.format($0.memory.proposalFootprintBytes))" },
                    tint: (model.live?.abandoned.isEmpty ?? true) ? Theme.text : Theme.amber)
            }
            GridRow {
                MetricTile(
                    label: "Storage growth · 24 h", value: day.map { Bytes.formatDelta($0.deltaBytes) } ?? "—",
                    detail: day.map { $0.coversWindow ? "disk usage change" : "over the last \(TimeFormat.age($0.actualSpan)) (history is shorter)" } ?? "No history yet"
                )
                .gridCellColumns(2)
            }
        }
    }

    private var scanRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(model.scanProgress.map { $0.total > 0 ? "\($0.phase) \($0.completed)/\($0.total)" : $0.phase } ?? "Scanning")
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
                    Text("Last restart: \(Bytes.format(done.hostFootprintBefore)) → \(Bytes.format(done.hostFootprintAfter))\(done.missing.isEmpty ? "" : "; \(done.missing.count) containers did not come back")")
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

    private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
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
