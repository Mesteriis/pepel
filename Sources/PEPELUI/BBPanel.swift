import Observation
import PEPELEngine
import SwiftUI

/// BB's state for the Agents screen.
@MainActor
@Observable
public final class BBModel {
    let engine: PepelEngine
    public var state: BBState?
    public var isLoading = false
    public var isReleasing = false
    public var message: String?
    public var confirmRelease = false

    init(engine: PepelEngine) { self.engine = engine }

    public func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            let fresh = await engine.bbState()
            withAnimation(.easeOut(duration: 0.2)) { state = fresh }
            isLoading = false
        }
    }

    /// Idle threads with a runtime, or the ones given.
    public func release(_ ids: [String]? = nil) {
        isReleasing = true
        Task {
            let result = await engine.releaseBBThreads(ids, confirmed: true, initiator: .user)
            isReleasing = false
            if let denial = result.denial {
                message = denial
            } else {
                message = L("BB released \(result.released.count) threads; its runtimes hold \(Bytes.format(result.freedBytes)) less. The threads resume with the next message.")
            }
            refresh()
        }
    }
}

/// BB's threads and what they hold, with releasing idle ones through BB itself.
struct BBPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let bb = model.bb
        Group {
            if let state = bb.state, state.running {
                VStack(alignment: .leading, spacing: 10) {
                    header(state)
                    figures(state)
                    if state.cliAvailable {
                        threads(state)
                    } else {
                        Text("The bb command line did not answer, so BB's threads are not known. Install it from BB (Settings › Command line) to manage them here.")
                            .font(.system(size: 12)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                    }
                    if let message = bb.message {
                        Text(message).font(.system(size: 11)).foregroundStyle(Theme.forest).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .panel()
            }
        }
        .onAppear { if bb.state == nil { bb.refresh() } }
        .confirmationDialog(L("Release idle BB threads?"), isPresented: Binding(get: { bb.confirmRelease }, set: { bb.confirmRelease = $0 }), titleVisibility: .visible) {
            Button("Release") { bb.release() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("BB stops the agent and its MCP servers of each idle thread with nothing pending. The threads, their history and environments stay; the next message starts them again.")
        }
    }

    /// BB's status words, in the app's language; an unknown one is shown as BB wrote it.
    static func statusTitle(_ status: String) -> String {
        switch status {
        case "idle": L(LocalizedStringResource("bb.idle", defaultValue: "idle"))
        case "running": L(LocalizedStringResource("bb.running", defaultValue: "running"))
        case "error": L(LocalizedStringResource("bb.error", defaultValue: "error"))
        case "waiting": L(LocalizedStringResource("bb.waiting", defaultValue: "waiting"))
        default: status
        }
    }

    private func releasable(_ state: BBState) -> [BBThread] {
        state.threads.filter { $0.isReleasable(minutes: 0) }
    }

    private func header(_ state: BBState) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Caption("BB")
            Text(L("holds \(Bytes.format(state.totalBytes))")).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary)
            Spacer()
            if model.bb.isLoading || model.bb.isReleasing { ProgressView().controlSize(.mini) }
            Button("Look again") { model.bb.refresh() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.copper)
            Button(L("Release idle threads")) { model.bb.confirmRelease = true }
                .buttonStyle(CopperButtonStyle(prominent: false))
                .disabled(releasable(state).isEmpty || model.bb.isReleasing)
                .help(L("\(releasable(state).count) idle threads quiet for less than a day may still hold an agent runtime"))
        }
    }

    private func figures(_ state: BBState) -> some View {
        HStack(spacing: 18) {
            figure("Agent runtimes", "\(state.runtimeCount)", L("\(Bytes.format(state.runtimeBytes)) in \(state.runtimeProcesses) processes"))
            figure("App, server and daemon", Bytes.format(state.appBytes), nil)
            if let plugin = state.plugins.first {
                figure("Plugins", Bytes.format(state.plugins.reduce(0) { $0 + $1.bytes }), L("most: \(plugin.name), \(Bytes.format(plugin.bytes))"))
            }
            Spacer()
        }
    }

    private func figure(_ label: LocalizedStringKey, _ value: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Caption(label)
            Text(verbatim: value).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text)
            if let detail { Text(verbatim: detail).font(.system(size: 10)).foregroundStyle(Theme.tertiary) }
        }
    }

    private func threads(_ state: BBState) -> some View {
        let recent = state.threads.filter { Date().timeIntervalSince($0.lastActivity) < BBThread.runtimeWindow }
        let settings = model.settings
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(recent.prefix(12)) { thread in
                Divider().overlay(Theme.stroke.opacity(0.6))
                HStack(spacing: 8) {
                    Badge(text: thread.busy ? L("busy") : Self.statusTitle(thread.status), tint: thread.status == "idle" && !thread.busy ? Theme.tertiary : thread.status == "error" ? Theme.amber : Theme.forest)
                    Text(verbatim: thread.title).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                    if let project = thread.projectName { Text(verbatim: project).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1) }
                    Spacer(minLength: 6)
                    Text(verbatim: thread.releasedAt.map { _ in L("released") } ?? L("quiet \(TimeFormat.age(Date().timeIntervalSince(thread.lastActivity)))"))
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.tertiary)
                    Button("Release") { model.bb.release([thread.id]) }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(thread.status != "idle" || thread.busy || model.bb.isReleasing)
                }
                .padding(.vertical, 4)
            }
            Text(settings.releaseIdleBBThreads
                ? L("Idle threads are released after \(settings.bbThreadIdleMinutes) min of quiet (Settings › Agent sessions). \(state.threads.count - recent.count) older threads hold no runtime.")
                : L("BB releases an idle thread's runtime after 30 min; PEPEL can do it sooner (Settings › Agent sessions). \(state.threads.count - recent.count) older threads hold no runtime."))
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
        }
    }
}
