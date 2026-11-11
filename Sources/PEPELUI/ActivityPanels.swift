import PEPELEngine
import SwiftUI

/// What the daily rules will act on next, grouped by rule, each item with "Leave alone".
struct PlanPanel: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<RuleAction.Rule> = []
    /// Rows shown per rule before "more".
    private let preview = 3

    var body: some View {
        let activity = model.activity
        VStack(alignment: .leading, spacing: 10) {
            header(activity)
            if let plan = activity.plan {
                if plan.actions.isEmpty {
                    Text(plan.notes.first ?? (anyRuleOn ? L("No daily rule has anything to do right now.") : L("No daily rule is switched on. Settings › Rule set picks a ready-made set.")))
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(groups(plan), id: \.rule) { group in
                        ruleGroup(group.rule, group.actions)
                    }
                    ForEach(plan.notes, id: \.self) { note in
                        Text(note).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking at what each rule would touch…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                .padding(.vertical, 6)
            }
        }
        .panel()
        .onAppear { if activity.plan == nil { activity.refreshPlan() } }
    }

    private var anyRuleOn: Bool {
        let s = model.settings
        return s.dockerAutoClean || s.cleanStaleProjects || s.trimCaches || s.cleanAppCaches || s.cleanOldLogs || s.cleanTempFiles || s.cleanAndroidEmulators
            || s.cleanUnusedSystemImages || s.cleanToolBackups || s.tidyScreenshots || s.tidyDownloads
    }

    private func header(_ activity: ActivityModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Caption("Next 24 hours")
            if let plan = activity.plan, !plan.actions.isEmpty {
                Text("\(plan.actions.count) items · up to \(Bytes.format(plan.bytes))")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary)
            }
            Spacer()
            if activity.isPlanning, activity.plan != nil { ProgressView().controlSize(.mini) }
            Button("Look again") { activity.refreshPlan() }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.copper).disabled(activity.isPlanning)
        }
    }

    private func groups(_ plan: ActionPlan) -> [(rule: RuleAction.Rule, actions: [RuleAction])] {
        var order: [RuleAction.Rule] = []
        var byRule: [RuleAction.Rule: [RuleAction]] = [:]
        for action in plan.actions {
            if byRule[action.rule] == nil { order.append(action.rule) }
            byRule[action.rule, default: []].append(action)
        }
        return order.map { ($0, byRule[$0]!.sorted { $0.bytes > $1.bytes }) }
    }

    private func ruleGroup(_ rule: RuleAction.Rule, _ actions: [RuleAction]) -> some View {
        let open = expanded.contains(rule)
        let shown = open ? actions : Array(actions.prefix(preview))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(rule.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                Text(when(actions.first?.due) + " · " + (actions.first?.verb ?? L("remove")))
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                Spacer()
                Text(Bytes.format(actions.reduce(0) { $0 + $1.bytes })).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(Theme.copper)
            }
            .padding(.bottom, 4)
            ForEach(shown) { action in
                PlanRow(action: action) { model.activity.leaveAlone(action) }
            }
            if actions.count > preview {
                Button(open ? "Show fewer" : "\(actions.count - preview) more") {
                    withAnimation(.easeOut(duration: 0.2)) { if open { expanded.remove(rule) } else { expanded.insert(rule) } }
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary).padding(.top, 3)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Rectangle().fill(Theme.stroke.opacity(0.6)).frame(height: 1).offset(y: -5) }
    }

    private func when(_ date: Date?) -> String {
        guard let date else { return "" }
        let wait = date.timeIntervalSinceNow
        return wait < 120 ? L("at the next pass") : L("in \(TimeFormat.age(wait))")
    }
}

private struct PlanRow: View {
    let action: RuleAction
    let leaveAlone: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(Bytes.format(action.bytes)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary).frame(width: 62, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                if let path = action.path {
                    Text(PathUtil.display(path)).font(Theme.mono).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            Button("Leave alone", action: leaveAlone)
                .buttonStyle(QuietButtonStyle())
                .opacity(hovering ? 1 : 0.55)
                .help("The rule will pass this by from now on. Settings › Leave alone undoes it.")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// What PEPEL moved to the Trash and can still put back, and what it removed for good.
struct RestorePanel: View {
    @Environment(AppModel.self) private var model
    @State private var showAll = false
    @State private var showRemoved = false

    var body: some View {
        let activity = model.activity
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Caption("Can be put back · 14 days")
                if let center = activity.restore, !center.restorable.isEmpty {
                    Text("\(center.restorable.count) · \(Bytes.format(center.restorable.reduce(0) { $0 + $1.bytes }))")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button("History") { model.open(.history) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.copper)
            }
            if let center = activity.restore {
                if center.restorable.isEmpty {
                    Text("Nothing PEPEL moved to the Trash is waiting there.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                } else {
                    let rows = showAll ? center.restorable : Array(center.restorable.prefix(6))
                    ForEach(rows) { record in row(record) }
                    if center.restorable.count > 6 {
                        Button(showAll ? "Show fewer" : "\(center.restorable.count - 6) more") { withAnimation(.easeOut(duration: 0.2)) { showAll.toggle() } }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
                removedForGood(center)
            } else {
                ProgressView().controlSize(.small)
            }
            if let message = activity.message {
                Text(message).font(.system(size: 11)).foregroundStyle(Theme.forest).fixedSize(horizontal: false, vertical: true)
            }
        }
        .panel()
        .onAppear { activity.refreshRestore() }
    }

    private func row(_ record: TrashRecord) -> some View {
        HStack(spacing: 8) {
            Text(Bytes.format(record.bytes)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary).frame(width: 62, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.name).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                Text("\(record.source) · \(TimeFormat.ago(record.at)) · from \(PathUtil.display((record.originalPath as NSString).deletingLastPathComponent))")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Button("Put back") { model.activity.restore(record) }.buttonStyle(CopperButtonStyle(prominent: false))
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func removedForGood(_ center: RestoreCenter) -> some View {
        if !center.removed.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { showRemoved.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(showRemoved ? 90 : 0))
                        Text("Removed for good: \(center.removed.count) actions, \(Bytes.format(center.removed.reduce(0) { $0 + $1.bytes })). Rebuilt or downloaded again when needed.")
                    }
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                if showRemoved {
                    ForEach(center.removed.prefix(30)) { entry in
                        HStack(spacing: 8) {
                            Text(Bytes.format(entry.bytes)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.tertiary).frame(width: 62, alignment: .trailing)
                            Text(entry.subject).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(TimeFormat.ago(entry.timestamp)).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
    }
}

/// PEPEL's own cost, at the foot of the sidebar; amber with a sentence when it is in the way.
struct SelfUsageLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let activity = model.activity
        if let usage = activity.selfUsage, !usage.processes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: activity.selfWarning == nil ? "gauge.with.dots.needle.0percent" : "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    let footprint = Bytes.format(usage.footprintBytes)
                    Text(usage.cpuPercent.map { L("PEPEL itself · \(footprint) · \(Int($0.rounded()))% CPU") } ?? L("PEPEL itself · \(footprint)"))
                        .monospacedDigit()
                }
                .font(.system(size: 10)).foregroundStyle(activity.selfWarning == nil ? Theme.tertiary : Theme.amber)
                if let warning = activity.selfWarning {
                    Text(warning).font(.system(size: 10)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                    if model.isMeasuringDiskMap {
                        Button("Stop the disk map") { model.cancelDiskMap() }.buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.copper)
                    }
                }
            }
            .help(usage.heavyTasks.isEmpty ? L("No heavy job is running.") : L("Running: \(usage.heavyTasks.map(AppModel.heavyTaskTitle).joined(separator: ", "))"))
        }
    }
}
