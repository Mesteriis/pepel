import PEPELEngine
import SwiftUI

/// Installed applications: how much each is used, what it occupies with its data, and removing
/// the ones nobody opens. PEPEL suggests; a person decides; everything goes to the Trash.
struct InstalledAppsSection: View {
    @Environment(AppModel.self) private var model
    @State private var showAll = false
    @State private var showApple = false

    var body: some View {
        let installed = model.installed
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(
                    title: "Apps",
                    subtitle: L("How much each installed app is used and what it occupies with its data. PEPEL suggests removing what nobody has opened for \(model.settings.appUnusedDays) days; it removes nothing on its own, and what you remove goes to the Trash."))
                Spacer()
                if installed.isLoading { ProgressView().controlSize(.small) }
                Button("Measure again") { installed.refresh() }.buttonStyle(QuietButtonStyle()).disabled(installed.isLoading)
            }
            if let message = installed.message {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.forest).fixedSize(horizontal: false, vertical: true).panel()
            }
            if let apps = installed.apps {
                tiles(apps)
                suggestions(installed.suggested)
                everything(apps)
            } else {
                EmptyState(symbol: "square.grid.2x2", title: "Measuring applications", message: "Every app in Applications with its data in your Library. Takes a few seconds; nothing is removed.")
            }
        }
        .onAppear { if installed.apps == nil { installed.refresh() } }
        .sheet(item: Binding(get: { installed.pending }, set: { installed.pending = $0 })) { app in
            UninstallSheet(app: app)
        }
    }

    private func tiles(_ apps: [InstalledApp]) -> some View {
        let suggested = apps.filter(\.isSuggested)
        let top = apps.max { $0.foregroundSeconds < $1.foregroundSeconds }
        return Grid(horizontalSpacing: 10) {
            GridRow {
                MetricTile(label: "Installed", value: "\(apps.count)", detail: L("\(Bytes.format(apps.reduce(0) { $0 + $1.totalBytes })) with their data"))
                MetricTile(
                    label: "Not opened lately", value: "\(suggested.count)", detail: L("\(Bytes.format(suggested.reduce(0) { $0 + $1.totalBytes })) could go to the Trash"),
                    tint: suggested.isEmpty ? Theme.text : Theme.copper)
                MetricTile(
                    label: "Used most · 30 days", value: top.flatMap { $0.foregroundSeconds >= 60 ? $0.name : nil } ?? "—",
                    detail: top.flatMap { $0.foregroundSeconds >= 60 ? L("\(Self.hours($0.foregroundSeconds)) in front, on \($0.daysUsed) days") : nil } ?? L("PEPEL records time in front while it runs"))
                MetricTile(label: "Largest data", value: apps.max { $0.dataBytes < $1.dataBytes }.map { $0.name } ?? "—", detail: apps.max { $0.dataBytes < $1.dataBytes }.map { L("\(Bytes.format($0.dataBytes)) in your Library") })
            }
        }
    }

    static func hours(_ seconds: Double) -> String {
        seconds < 3600 ? L("\(Int(seconds / 60)) min") : L("\(String(format: "%.1f", seconds / 3600)) h")
    }

    private func suggestions(_ apps: [InstalledApp]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Caption(L("Not opened for \(model.settings.appUnusedDays) days"))
                Spacer()
                Text(Bytes.format(apps.reduce(0) { $0 + $1.totalBytes })).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(Theme.copper)
            }
            .padding(.bottom, 6)
            if apps.isEmpty {
                Text("Every app was opened recently, is open now, starts on its own, or is on the keep list.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            ForEach(apps) { app in
                Divider().overlay(Theme.stroke.opacity(0.6))
                AppRow(app: app, suggested: true)
            }
            Text("Last used comes from macOS's own record of opening an app and from what PEPEL has seen open. Data of sandboxed apps (~/Library/Containers) is protected by macOS and is not touched.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
        }
        .panel()
    }

    private func everything(_ apps: [InstalledApp]) -> some View {
        let shown = apps.filter { !$0.isSuggested && (showApple || !$0.isApple) }.sorted { $0.totalBytes > $1.totalBytes }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { showAll.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(showAll ? 90 : 0))
                        Caption(L("In use: \(shown.count) apps"))
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if showAll { Toggle("Show apps that come with macOS", isOn: $showApple).toggleStyle(.checkbox).font(.system(size: 11)) }
            }
            if showAll {
                ForEach(shown) { app in
                    Divider().overlay(Theme.stroke.opacity(0.6))
                    AppRow(app: app, suggested: false)
                }
            }
        }
        .panel()
    }
}

private struct AppRow: View {
    @Environment(AppModel.self) private var model
    let app: InstalledApp
    let suggested: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: model.installed.icon(app)).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: app.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    if let version = app.version { Text(verbatim: version).font(.system(size: 10)).foregroundStyle(Theme.tertiary) }
                    if app.isRunning { Badge(text: "open", tint: Theme.forest) }
                    if !app.startupLabels.isEmpty { Badge(text: "starts on its own", tint: Theme.amber) }
                }
                Text(verbatim: usage).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                if !suggested, let reason = app.keptBecause {
                    Text(verbatim: reason).font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: Bytes.format(app.totalBytes)).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(Theme.text)
                Text(verbatim: app.data.isEmpty ? L("no data") : L("app \(Bytes.format(app.bundleBytes)) · data \(Bytes.format(app.dataBytes))"))
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.tertiary)
            }
            .frame(width: 230, alignment: .trailing)
            Button { model.installed.reveal(app) } label: { Image(systemName: "folder") }.buttonStyle(.plain).foregroundStyle(Theme.secondary).help("Show in Finder")
            if suggested {
                Button("Keep") { model.installed.keep(app, model: model) }.buttonStyle(QuietButtonStyle()).help("Never suggest it again (Settings › Applications)")
            }
            Button("Remove…") { model.installed.pending = app }
                .buttonStyle(CopperButtonStyle(prominent: false))
                .disabled(app.isApple || app.isRunning)
                .help(app.isApple ? L("It comes with macOS.") : app.isRunning ? L("Quit it first.") : "")
        }
        .padding(.vertical, 6)
    }

    private var usage: String {
        let last = app.lastUsed.map { L("last opened \(TimeFormat.ago($0))") } ?? L("no record of being opened")
        guard app.foregroundSeconds >= 60 else { return last }
        return last + " · " + L("\(InstalledAppsSection.hours(app.foregroundSeconds)) in front over \(app.daysUsed) days")
    }
}

/// Confirms removing one app, showing exactly what goes to the Trash.
private struct UninstallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let app: InstalledApp
    @State private var withData = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: model.installed.icon(app)).resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Remove \(app.name)?")).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(app.lastUsed.map { L("Last opened \(TimeFormat.ago($0)).") } ?? L("No record of being opened.")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                line(L("Application"), app.path, app.bundleBytes)
                if !app.data.isEmpty {
                    Toggle(L("Also its data: \(app.data.count) places, \(Bytes.format(app.dataBytes))"), isOn: $withData).toggleStyle(.checkbox).font(.system(size: 12)).padding(.top, 4)
                    ForEach(app.data) { place in line(place.kind, place.path, place.bytes).opacity(withData ? 1 : 0.4) }
                }
            }
            .panel()
            if !app.startupLabels.isEmpty {
                Text(L("Its startup items stay until you switch them off in Startup: \(app.startupLabels.joined(separator: ", ")).")).font(.system(size: 11)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
            }
            Text("Everything goes to the Trash and can be put back from the Overview until the Trash is emptied. Settings and documents you saved elsewhere are not touched.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(QuietButtonStyle())
                Button("Move to Trash") { model.installed.uninstall(app, withData: withData) }.keyboardShortcut(.defaultAction).buttonStyle(CopperButtonStyle())
            }
        }
        .padding(18)
        .frame(width: 520)
        .background(Theme.background)
    }

    private func line(_ kind: String, _ path: String, _ bytes: Int64) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: kind).font(.system(size: 11)).foregroundStyle(Theme.secondary).frame(width: 120, alignment: .leading)
            Text(verbatim: PathUtil.display(path)).font(Theme.mono).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(verbatim: Bytes.format(bytes)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.text)
        }
    }
}
