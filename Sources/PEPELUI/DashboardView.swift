import PEPELEngine
import SwiftUI

public struct DashboardView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Theme.stroke)
            ScrollView {
                content
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Theme.background)
        }
        .frame(minWidth: 980, minHeight: 620)
        .background(Theme.background)
        .alert("PEPEL", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
        .sheet(item: Binding(get: { model.pendingTermination.map(TerminationSheetItem.init) }, set: { if $0 == nil { model.pendingTermination = nil } })) { item in
            TerminationSheet(decision: item.decision)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(nsImage: AppImages.glyph("Glyph", fallbackSymbol: "flame.fill", pointSize: 28))
                Text("PEPEL").font(.system(size: 14, weight: .bold)).kerning(1.4).foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 10).padding(.top, 34).padding(.bottom, 14)

            ForEach(DashboardSection.allCases) { section in
                SidebarRow(section: section, selected: model.section == section, badge: badge(for: section)) { model.open(section) }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                if model.isScanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(model.scanProgress.map { $0.total > 0 ? "\($0.completed)/\($0.total)" : $0.phase } ?? "Scanning")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary).monospacedDigit().lineLimit(1)
                    }
                }
                Button {
                    model.isScanning ? model.cancelScan() : model.scanNow()
                } label: {
                    Label(model.isScanning ? "Cancel scan" : "Scan now", systemImage: model.isScanning ? "xmark" : "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut("r")
                Text(model.storage.map { "Last scan \(TimeFormat.ago($0.scan.finishedAt))" } ?? "Not scanned yet")
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                SelfUsageLine()
            }
            .padding(10)
        }
        .frame(width: 176)
        .background(Theme.sidebar)
    }

    private func badge(for section: DashboardSection) -> String? {
        switch section {
        case .memory:
            return model.live.flatMap { live in
                let count = live.abandoned.count + live.leftovers.reduce(0) { $0 + $1.processes.count }
                return count == 0 ? nil : "\(count)"
            }
        case .builds: return model.live.flatMap { $0.activeBuildCount == 0 ? nil : "\($0.activeBuildCount)" }
        case .agents: return model.live.flatMap { $0.agentSessions.isEmpty ? nil : "\($0.agentSessions.count)" }
        case .cleanup: return model.storage.flatMap { $0.reclaimableBytes > 0 ? Bytes.format($0.reclaimableBytes) : nil }
        default: return nil
        }
    }

    @ViewBuilder private var content: some View {
        switch model.section {
        case .overview: OverviewSection()
        case .storage: StorageSection()
        case .map: DiskMapSection()
        case .memory: MemorySection()
        case .builds: BuildsSection()
        case .projects: ProjectsSection()
        case .agents: AgentsSection()
        case .cleanup: CleanupSection()
        case .history: HistorySection()
        case .settings: SettingsSection()
        }
    }
}

private struct SidebarRow: View {
    let section: DashboardSection
    let selected: Bool
    let badge: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: section.symbol).font(.system(size: 12)).frame(width: 16)
                    .foregroundStyle(selected ? (section == .cleanup ? Theme.copper : Theme.forest) : Theme.secondary)
                Text(section.title).font(.system(size: 12, weight: selected ? .semibold : .regular)).foregroundStyle(selected ? Theme.text : Theme.secondary)
                Spacer(minLength: 0)
                if let badge {
                    Text(badge).font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .foregroundStyle(section == .cleanup ? Theme.copper : Theme.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(selected ? Theme.raised : hovering ? Theme.raised.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
        .modifier(SectionShortcut(index: DashboardSection.allCases.firstIndex(of: section) ?? 0))
        .accessibilityLabel(section.title + (badge.map { ", \($0)" } ?? ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct TerminationSheetItem: Identifiable {
    let decision: TerminationDecision
    var id: ProcessIdentity { decision.target.process.identity }
}

/// Explains exactly what will be signalled and why before anything happens.
struct TerminationSheet: View {
    @Environment(AppModel.self) private var model
    let decision: TerminationDecision
    @State private var force = false

    var body: some View {
        let target = decision.target
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Terminate \(target.process.name)?").font(.system(size: 15, weight: .semibold))
                Spacer()
                Badge(text: target.lifecycle.rawValue, tint: Theme.amber)
                ConfidenceBadge(confidence: target.confidence)
            }
            Text(target.process.displayCommand).font(Theme.mono).foregroundStyle(Theme.secondary).lineLimit(3).textSelection(.enabled)
            Text("PID \(target.process.pid) · started \(TimeFormat.ago(target.process.identity.startDate)) · process tree holds \(Bytes.format(target.subtreeFootprintBytes))")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Caption("What PEPEL established")
                ForEach(target.evidence, id: \.self) { line in
                    Label(line, systemImage: "circle.fill").labelStyle(BulletLabelStyle()).font(.system(size: 12)).foregroundStyle(Theme.text)
                }
            }
            .panel()

            if !(decision.reasons + decision.warnings).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(decision.reasons + decision.warnings, id: \.self) { line in
                        Label(line, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12))
                            .foregroundStyle(decision.verdict == .denied ? Theme.danger : Theme.amber)
                    }
                }
            }

            if decision.verdict == .denied {
                Text("PEPEL will not terminate this process.").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
            } else {
                Toggle("If it ignores SIGTERM for \(model.settings.gracefulTerminationSeconds) seconds, force-quit it (SIGKILL)", isOn: $force)
                    .font(.system(size: 12)).toggleStyle(.checkbox)
                Text("PEPEL sends SIGTERM, waits for the process to exit, and records memory pressure before and after. The memory a process holds is not guaranteed to become available.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { model.pendingTermination = nil }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                if decision.verdict != .denied {
                    Button("Terminate") { model.confirmTermination(force: force) }.buttonStyle(CopperButtonStyle())
                }
            }
        }
        .padding(18)
        .frame(width: 560)
        .background(Theme.background)
    }
}

struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            configuration.icon.font(.system(size: 4)).foregroundStyle(Theme.tertiary).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2 }
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// ⌘1…⌘9 for the first nine sections; a tenth one has no single digit left.
private struct SectionShortcut: ViewModifier {
    let index: Int

    func body(content: Content) -> some View {
        if index < 9 {
            content.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        } else {
            content
        }
    }
}
