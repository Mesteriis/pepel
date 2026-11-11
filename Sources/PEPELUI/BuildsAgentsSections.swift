import PEPELEngine
import SwiftUI

struct BuildsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(
                title: "Builds",
                subtitle: "Build generations per repository, with the retention verdict for each. PEPEL knows a build's outcome only when it ran through `pepel run`; otherwise the status is shown as unknown.")
            if let storage = model.storage, !storage.builds.isEmpty {
                global(storage)
                ForEach(storage.builds) { summary in card(summary) }
            } else {
                EmptyState(
                    symbol: "hammer", title: model.storage == nil ? "No scan yet" : "No build artifacts found",
                    message: "Xcode DerivedData, SwiftPM, Cargo, CMake, Node and Python build output appears here once a scan finds it.")
            }
        }
    }

    private func global(_ storage: StorageState) -> some View {
        let fraction = Double(storage.buildTotalBytes) / Double(max(1, storage.globalBuildBudgetBytes))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Caption("Global build budget")
                Spacer()
                Text("\(Bytes.format(storage.buildTotalBytes)) of \(Bytes.format(storage.globalBuildBudgetBytes))").font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(Theme.text)
            }
            Meter(fraction: fraction, tint: fraction > 1 ? Theme.ember : fraction > 0.8 ? Theme.amber : Theme.forest, height: 6)
            let running = model.live?.activeBuildCount ?? 0
            Text("\(running == 0 ? "No builds are" : running == 1 ? "One build is" : "\(running) builds are") running now. PEPEL warns before budgets are exceeded and proposes old generations; it cannot stop other tools from writing more.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
        .panel()
    }

    private func card(_ summary: ProjectBuildSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                if !summary.attributed { Badge(text: "no known project", tint: Theme.tertiary) }
                Spacer()
                if let budget = summary.budgetBytes {
                    Text("\(Bytes.format(summary.totalBytes)) / \(Bytes.format(budget))").font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(summary.overBudget ? Theme.ember : Theme.secondary)
                }
            }
            Text(summary.narrative).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            if let fraction = summary.budgetFraction {
                Meter(fraction: fraction, tint: summary.overBudget ? Theme.ember : summary.nearBudget ? Theme.amber : Theme.forest)
            }
            Text("Policy: keep last \(summary.policy.keepSuccessful) builds, \(summary.policy.keepFailed) failed, review after \(summary.policy.reviewAfterHours) h\(summary.policy.maxAgeDays.map { ", max age \($0) d" } ?? "").")
                .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            VStack(spacing: 0) {
                ForEach(summary.generations) { generation in
                    Divider().overlay(Theme.stroke.opacity(0.6))
                    row(generation)
                }
            }
        }
        .panel()
    }

    private func row(_ g: BuildGeneration) -> some View {
        HStack(spacing: 10) {
            Text((g.sizeIsApproximate ? "≤ " : "") + Bytes.format(g.sizeBytes)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 76, alignment: .trailing)
            Badge(text: g.system.displayName).frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(g.title).font(.system(size: 12)).lineLimit(1)
                    if let branch = g.branch { Label(branch, systemImage: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1) }
                    if g.status != .unknown { Badge(text: g.status.rawValue, tint: g.status == .failed ? Theme.ember : Theme.forest) }
                }
                Text(g.activeReason ?? g.verdict.reason).font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(TimeFormat.ago(g.timestamp)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.tertiary).frame(width: 84, alignment: .trailing)
            verdictBadge(g).frame(width: 78, alignment: .trailing)
            Button {
                model.setPinned(g.path, !g.isPinned)
            } label: {
                Image(systemName: g.isPinned ? "pin.fill" : "pin").font(.system(size: 11)).foregroundStyle(g.isPinned ? Theme.copper : Theme.tertiary)
            }
            .buttonStyle(.plain).help(g.isPinned ? "Unpin this build" : "Pin: keep this build regardless of retention")
            .accessibilityLabel(g.isPinned ? "Unpin \(g.title)" : "Pin \(g.title)")
        }
        .foregroundStyle(Theme.text)
        .padding(.vertical, 5)
        .help(g.path)
    }

    private func verdictBadge(_ g: BuildGeneration) -> some View {
        if g.isActive { return Badge(text: "active", tint: Theme.forest) }
        if g.isPinned { return Badge(text: "pinned", tint: Theme.copper) }
        return g.verdict.isCandidate ? Badge(text: "candidate", tint: Theme.copper) : Badge(text: "kept", tint: Theme.secondary)
    }
}

struct AgentsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(
                title: "Agents",
                subtitle: "Agent sessions are found by watching processes, not by reading the agents' private files. Their state, history and credentials are always protected.")
            sessions
            helpers
            leases
            integration
        }
    }

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption("Running sessions")
            if let live = model.live, !live.agentSessions.isEmpty {
                ForEach(live.agentSessions) { session in
                    HStack(spacing: 10) {
                        Badge(
                            text: session.frozenSince != nil ? "suspended" : session.state == .working ? "working" : session.state == .sleeping ? "asleep" : "idle",
                            tint: session.frozenSince != nil ? Theme.copper : session.state == .working ? Theme.forest : session.state == .sleeping ? Theme.amber : Theme.tertiary
                        )
                        .frame(width: 62, alignment: .leading)
                        .help(session.evidence.joined(separator: "\n"))
                        Text(session.kind.displayName + (session.isService ? " server" : "")).font(.system(size: 12, weight: .semibold)).frame(width: 110, alignment: .leading).lineLimit(1)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(model.projectName(session.projectID) ?? "No known project").font(.system(size: 12))
                                    .foregroundStyle(session.projectID == nil ? Theme.tertiary : Theme.text)
                                if session.projectID != nil { ConfidenceBadge(confidence: session.projectConfidence) }
                                if session.activeBuildCount > 0 { Badge(text: "\(session.activeBuildCount) build process\(session.activeBuildCount == 1 ? "" : "es")", tint: Theme.forest) }
                            }
                            if let cwd = session.workingDirectory { PathText(path: cwd) }
                        }
                        Spacer(minLength: 4)
                        if let quiet = session.quietSince, session.state != .working {
                            Text("quiet \(TimeFormat.age(Date().timeIntervalSince(quiet)))").font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(session.state == .sleeping ? Theme.amber : Theme.secondary)
                        }
                        if session.frozenSince != nil {
                            Button("Wake") { model.thaw(session) }.buttonStyle(QuietButtonStyle()).help("Continue this session now.")
                        } else if !session.isService, session.state != .working {
                            Button("Suspend") { model.freeze(session) }.buttonStyle(QuietButtonStyle())
                                .help("Pause this session without ending it. Nothing is lost; it continues when its application comes to the front or you press Wake.")
                        }
                        Text("\(session.processCount) proc").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary)
                        Text(Bytes.format(session.footprintBytes)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 70, alignment: .trailing)
                        Text(TimeFormat.age(Date().timeIntervalSince(session.startedAt))).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.tertiary).frame(width: 64, alignment: .trailing)
                    }
                    .foregroundStyle(Theme.text).padding(.vertical, 3)
                    .accessibilityElement(children: .combine)
                }
                Text("While a session runs in a project, that project's build output is not cleaned automatically, and cleaning it by hand asks for confirmation.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                Text(
                    "A session is asleep after \(model.settings.agentSleepMinutes) minutes without disk writes, CPU bursts, new processes or a build. "
                        + (model.settings.terminateSleepingAgents
                            ? "Sleeping sessions are terminated automatically, together with the tool servers they started."
                            : "Sleeping sessions are only reported; automatic termination is off (Settings › Process guardian).")
                )
                .font(.system(size: 11)).foregroundStyle(model.settings.terminateSleepingAgents ? Theme.amber : Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No Claude Code, Codex, OpenCode or Hermes session is running.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        .panel()
    }

    /// The same tool server started by every session.
    @ViewBuilder private var helpers: some View {
        if let groups = model.live?.agentHelpers, !groups.isEmpty {
            let duplicated = groups.reduce(Int64(0)) { $0 + $1.duplicatedBytes }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Caption("Same helper, one copy per session")
                    Spacer()
                    Text("\(Bytes.format(duplicated)) in extra copies").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Theme.amber)
                }
                ForEach(groups.prefix(12)) { group in
                    HStack(spacing: 10) {
                        Text("×\(group.copies)").font(.system(size: 12, weight: .semibold)).monospacedDigit().frame(width: 34, alignment: .trailing)
                        Text(group.id).font(Theme.mono).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text("\(group.sessions) sessions").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        Text(Bytes.format(group.footprintBytes)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 66, alignment: .trailing)
                    }
                    .foregroundStyle(Theme.text)
                    .accessibilityElement(children: .combine)
                }
                Text("PEPEL cannot merge these: every session starts its own. Closing idle sessions frees them; so does running a server once and connecting sessions to it over HTTP.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .panel()
        }
    }

    private var leases: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption("Resource leases")
            if model.leases.isEmpty {
                Text("No active leases. Agents and builds can lease a path to protect it for a limited time; when a lease ends, normal usage checks still apply before anything is proposed.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.leases) { lease in
                HStack(spacing: 10) {
                    Text(lease.owner).font(.system(size: 12, weight: .medium)).frame(width: 120, alignment: .leading).lineLimit(1)
                    PathText(path: lease.path)
                    Spacer()
                    if !lease.purpose.isEmpty { Badge(text: String(lease.purpose.prefix(28))) }
                    Text("until \(lease.expiresAt.formatted(date: .omitted, time: .shortened))").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                .foregroundStyle(Theme.text)
            }
        }
        .panel()
    }

    private var integration: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Caption("Local agent interface")
                Spacer()
                Badge(text: model.apiStatus, tint: model.apiStatus == "Listening" ? Theme.forest : Theme.amber)
            }
            Text("Agents can register builds and workspaces, lease or protect paths, mark their own temporary files, request a scan and preview cleanup. They cannot delete files or terminate processes.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            Text("pepel agent lease.acquire owner=my-agent path=./.build seconds=3600").font(Theme.mono).foregroundStyle(Theme.text).textSelection(.enabled)
            Text("Socket \(PathUtil.display(model.engine.paths.socket)) · owner-only, same-user, token-authenticated").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
        }
        .panel()
    }
}
