import Foundation
import Testing

@testable import PEPELAgents
@testable import PEPELCore
@testable import PEPELEngine
@testable import PEPELPersistence
@testable import PEPELProcesses

/// A scripted `bb` command line that records what it was asked.
final class FakeBB: @unchecked Sendable {
    let lock = NSLock()
    var calls: [[String]] = []
    var threads: String

    init(now: Date) {
        func ms(_ minutesAgo: Double) -> Int { Int((now.timeIntervalSince1970 - minutesAgo * 60) * 1000) }
        threads = """
            [
             {"id":"thr_quiet","projectId":"proj_a","providerId":"codex","title":"Quiet one","status":"idle","updatedAt":\(ms(40)),"lastReadAt":\(ms(41)),"activity":{"activeBackgroundAgentCount":0},"queuedWork":"none","archivedAt":null,"deletedAt":null},
             {"id":"thr_recent","projectId":"proj_a","providerId":"codex","title":"Recent","status":"idle","updatedAt":\(ms(5)),"activity":{},"queuedWork":"none","archivedAt":null},
             {"id":"thr_running","projectId":"proj_a","title":"Working","status":"running","updatedAt":\(ms(60)),"activity":{},"queuedWork":"none","archivedAt":null},
             {"id":"thr_background","projectId":"proj_a","title":"Background command","status":"idle","updatedAt":\(ms(60)),"activity":{"activeBackgroundCommandCount":1},"queuedWork":"none","archivedAt":null},
             {"id":"thr_queued","projectId":"proj_a","title":"Queued","status":"idle","updatedAt":\(ms(60)),"activity":{},"queuedWork":"queued","archivedAt":null},
             {"id":"thr_old","projectId":"proj_a","title":"Old","status":"idle","updatedAt":\(ms(3 * 24 * 60)),"activity":{},"queuedWork":"none","archivedAt":null},
             {"id":"thr_archived","projectId":"proj_a","title":"Archived","status":"idle","updatedAt":\(ms(60)),"activity":{},"archivedAt":1}
            ]
            """
    }

    func run(_ arguments: [String]) -> String? {
        lock.lock(); defer { lock.unlock() }
        calls.append(arguments)
        switch Array(arguments.prefix(2)) {
        case ["thread", "list"]: return threads
        case ["project", "list"]: return #"[{"id":"proj_a","name":"alpha"}]"#
        case ["thread", "stop"]: return #"{"ok":true}"#
        default: return nil
        }
    }

    var stopped: [String] { lock.lock(); defer { lock.unlock() }; return calls.filter { $0.prefix(2) == ["thread", "stop"] }.map { $0[2] } }
}

@Suite("BB, the agent IDE")
struct BBTests {
    let app = "/Applications/bb.app/Contents/MacOS/bb"

    func bbProcesses(home: String) -> [ProcessSnapshot] {
        [
            process(100, parent: 1, name: "bb", path: app, args: [app], footprint: 200 * Bytes.mb),
            process(101, parent: 100, name: "bb", path: app, args: [app, "/x/host-daemon/dist/daemon-bundle.mjs"], footprint: 100 * Bytes.mb),
            process(102, parent: 101, name: "bb", path: app, args: [app, "/x/host-daemon/dist/bb-provider-bridge-worker.mjs", home + "/.bb/plugin-host-artifacts/provider-codex/abc/host.mjs"], footprint: 90 * Bytes.mb),
            process(103, parent: 102, name: "codex", path: "/opt/homebrew/bin/codex", args: ["/opt/homebrew/bin/codex", "app-server"], footprint: 300 * Bytes.mb),
            process(104, parent: 103, name: "node", path: "/usr/local/bin/node", args: ["node", "mcp.js"], footprint: 80 * Bytes.mb),
            process(105, parent: 101, name: "bb", path: app, args: [app, "/x/host-daemon/dist/bb-plugin-host-worker.mjs", home + "/.bb/plugin-host-artifacts/gigaam/def/host.mjs", "gigaam"], footprint: 120 * Bytes.mb),
            process(106, parent: 1, name: "python", path: home + "/.bb/plugins/gigaam/host-data/venv/bin/python", args: [home + "/.bb/plugins/gigaam/host-data/venv/bin/python", "server.py"], footprint: 1500 * Bytes.mb),
            process(200, parent: 1, name: "codex", path: "/opt/homebrew/bin/codex", args: ["/opt/homebrew/bin/codex", "app-server"], footprint: 50 * Bytes.mb),
        ]
    }

    @Test("BB's memory splits into the app, thread runtimes and plugins; its agent is tagged as BB's")
    func usageAndTagging() {
        let home = "/Users/me"
        let processes = bbProcesses(home: home)
        let usage = BBProcesses.usage(processes, home: home)
        #expect(usage.running && usage.runtimeCount == 1 && usage.runtimeProcesses == 3 && usage.runtimeBytes == 470 * Bytes.mb)
        #expect(usage.appBytes == 300 * Bytes.mb)
        #expect(usage.plugins["gigaam"]?.bytes == 1620 * Bytes.mb && usage.plugins["gigaam"]?.count == 2)
        let sessions = AgentDetector.sessions(processes: processes, attributor: nil)
        #expect(sessions.first { $0.root.pid == 103 }?.hostApp == "BB")
        #expect(sessions.first { $0.root.pid == 200 }?.hostApp == nil, "a Codex server of another app is not BB's")
    }

    @Test("A thread is releasable only when idle, with nothing pending, quiet long enough and less than a day")
    func releasable() {
        let now = Date(), fake = FakeBB(now: now)
        let threads = PepelEngine.parseBBThreads(fake.threads, projects: #"[{"id":"proj_a","name":"alpha"}]"#, released: [:])
        #expect(!threads.contains { $0.id == "thr_archived" })
        #expect(threads.first { $0.id == "thr_quiet" }?.projectName == "alpha")
        #expect(threads.filter { $0.isReleasable(minutes: 15, now: now) }.map(\.id) == ["thr_quiet"])
        var released = threads.first { $0.id == "thr_quiet" }!
        released.releasedAt = now
        #expect(!released.isReleasable(minutes: 15, now: now), "not again until it is used")
    }

    @Test("Releasing asks BB to stop idle threads only, never for an agent or with the rule off, and is recorded")
    func release() async throws {
        let f = Fixture(), now = Date(), fake = FakeBB(now: now)
        let store = try PepelStore.inMemory()
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled, analyzers: [],
            processSource: FakeProcessSource(processes: bbProcesses(home: f.home)), telemetry: { SystemTelemetry() })
        await engine.setBBCommand { fake.run($0) }
        _ = await engine.actionNotices()

        #expect(await engine.releaseBBThreads(confirmed: true, initiator: .agent).denial != nil)
        #expect(await engine.releaseBBThreads(confirmed: false, initiator: .automatic).denial != nil, "the rule is off by default")
        #expect(await engine.releaseBBThreads(confirmed: false, initiator: .user).denial != nil)
        #expect(fake.stopped.isEmpty)

        let state = await engine.bbState(now: now)
        #expect(state.cliAvailable && state.threads.count == 6)
        // By hand, a chosen thread that is working or busy is refused.
        #expect(await engine.releaseBBThreads(["thr_running", "thr_background", "thr_queued"], confirmed: true, initiator: .cli).released.isEmpty)
        #expect(fake.stopped.isEmpty)

        _ = try await engine.update { $0.releaseIdleBBThreads = true; $0.bbThreadIdleMinutes = 15 }
        let result = await engine.releaseBBThreads(confirmed: false, initiator: .automatic, now: now)
        #expect(result.denial == nil && result.released.map(\.id) == ["thr_quiet"] && fake.stopped == ["thr_quiet"])
        #expect(store.audit(limit: 5, kinds: [.termination]).first?.outcome == "released")
        #expect(await engine.actionNotices().contains { $0.title.contains("BB") })
        // Not asked again while the thread stays quiet.
        _ = await engine.releaseBBThreads(confirmed: false, initiator: .automatic, now: now.addingTimeInterval(60))
        #expect(fake.stopped == ["thr_quiet"])
    }
}
