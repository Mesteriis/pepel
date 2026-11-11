import PEPELEngine
import SwiftUI

struct OverviewSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(
                title: "Overview",
                subtitle: model.healthSentence.trimmingCharacters(in: CharacterSet(charactersIn: ".")) + "." + (model.cadence.isEmpty ? "" : " Monitoring cadence: \(model.cadence)."))

            if let notice = model.menuBarNotice {
                Label(notice, systemImage: "menubar.rectangle").font(.system(size: 12)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true).panel()
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.amber.opacity(0.6), lineWidth: 1))
            }

            tiles

            if !model.alerts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Caption("Needs attention")
                    ForEach(model.alerts) { alert in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: alert.severity == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.color(for: alert.severity)).font(.system(size: 12))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(alert.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                                Text(alert.message).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .panel()
            }

            // What PEPEL is about to do and what it can undo: the two questions before trusting it.
            HStack(alignment: .top, spacing: 10) {
                PlanPanel()
                RestorePanel()
            }

            HStack(alignment: .top, spacing: 10) {
                largest
                buildsSummary
            }
        }
    }

    private var tiles: some View {
        let t = model.live?.telemetry
        let storage = model.storage
        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                MetricTile(
                    label: "Disk available", value: t.map { Bytes.format($0.diskAvailableBytes) } ?? "—",
                    detail: t.map { "\(Bytes.format($0.diskUsedBytes)) used of \(Bytes.format($0.diskTotalBytes))" },
                    fraction: t.map { $0.diskTotalBytes > 0 ? Double($0.diskUsedBytes) / Double($0.diskTotalBytes) : 0 })
                MetricTile(
                    label: "Reclaimable now", value: model.reclaimableText,
                    detail: storage.map { state in
                        let found = state.safeBytes + state.reviewBytes
                        let busy = max(0, found - state.reclaimableBytes)
                        return "\(state.reclaimableIsApproximate ? "Upper bound. " : "")\(Bytes.format(found)) found" + (busy > 0 ? ", \(Bytes.format(busy)) of it in use" : "")
                    } ?? "Run a scan to measure",
                    tint: Theme.copper)
                MetricTile(
                    label: "Memory pressure", value: t.map { $0.pressure.rawValue.capitalized } ?? "—",
                    detail: t.map { "\(Bytes.format($0.memoryUsedBytes)) used · \(Bytes.format($0.compressedBytes)) compressed" },
                    tint: t.map { Theme.color(for: $0.pressure) } ?? Theme.text)
                MetricTile(
                    label: "Swap", value: t.map { Bytes.format($0.swapUsedBytes) } ?? "—",
                    detail: t.map { "of \(Bytes.format($0.swapTotalBytes)) allocated by macOS" })
            }
            GridRow {
                MetricTile(
                    label: "Active builds", value: model.live.map { "\($0.activeBuildCount)" } ?? "—",
                    detail: storage.map { "\(Bytes.format($0.buildTotalBytes)) of build output on disk" })
                MetricTile(
                    label: "Abandoned processes", value: model.live.map { "\($0.abandoned.count)" } ?? "—",
                    detail: model.live.map { $0.abandoned.isEmpty ? "None among \($0.assessments.count) developer processes" : "holding up to \(Bytes.format($0.memory.proposalFootprintBytes))" },
                    tint: (model.live?.abandoned.isEmpty ?? true) ? Theme.text : Theme.amber)
                MetricTile(
                    label: "Agent sessions", value: model.live.map { "\($0.agentSessions.count)" } ?? "—",
                    detail: model.live.map { live in
                        let total = live.agentSessions.reduce(Int64(0)) { $0 + $1.footprintBytes }
                        return live.agentSessions.isEmpty ? "No agents running" : "\(Bytes.format(total)) across their process trees"
                    })
                growthTile
            }
        }
    }

    private var growthTile: some View {
        let day = model.growth?.day
        let delta = day?.deltaBytes ?? 0
        let span = day.map { $0.coversWindow ? "than a day ago" : "than \(TimeFormat.age($0.actualSpan)) ago" } ?? ""
        return MetricTile(
            label: "Disk used · 24 h", value: day.map { Bytes.formatDelta($0.deltaBytes) } ?? "—",
            detail: day.map { _ in delta < 0 ? "\(Bytes.format(-delta)) less in use \(span)" : delta > 0 ? "\(Bytes.format(delta)) more in use \(span)" : "Unchanged" }
                ?? "History starts with the first scan",
            tint: delta > 20 * Bytes.gb ? Theme.amber : delta < 0 ? Theme.forest : Theme.text)
    }

    private var largest: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Caption("Largest reclaimable artifacts")
                Spacer()
                Button("All storage") { model.open(.storage) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.copper)
            }
            if let storage = model.storage {
                let top = storage.items.filter { $0.safety != .protected && $0.reclaimableBytes > 0 }.prefix(7)
                if top.isEmpty {
                    Text("Nothing reclaimable was found.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                ForEach(Array(top)) { item in
                    HStack(spacing: 8) {
                        Text(Bytes.format(item.reclaimableBytes)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                            .foregroundStyle(Theme.text).frame(width: 64, alignment: .trailing)
                        Badge(text: item.safety.rawValue, tint: Theme.color(for: item.safety))
                        Text(item.title).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(item.category.displayName).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                }
            } else {
                EmptyState(symbol: "internaldrive", title: "No scan yet", message: "PEPEL has not measured developer storage on this Mac. A scan only reads; nothing is removed.")
            }
        }
        .panel()
    }

    private var buildsSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Caption("Build generations")
                Spacer()
                Button("All builds") { model.open(.builds) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.copper)
            }
            if let builds = model.storage?.builds, !builds.isEmpty {
                ForEach(builds.prefix(4)) { summary in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary.narrative).font(.system(size: 12)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                        if let fraction = summary.budgetFraction {
                            Meter(fraction: fraction, tint: summary.overBudget ? Theme.ember : summary.nearBudget ? Theme.amber : Theme.forest)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else {
                Text(model.storage == nil ? "Build generations appear after the first scan." : "No build artifacts were found in the configured project roots.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        .panel()
    }
}
