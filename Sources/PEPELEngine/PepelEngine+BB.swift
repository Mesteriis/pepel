import Foundation
import PEPELCore
import PEPELProcesses

/// BB, the agent IDE: its threads, what they hold, and releasing idle ones through BB itself.
extension PepelEngine {
    static let bbReleasedKey = "bb.released"

    nonisolated func bbCommand() -> @Sendable ([String]) -> String? {
        if let bbOverride { return bbOverride }
        let tools = tools
        return { arguments in
            guard let result = tools.run("bb", arguments, timeout: 20), result.status == 0 else { return nil }
            return result.output
        }
    }

    /// BB's threads from its command line, with what its processes hold now.
    public func bbState(now: Date = Date()) async -> BBState {
        let usage = BBProcesses.usage(processSource.snapshot(), home: paths.home)
        let run = bbCommand()
        let released = store.loadCodable([String: Date].self, key: Self.bbReleasedKey) ?? [:]
        var threads: [BBThread] = []
        var cli = false
        if usage.running {
            let (threadData, projectData) = await Task.detached(priority: .utility) { (run(["thread", "list", "--json"]), run(["project", "list", "--json"])) }.value
            if let threadData {
                cli = true
                threads = Self.parseBBThreads(threadData, projects: projectData, released: released)
            }
        }
        return BBState(
            running: usage.running, cliAvailable: cli, threads: threads, runtimeCount: usage.runtimeCount, runtimeBytes: usage.runtimeBytes,
            runtimeProcesses: usage.runtimeProcesses, appBytes: usage.appBytes,
            plugins: usage.plugins.map { BBState.Plugin(name: $0.key, bytes: $0.value.bytes, processCount: $0.value.count) }.sorted { $0.bytes > $1.bytes }, at: now)
    }

    static func parseBBThreads(_ json: String, projects: String?, released: [String: Date]) -> [BBThread] {
        guard let list = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else { return [] }
        var names: [String: String] = [:]
        if let projects, let items = (try? JSONSerialization.jsonObject(with: Data(projects.utf8))) as? [[String: Any]] {
            for item in items { if let id = item["id"] as? String, let name = item["name"] as? String { names[id] = name } }
        }
        func date(_ value: Any?) -> Date? { (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }
        return list.compactMap { item in
            guard let id = item["id"] as? String, item["archivedAt"] is NSNull || item["archivedAt"] == nil, item["deletedAt"] is NSNull || item["deletedAt"] == nil else { return nil }
            let activity = item["activity"] as? [String: Any] ?? [:]
            let running = activity.values.contains { ($0 as? NSNumber)?.intValue ?? 0 > 0 }
            let queued = (item["queuedWork"] as? String).map { $0 != "none" } ?? false
            let last = [date(item["updatedAt"]), date(item["lastReadAt"]), date(item["latestAttentionAt"])].compactMap { $0 }.max() ?? .distantPast
            let title = (item["title"] as? String) ?? (item["titleFallback"] as? String) ?? id
            let project = item["projectId"] as? String
            return BBThread(
                id: id, title: title, projectID: project, projectName: project.flatMap { names[$0] }, providerID: item["providerId"] as? String,
                status: item["status"] as? String ?? "unknown", lastActivity: last, busy: running || queued, releasedAt: released[id])
        }
        .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Asks BB to release the agent runtime of idle threads (`bb thread stop`): the thread, its
    /// history and environment stay, and the next message starts the runtime again. Never a
    /// thread that is working, queued or waiting; never by an agent; automatically only when the
    /// rule is on. What is recorded as freed is measured on BB's runtimes before and after.
    public func releaseBBThreads(_ ids: [String]? = nil, confirmed: Bool, initiator: Initiator, now: Date = Date()) async -> (denial: String?, released: [BBThread], freedBytes: Int64) {
        switch initiator {
        case .agent: return (L("Agents cannot release BB threads."), [], 0)
        case .automatic: if !settings.releaseIdleBBThreads || settings.paused { return (L("Releasing idle BB threads is not switched on."), [], 0) }
        case .user, .cli: if !confirmed { return (L("This needs your confirmation."), [], 0) }
        }
        // Decided on a fresh reading of BB, not on what was shown.
        let state = await bbState(now: now)
        guard state.cliAvailable else { return (state.running ? L("The bb command line did not answer.") : L("BB is not running."), [], 0) }
        let minutes = initiator == .automatic ? settings.bbThreadIdleMinutes : 0
        let chosen = state.threads.filter { thread in
            (ids.map { $0.contains(thread.id) } ?? true) && (initiator == .automatic || ids == nil ? thread.isReleasable(minutes: minutes, now: now) : (thread.status == "idle" && !thread.busy))
        }
        if chosen.isEmpty { return (ids == nil ? nil : L("None of these threads is idle with nothing pending."), [], 0) }
        let before = state.runtimeBytes
        let run = bbCommand()
        let stopped = await Task.detached(priority: .utility) { chosen.filter { run(["thread", "stop", $0.id]) != nil } }.value
        guard !stopped.isEmpty else { return (L("BB did not accept the request."), [], 0) }
        var released = store.loadCodable([String: Date].self, key: Self.bbReleasedKey) ?? [:]
        for thread in stopped { released[thread.id] = now }
        try? store.saveCodable(released.filter { now.timeIntervalSince($0.value) < 7 * 86_400 }, key: Self.bbReleasedKey)
        // BB ends the runtime's processes after it answers; give it a moment, then measure.
        try? await Task.sleep(for: .seconds(paths.isRedirected ? 0 : 4))
        let after = BBProcesses.usage(processSource.snapshot(), home: paths.home).runtimeBytes
        let freed = max(0, before - after)
        store.appendAudit(
            AuditEntry(
                kind: .termination, initiator: initiator.rawValue, subject: "BB threads: \(stopped.count)", outcome: "released", bytes: freed,
                detail: ["threads": stopped.map { "\($0.id) \($0.title)" }.joined(separator: "\n"), "runtimeBefore": Bytes.format(before), "runtimeAfter": Bytes.format(after)]))
        return (nil, stopped, freed)
    }

    /// At most every five minutes, when the rule is on and BB runs.
    func autoReleaseBBThreads(now: Date = Date()) async {
        guard settings.releaseIdleBBThreads, !settings.paused else { return }
        let last = store.value("bb.lastAutoRelease").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
        guard now.timeIntervalSince(last) >= 300 else { return }
        try? store.setValue(String(now.timeIntervalSince1970), for: "bb.lastAutoRelease")
        guard BBProcesses.usage(processSource.snapshot(), home: paths.home).runtimeCount > 0 else { return }
        _ = await releaseBBThreads(confirmed: false, initiator: .automatic, now: now)
    }
}
