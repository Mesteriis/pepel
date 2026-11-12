import PEPELEngine
import SwiftUI

/// What macOS starts on its own: launch agents (yours and apps'), system daemons and login
/// helpers, with what each runs and holds now; agents can be switched off and on again.
struct StartupSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let startup = model.startup
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(
                    title: "Startup",
                    subtitle: "What macOS starts on its own, what it holds right now, and switching launch agents off. PEPEL only reads until you confirm a change; property lists are never deleted.")
                Spacer()
                if startup.isLoading { ProgressView().controlSize(.small) }
                Button("Read again") { startup.refresh() }.buttonStyle(QuietButtonStyle()).disabled(startup.isLoading)
            }
            if let message = startup.message {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.forest).fixedSize(horizontal: false, vertical: true).panel()
            }
            if let items = startup.items {
                tiles(items)
                ForEach(StartupItem.Kind.allCases, id: \.self) { kind in
                    let group = items.filter { $0.kind == kind }
                    if !group.isEmpty { panel(kind, group) }
                }
                loginItems
            } else {
                EmptyState(symbol: "power", title: "Reading startup items", message: "Launch agents, daemons and login helpers, with what they run now.")
            }
        }
        .onAppear { if startup.items == nil { startup.refresh() } }
        .confirmationDialog(
            dialogTitle(startup.pending), isPresented: Binding(get: { startup.pending != nil }, set: { if !$0 { startup.pending = nil } }), titleVisibility: .visible
        ) {
            Button(startup.pending?.disabled == true ? L("Switch on") : L("Switch off")) { startup.confirm() }
            Button("Cancel", role: .cancel) { startup.pending = nil }
        } message: {
            Text(dialogMessage(startup.pending))
        }
    }

    private func dialogTitle(_ item: StartupItem?) -> String {
        guard let item else { return "" }
        return item.disabled ? L("Switch \(item.owner) on?") : L("Switch \(item.owner) off?")
    }

    private func dialogMessage(_ item: StartupItem?) -> String {
        guard let item else { return "" }
        if item.disabled { return L("\(item.label) is enabled and loaded now; it then starts as its property list says (\(item.schedule)).") }
        let running = item.isRunning ? L("It stops now, freeing about \(Bytes.format(item.footprintBytes)).") + " " : ""
        return running + L("It will not start at login until you switch it on again. The property list \(PathUtil.display(item.plistPath ?? "")) stays where it is.")
    }

    private func tiles(_ items: [StartupItem]) -> some View {
        let running = items.filter(\.isRunning)
        let held = running.reduce(Int64(0)) { $0 + $1.footprintBytes }
        return Grid(horizontalSpacing: 10) {
            GridRow {
                MetricTile(label: "Start on their own", value: "\(items.filter { !$0.disabled }.count)", detail: L("\(items.filter(\.disabled).count) switched off"))
                MetricTile(label: "Running now", value: "\(running.count)", detail: L("\(running.reduce(0) { $0 + $1.processCount }) processes"))
                MetricTile(label: "Memory they hold", value: Bytes.format(held), detail: running.first.map { L("Most: \($0.owner), \(Bytes.format($0.footprintBytes))") }, tint: Theme.copper)
                MetricTile(label: "New this week", value: "\(model.startup.newCount)", detail: L("PEPEL notifies when something new appears"), tint: model.startup.newCount > 0 ? Theme.amber : Theme.text)
            }
        }
    }

    private func panel(_ kind: StartupItem.Kind, _ items: [StartupItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Caption(kind.title)
                Spacer()
                Text(folder(kind)).font(Theme.mono).foregroundStyle(Theme.tertiary)
            }
            .padding(.bottom, 6)
            ForEach(items) { item in
                Divider().overlay(Theme.stroke.opacity(0.6))
                StartupRow(item: item)
            }
        }
        .panel()
    }

    private func folder(_ kind: StartupItem.Kind) -> String {
        switch kind {
        case .userAgent: "~/Library/LaunchAgents"
        case .sharedAgent: "/Library/LaunchAgents"
        case .daemon: "/Library/LaunchDaemons"
        case .appHelper: L("inside apps")
        }
    }

    private var loginItems: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Apps that open at login").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                Text("The list of apps macOS opens when you log in is kept by System Settings. Reading it would need permission to control System Events, which PEPEL does not ask for; each app there also shows on the Memory screen while it runs.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open Login Items") { LoginItem.openSettings() }.buttonStyle(QuietButtonStyle())
        }
        .panel()
    }
}

private struct StartupRow: View {
    @Environment(AppModel.self) private var model
    let item: StartupItem

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle().fill(stateColor).frame(width: 7, height: 7).help(stateText)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: item.owner).font(.system(size: 12, weight: .semibold)).foregroundStyle(item.disabled ? Theme.tertiary : Theme.text).lineLimit(1)
                    Badge(text: item.schedule)
                    if isNew { Badge(text: "new", tint: Theme.amber) }
                    if let status = item.lastExitStatus, status != 0, !item.isRunning { Badge(text: L("exited with \(Int(status))"), tint: Theme.amber) }
                }
                Text(verbatim: item.label + (item.program.map { "  ·  " + PathUtil.display($0) } ?? ""))
                    .font(Theme.mono).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: item.isRunning && item.processCount > 0 ? Bytes.format(item.footprintBytes) : "—").font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(Theme.text)
                Text(verbatim: stateText).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            }
            .frame(width: 120, alignment: .trailing)
            if item.plistPath != nil || item.program != nil {
                Button { model.startup.reveal(item) } label: { Image(systemName: "folder") }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondary).help("Show in Finder")
            }
            Button(item.disabled ? L("Switch on") : L("Switch off")) { model.startup.pending = item }
                .buttonStyle(QuietButtonStyle())
                .disabled(item.managementRefusal != nil)
                .help(item.managementRefusal ?? "")
                .frame(width: 104)
        }
        .padding(.vertical, 6)
    }

    private var isNew: Bool { (item.firstSeen ?? .distantPast) > Date().addingTimeInterval(-7 * 86_400) }

    private var stateColor: Color {
        if item.disabled { return Theme.tertiary.opacity(0.5) }
        if item.isRunning { return Theme.forest }
        if let status = item.lastExitStatus, status != 0 { return Theme.amber }
        return Theme.tertiary
    }

    private var stateText: String {
        if item.disabled { return L("switched off") }
        if let pid = item.pid, item.kind == .daemon { return L("running as root, PID \(Int(pid))") }
        if let pid = item.pid { return item.processCount > 1 ? L("running, \(item.processCount) processes, PID \(Int(pid))") : L("running, PID \(Int(pid))") }
        if item.loaded { return L("loaded, waiting") }
        return item.kind == .daemon ? L("not running") : L("not loaded")
    }
}
