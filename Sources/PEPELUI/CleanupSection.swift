import PEPELEngine
import SwiftUI

struct CleanupSection: View {
    @Environment(AppModel.self) private var model
    @State private var selected = Set<String>()
    @State private var confirming = false
    @State private var showBlocked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(
                title: "Cleanup",
                subtitle: "Every item is checked against running processes, agent sessions, leases and your rules, and checked again at the moment of removal. Nothing happens until you confirm.")
            if let report = model.cleanupReport { reportView(report) }
            if let plan = model.plan {
                let allowed = plan.decisions.filter { $0.verdict == .allowed }
                let review = plan.decisions.filter { $0.verdict == .needsConfirmation }
                let blocked = plan.decisions.filter { $0.verdict == .denied }
                actionBar(plan)
                group("Safe", "Verified disposable, not in use.", allowed, tint: Theme.forest, selectable: true)
                group("Review", "Reproducible or recoverable; removing it costs a rebuild, a download or a restart.", review, tint: Theme.copper, selectable: true)
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { showBlocked.toggle() }
                } label: {
                    Label(showBlocked ? "Hide \(blocked.count) blocked items PEPEL will not touch" : "Show \(blocked.count) blocked items PEPEL will not touch", systemImage: showBlocked ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                if showBlocked { group("Blocked", "In use, leased, protected, or too recently written.", blocked, tint: Theme.tertiary, selectable: false) }
            } else if model.isPlanning {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Evaluating policy…").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
            } else {
                EmptyState(
                    symbol: "flame", title: model.storage == nil ? "Scan first" : "Ready to evaluate",
                    message: model.storage == nil ? "Cleanup works from a storage scan. Run one from the sidebar." : "PEPEL will evaluate each artifact against current activity.")
                if model.storage != nil { Button("Evaluate cleanup") { model.prepareCleanup() }.buttonStyle(CopperButtonStyle()) }
            }
        }
        .onAppear {
            if model.plan == nil, model.storage != nil { model.prepareCleanup() }
            selectSafe()
        }
        .onChange(of: model.plan?.id) { _, _ in selectSafe() }
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button("Clean \(selected.count) items", role: .destructive) { model.runCleanup(selected: selected, dryRun: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    /// Safe items start selected; review items are opt-in.
    private func selectSafe() {
        selected = Set(model.plan?.decisions.filter { $0.verdict == .allowed }.map(\.id) ?? [])
    }

    private var chosen: [CleanupDecision] { model.plan?.decisions.filter { selected.contains($0.id) } ?? [] }
    private var chosenBytes: Int64 { chosen.reduce(0) { $0 + $1.item.reclaimableBytes } }
    private var confirmTitle: String { L("Clean up to \(Bytes.format(chosenBytes))?") }

    private var confirmMessage: String {
        let permanent = chosen.filter { !$0.action.isUndoable }.count
        let trashed = chosen.count - permanent
        var parts: [String] = []
        if permanent > 0 { parts.append(L("\(permanent) items will be removed permanently or through a tool. That cannot be undone.")) }
        if trashed > 0 { parts.append(L("\(trashed) items will move to the Trash and can be restored; space is reclaimed when the Trash is emptied.")) }
        parts.append(L("The amount freed can be lower than shown where files are shared."))
        return parts.joined(separator: " ")
    }

    private func actionBar(_ plan: CleanupPlan) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(selected.count) selected · up to \(Bytes.format(chosenBytes))").font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text)
                Text("Evaluated \(TimeFormat.ago(plan.createdAt)). Deletion mode: \(modeText).").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            if model.isCleaning { ProgressView().controlSize(.small) }
            Button("Re-evaluate") { model.prepareCleanup() }.buttonStyle(QuietButtonStyle()).disabled(model.isPlanning || model.isCleaning)
            Button("Dry run") { model.runCleanup(selected: selected, dryRun: true) }.buttonStyle(QuietButtonStyle()).disabled(selected.isEmpty || model.isCleaning)
                .help("Runs every check the real cleanup runs, without removing anything")
            Button("Clean selected…") { confirming = true }.buttonStyle(CopperButtonStyle()).disabled(selected.isEmpty || model.isCleaning)
        }
        .panel()
    }

    private var modeText: String {
        switch model.settings.deletionMode {
        case .automatic: L("safe items are removed, review items go to the Trash")
        case .trash: L("everything goes to the Trash")
        case .permanent: L("everything is removed permanently")
        }
    }

    private func group(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, _ decisions: [CleanupDecision], tint: Color, selectable: Bool) -> some View {
        let sorted = decisions.sorted { $0.item.reclaimableBytes > $1.item.reclaimableBytes }
        let ids = Set(sorted.map(\.id))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                Text("\(sorted.count) · up to \(Bytes.format(sorted.reduce(0) { $0 + $1.item.reclaimableBytes }))").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                Spacer()
                if selectable, !sorted.isEmpty {
                    Button(ids.isSubset(of: selected) ? "Select none" : "Select all") {
                        if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
                    }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.copper)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if sorted.isEmpty {
                Text("Nothing here.").font(.system(size: 12)).foregroundStyle(Theme.tertiary).padding(.horizontal, 12).padding(.bottom, 10)
            }
            LazyVStack(spacing: 0) {
                ForEach(sorted.prefix(250)) { decision in
                    Divider().overlay(Theme.stroke.opacity(0.6))
                    row(decision, selectable: selectable)
                }
            }
        }
        .panel(padding: 0)
    }

    private func row(_ decision: CleanupDecision, selectable: Bool) -> some View {
        let item = decision.item
        return HStack(alignment: .top, spacing: 10) {
            if selectable {
                Toggle("", isOn: Binding(get: { selected.contains(decision.id) }, set: { if $0 { selected.insert(decision.id) } else { selected.remove(decision.id) } }))
                    .toggleStyle(.checkbox).labelsHidden().accessibilityLabel("Select \(item.title)")
            } else {
                Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Theme.tertiary).frame(width: 16).padding(.top, 2)
            }
            Text((item.size?.isApproximate ?? false ? "≤ " : "") + Bytes.format(item.reclaimableBytes)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(Theme.text).frame(width: 76, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
                    Badge(text: item.category.displayName)
                    if let project = model.projectName(item.projectID) { Badge(text: project, tint: Theme.forest) }
                }
                PathText(path: item.path)
                ForEach(decision.reasons.prefix(3), id: \.self) { reason in
                    Text(reason).font(.system(size: 11)).foregroundStyle(decision.verdict == .denied ? Theme.secondary : Theme.copper).fixedSize(horizontal: false, vertical: true)
                }
                if decision.verdict != .denied {
                    // The action column already says whether this is reversible. The engine's warnings may arrive translated.
                    ForEach(decision.warnings.filter { !Self.reversibilityWarnings.contains($0) && !$0.hasPrefix("This cannot be undone") && !$0.hasPrefix("Space is reclaimed") }, id: \.self) { warning in
                        Text(warning).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    }
                }
            }
            Spacer(minLength: 4)
            if decision.verdict != .denied {
                Text(decision.action.summary).font(.system(size: 10, weight: .medium)).foregroundStyle(decision.action.isUndoable ? Theme.secondary : Theme.ember)
                    .lineLimit(1).help(decision.action.isUndoable ? "Reversible until the Trash is emptied" : "Irreversible")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    /// The policy engine's warnings that repeat what the action column says.
    private static var reversibilityWarnings: Set<String> {
        [L("This cannot be undone."), L("Space is reclaimed only when the Trash is emptied.")]
    }

    private func reportView(_ report: CleanupReport) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(report.dryRun ? "Dry run — nothing was removed" : "\(report.succeededCount) of \(report.outcomes.count) items cleaned")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(report.dryRun ? Theme.text : Theme.forest)
                Spacer()
                Button("Dismiss") { model.cleanupReport = nil }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            Text(
                report.dryRun
                    ? "Up to \(Bytes.format(report.estimatedBytes)) would be affected."
                    : "Estimated up to \(Bytes.format(report.estimatedBytes)). Available disk space changed by \(Bytes.formatDelta(report.observedFreedBytes)) during cleanup (measured; other activity affects it, and the Trash still holds trashed items)."
            )
            .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(report.outcomes.prefix(40)) { outcome in
                HStack(spacing: 8) {
                    Image(systemName: symbol(outcome.status)).font(.system(size: 11)).foregroundStyle(tint(outcome.status)).frame(width: 14)
                    Text(outcome.title).font(.system(size: 11)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(text(outcome)).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
        }
        .panel()
    }

    private func symbol(_ status: CleanupStatus) -> String {
        switch status {
        case .removed, .trashed, .toolRan: "checkmark.circle.fill"
        case .wouldApply: "eye"
        case .skipped: "minus.circle"
        case .failed: "xmark.octagon.fill"
        }
    }

    private func tint(_ status: CleanupStatus) -> Color {
        switch status {
        case .removed, .trashed, .toolRan: Theme.forest
        case .wouldApply: Theme.secondary
        case .skipped: Theme.amber
        case .failed: Theme.danger
        }
    }

    private func text(_ outcome: CleanupOutcome) -> String {
        switch outcome.status {
        case .removed: L("removed")
        case .trashed: L("moved to Trash")
        case .toolRan: L("cleaned by its tool")
        case .wouldApply: L("would: \(outcome.action.summary.lowercased())")
        case .skipped(let reason): L("skipped — \(reason)")
        case .failed(let reason): L("failed — \(reason)")
        }
    }
}
