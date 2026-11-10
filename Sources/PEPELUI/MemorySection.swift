import PEPELEngine
import SwiftUI

struct MemorySection: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var showAgentOwned = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let live = model.live {
                SectionTitle(title: "Memory", subtitle: live.memory.headline + ". " + live.memory.detail)
                composition(live.telemetry, developer: live.memory.developerFootprintBytes)
                if let report = model.terminationReport { terminationResult(report) }
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
