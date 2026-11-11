import Foundation
import Testing
@testable import PEPELCleanup
@testable import PEPELEngine
@testable import PEPELStorage

/// A scripted `docker`: answers from fixtures and records every command line.
final class DockerScript: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [[String]] = []
    var df: String
    var refuse: Set<String> = []

    init(df: String) { self.df = df }

    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return log }

    func answer(_ arguments: [String]) -> (status: Int32, output: String)? {
        lock.lock()
        log.append(arguments)
        lock.unlock()
        switch arguments.first {
        case "system":
            return arguments.contains("-v") ? (0, df) : (0, "40GB\n2GB\n60GB\n29GB\n")
        case "inspect":
            return (0, "c-old\t2026-09-01T10:00:00.123456789Z\nc-new\t2026-11-10T10:00:00Z\nc-run\t0001-01-01T00:00:00Z\nc-keep\t2026-08-01T10:00:00Z\nc-stack\t2026-08-01T10:00:00Z\n")
        case "image":
            return (0, "img-old\t2026-08-01T10:00:00Z\nimg-shared\t2026-08-01T10:00:00Z\nimg-fresh\t2026-11-09T10:00:00Z\nimg-run\t2026-08-01T10:00:00Z\n")
        case "volume":
            if arguments.dropFirst().first == "inspect" { return (0, "vol-old\t2026-08-01T10:00:00Z\nvol-new\t2026-11-09T10:00:00Z\nvol-used\t2026-08-01T10:00:00Z\n") }
            return refuse.contains(arguments.last ?? "") ? (1, "") : (0, (arguments.last ?? "") + "\n")
        case "rm":
            return (0, arguments.dropFirst().filter { !refuse.contains($0) }.joined(separator: "\n") + "\n")
        case "rmi":
            return refuse.contains(arguments.last ?? "") ? (1, "") : (0, "Deleted: \(arguments.last ?? "")\n")
        case "builder":
            return (0, "ID\tRECLAIMABLE\nTotal reclaimed space: 6.29GB\n")
        case "network":
            return (0, "Deleted Networks:\nold_default\n")
        case "images":
            return (0, "postgres:17\nredis:7-alpine\n<none>:<none>\n")
        case "run":
            return (0, "/var/lib/docker: 20 GiB (21474836480 bytes) trimmed\n")
        default:
            return nil
        }
    }
}

@Suite("Disk cleaning")
struct DiskTests {
    static let now = ISO8601DateFormatter().date(from: "2026-11-11T12:00:00Z")!

    static let df = """
        {"Images":[
          {"ID":"img-old","Repository":"old/app","Tag":"1","CreatedAt":"2026-07-01 10:00:00 +0000 UTC","Size":"1GB","UniqueSize":"800MB"},
          {"ID":"img-shared","Repository":"<none>","Tag":"<none>","CreatedAt":"2026-07-01 10:00:00 +0000 UTC","Size":"2GB","UniqueSize":"2GB"},
          {"ID":"img-fresh","Repository":"new/app","Tag":"2","CreatedAt":"2026-07-01 10:00:00 +0000 UTC","Size":"3GB","UniqueSize":"3GB"},
          {"ID":"img-run","Repository":"db","Tag":"17","CreatedAt":"2026-07-01 10:00:00 +0000 UTC","Size":"500MB","UniqueSize":"500MB"}],
         "Containers":[
          {"ID":"c-old","Names":"old-job","Image":"img-old","State":"exited","CreatedAt":"2026-08-30 10:00:00 +0200 CEST","Size":"100MB (virtual 1GB)","Labels":"com.docker.compose.project=gone"},
          {"ID":"c-new","Names":"new-job","Image":"img-shared","State":"exited","CreatedAt":"2026-11-10 10:00:00 +0100 CET","Size":"10MB","Labels":""},
          {"ID":"c-run","Names":"db","Image":"img-run","State":"running","CreatedAt":"2026-08-01 10:00:00 +0200 CEST","Size":"1MB","Labels":"com.docker.compose.project=live"},
          {"ID":"c-keep","Names":"vault","Image":"img-run","State":"exited","CreatedAt":"2026-08-01 10:00:00 +0200 CEST","Size":"1MB","Labels":"pepel.keep=true"},
          {"ID":"c-stack","Names":"live-migrate","Image":"img-run","State":"exited","CreatedAt":"2026-08-01 10:00:00 +0200 CEST","Size":"1MB","Labels":"com.docker.compose.project=live"}],
         "Volumes":[
          {"Name":"vol-old","Links":"0","Size":"5GB","Labels":"com.docker.volume.anonymous="},
          {"Name":"vol-new","Links":"0","Size":"1GB","Labels":""},
          {"Name":"vol-used","Links":"1","Size":"9GB","Labels":"com.docker.compose.project=live"}],
         "BuildCache":[
          {"Size":"4GB","LastUsedAt":"2026-09-01 09:25:01.033911041 +0000 UTC","InUse":"false"},
          {"Size":"2GB","LastUsedAt":"2026-11-09 09:25:01.033911041 +0000 UTC","InUse":"false"},
          {"Size":"1GB","LastUsedAt":"2026-08-01 09:25:01 +0000 UTC","InUse":"true"},
          {"Size":"8GB","LastUsedAt":"","InUse":"false"}]}
        """

    @Test("Docker's three date shapes and its sizes are read; an unknown date is not a date")
    func dockerParsing() {
        #expect(DockerDisk.date("2026-11-11 08:59:20 +0100 CET") == ISO8601DateFormatter().date(from: "2026-11-11T07:59:20Z"))
        #expect(DockerDisk.date("2026-11-04 09:25:01.033911041 +0000 UTC") == ISO8601DateFormatter().date(from: "2026-11-04T09:25:01Z"))
        #expect(DockerDisk.date("2026-11-11T11:36:40.999671752Z") == ISO8601DateFormatter().date(from: "2026-11-11T11:36:40Z"))
        #expect(DockerDisk.date("0001-01-01T00:00:00Z") == nil && DockerDisk.date("") == nil && DockerDisk.date(nil) == nil)
        #expect(DockerDisk.size("673.3MB") == 673_300_000 && DockerDisk.size("8.19kB") == 8190 && DockerDisk.size("0B") == 0 && DockerDisk.size("1.2GB") == 1_200_000_000)
        #expect(DockerDisk.labels("a=1,com.docker.compose.project=app,flag=")["com.docker.compose.project"] == "app")
    }

    @Test("Only what has been unused long enough is chosen; running stacks, kept containers and fresh images are left alone")
    func dockerPlan() throws {
        let script = DockerScript(df: Self.df)
        let report = try #require(DockerDisk { arguments, _ in script.answer(arguments) }.report())
        #expect(report.containers.count == 5 && report.images.count == 4 && report.volumes.count == 3 && report.buildCache.count == 4)
        #expect(report.containers.first { $0.id == "c-run" }?.finishedAt == nil && report.containers.first { $0.id == "c-old" }?.sizeBytes == 100_000_000)

        let plan = DockerCleanupPlan.make(report, days: 30, keep: [], activeProjects: [], now: Self.now)
        #expect(plan.containers.map(\.id) == ["c-old"], "not the recent one, the running one, the labelled one, or the one of a running stack")
        #expect(plan.images.map(\.id) == ["img-old"], "img-shared still has a container; img-fresh arrived two days ago; img-run is in use")
        #expect(plan.volumes.map(\.name) == ["vol-old"] && plan.bytes(.volumes) == 5_000_000_000)
        #expect(plan.buildCacheEntries == 1 && plan.buildCacheBytes == 4_000_000_000, "not the recent, the in-use, or the undated entry")
        #expect(plan.reproducibleBytes == 100_000_000 + 800_000_000 + 4_000_000_000, "volumes are not part of what can be rebuilt")
        #expect(plan.skipped.count == 4)

        // With an agent in the project, or the project kept, its stopped container stays.
        #expect(DockerCleanupPlan.make(report, days: 30, keep: [], activeProjects: ["gone"], now: Self.now).containers.isEmpty)
        #expect(DockerCleanupPlan.make(report, days: 30, keep: ["gone"], activeProjects: [], now: Self.now).containers.isEmpty)
        // And then the image it uses is not free either.
        #expect(DockerCleanupPlan.make(report, days: 30, keep: ["gone"], activeProjects: [], now: Self.now).images.isEmpty)
        // Zero days takes everything that is not in use, including what has no date.
        let all = DockerCleanupPlan.make(report, days: 0, keep: [], activeProjects: [], now: Self.now)
        #expect(Set(all.containers.map(\.id)) == ["c-old", "c-new"] && Set(all.images.map(\.id)) == ["img-old", "img-shared", "img-fresh"] && all.buildCacheEntries == 3)
    }

    @Test("Removal names every object, never forces, touches volumes only when asked, and trims from a local image")
    func dockerClean() throws {
        let script = DockerScript(df: Self.df)
        let disk = DockerDisk { arguments, _ in script.answer(arguments) }
        let plan = DockerCleanupPlan.make(try #require(disk.report()), days: 30, keep: [], activeProjects: [], now: Self.now)
        let report = disk.clean(plan, kinds: [.containers, .images, .buildCache, .networks], compact: true)
        #expect(report.steps.map(\.kind) == [.containers, .images, .buildCache, .networks] && report.steps.allSatisfy { $0.removed == $0.attempted })
        #expect(script.calls.contains(["rm", "c-old"]) && script.calls.contains(["rmi", "img-old"]))
        #expect(script.calls.contains(["builder", "prune", "--force", "--filter", "until=720h"]))
        #expect(!script.calls.contains { $0.first == "volume" && $0.dropFirst().first == "rm" }, "volumes were not asked for")
        #expect(report.compacted && report.compactNote.contains("trimmed"))
        let trim = try #require(script.calls.first { $0.first == "run" })
        #expect(trim.contains("redis:7-alpine") && trim.contains("--network=none") && trim.last == "nsenter -t 1 -m -- fstrim -v /var/lib/docker")
        let destructive = script.calls.filter { ["rm", "rmi"].contains($0.first ?? "") }.joined()
        #expect(!destructive.contains("-f") && !destructive.contains("--force") && !script.calls.joined().contains("prune") == false)
        #expect(!script.calls.contains { $0.contains("-a") || $0.contains("--all") || $0.contains("--volumes") })

        // Volumes, when asked; a refusal by Docker is reported, not forced.
        script.refuse = ["vol-old"]
        let volumes = disk.clean(plan, kinds: [.volumes], compact: false)
        #expect(volumes.steps.first?.removed == 0 && volumes.steps.first?.notes.first?.contains("refused") == true)
        #expect(script.calls.contains(["volume", "rm", "vol-old"]) && !volumes.compacted)
        // Without an Alpine or BusyBox image nothing is pulled to trim with.
        let bare = DockerDisk { arguments, _ in arguments.first == "images" ? (0, "postgres:17\n") : nil }
        #expect(bare.compact().done == false)
    }

    @Test("Docker cleanup is a person's to ask for, or a daily rule the user switched on; volumes never go on their own")
    func dockerPolicy() async throws {
        let policy = CleanupPolicyEngine()
        var settings = PepelSettings()
        #expect(policy.dockerCleanDenial(kinds: [.images], confirmed: true, initiator: .agent, settings: settings) != nil)
        #expect(policy.dockerCleanDenial(kinds: [.images], confirmed: false, initiator: .user, settings: settings) != nil)
        #expect(policy.dockerCleanDenial(kinds: [.images, .volumes], confirmed: true, initiator: .cli, settings: settings) == nil)
        #expect(policy.dockerCleanDenial(kinds: [.images], confirmed: false, initiator: .automatic, settings: settings) != nil, "off by default")
        settings.dockerAutoClean = true
        #expect(policy.dockerCleanDenial(kinds: [.images, .buildCache], confirmed: false, initiator: .automatic, settings: settings) == nil)
        #expect(policy.dockerCleanDenial(kinds: [.volumes], confirmed: false, initiator: .automatic, settings: settings) != nil)
        #expect(policy.dockerCleanDenial(kinds: [], confirmed: true, initiator: .user, settings: settings) != nil)

        // In the engine: once a day, and only what can be rebuilt.
        let f = Fixture()
        let store = try PepelStore.inMemory()
        let script = DockerScript(df: Self.df.replacingOccurrences(of: "2026-", with: "2020-"))
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled, analyzers: [],
            processSource: FakeProcessSource(processes: []), telemetry: { SystemTelemetry() })
        await engine.setContainerRunner { arguments, _ in script.answer(arguments) }
        _ = await engine.automaticPass()
        #expect(!script.calls.contains { ["rm", "rmi", "builder"].contains($0.first ?? "") }, "off by default")
        _ = try await engine.update { $0.dockerAutoClean = true }
        _ = await engine.automaticPass()
        #expect(script.calls.contains { $0.first == "rmi" } && script.calls.contains { $0.first == "builder" })
        #expect(!script.calls.contains { $0.first == "volume" && $0.dropFirst().first == "rm" })
        #expect(store.audit(kinds: [.cleanup]).contains { $0.subject.hasPrefix("Docker:") && $0.initiator == "automatic" })
        let before = script.calls.count
        _ = await engine.automaticPass()
        #expect(!script.calls.dropFirst(before).contains { $0.first == "rmi" }, "not again the same day")
        let asAgent = await engine.cleanDocker(kinds: [.images], confirmed: true, initiator: .agent)
        #expect(asAgent.denial != nil && asAgent.report == nil)
    }
}
