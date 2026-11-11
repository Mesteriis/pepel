import Foundation
import Testing
@testable import PEPELCleanup
@testable import PEPELEngine
@testable import PEPELProjects
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
            if arguments.dropFirst().first == "inspect" { return (0, "vol-old\t2026-08-01T10:00:00Z\nvol-new\t2026-11-09T10:00:00Z\nvol-used\t2026-08-01T10:00:00Z\npgdata\t2026-01-01T10:00:00Z\n") }
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
          {"Name":"vol-used","Links":"1","Size":"9GB","Labels":"com.docker.compose.project=live"},
          {"Name":"pgdata","Links":"0","Size":"7GB","Labels":"com.docker.compose.project=gone"}],
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
        #expect(report.containers.count == 5 && report.images.count == 4 && report.volumes.count == 4 && report.buildCache.count == 4)
        #expect(report.containers.first { $0.id == "c-run" }?.finishedAt == nil && report.containers.first { $0.id == "c-old" }?.sizeBytes == 100_000_000)

        let plan = DockerCleanupPlan.make(report, days: 30, keep: [], activeProjects: [], now: Self.now)
        #expect(plan.containers.map(\.id) == ["c-old"], "not the recent one, the running one, the labelled one, or the one of a running stack")
        #expect(plan.images.map(\.id) == ["img-old"], "img-shared still has a container; img-fresh arrived two days ago; img-run is in use")
        #expect(plan.volumes.map(\.name) == ["vol-old"] && plan.bytes(.volumes) == 5_000_000_000, "the anonymous one; never the named one, however old and unmounted")
        #expect(plan.skipped.contains { $0.contains("named volume") })
        #expect(DockerCleanupPlan.make(report, days: 0, keep: [], activeProjects: [], now: Self.now).volumes.map(\.name) == ["vol-old"], "not even with no age limit")
        #expect(plan.buildCacheEntries == 1 && plan.buildCacheBytes == 4_000_000_000, "not the recent, the in-use, or the undated entry")
        #expect(plan.reproducibleBytes == 100_000_000 + 800_000_000 + 4_000_000_000, "volumes are not part of what can be rebuilt")
        #expect(plan.skipped.count == 5)

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

@Suite("Projects left untouched")
struct StaleProjectTests {
    @Test("A project's last activity is the newest of git's bookkeeping and its own files, never its generated directories")
    func activityProbe() {
        let f = Fixture()
        let root = f.gitRepo(f.projects + "/app")
        f.file(root + "/src/deep/main.py")
        f.file(root + "/node_modules/pkg/index.js")
        f.age(root, hours: 24 * 90)
        let old = ProjectActivityProbe.lastActivity(root: root, gitDirectory: root + "/.git")
        #expect(old.map { Date().timeIntervalSince($0) > 80 * 86_400 } == true)
        // A build writing into node_modules is not someone working on the project.
        f.file(root + "/node_modules/pkg/fresh.js")
        f.age(root, hours: 24 * 90)
        f.file(root + "/node_modules/pkg/newer.js")
        let afterBuild = ProjectActivityProbe.lastActivity(root: root, gitDirectory: root + "/.git", skip: [])
        #expect(afterBuild.map { Date().timeIntervalSince($0) > 80 * 86_400 } == true)
        // Editing a source file deep inside is.
        f.file(root + "/src/deep/main.py", text: "changed")
        let afterEdit = ProjectActivityProbe.lastActivity(root: root, gitDirectory: root + "/.git")
        #expect(afterEdit.map { Date().timeIntervalSince($0) < 3600 } == true)
        #expect(ProjectActivityProbe.lastActivity(root: f.root + "/missing", gitDirectory: nil) == nil)
    }

    @Test("Artifacts of an untouched project are removed on their own only with the rule on; an active project, its source and a project with an agent stay")
    func staleProjectRule() async throws {
        let f = Fixture()
        let store = try PepelStore.inMemory()
        func project(_ name: String, touchedDaysAgo: Double?) -> String {
            let root = f.gitRepo(f.projects + "/" + name)
            f.file(root + "/pyproject.toml", text: "[project]\nname='x'")
            f.file(root + "/src/main.py", text: "print(1)")
            f.file(root + "/.venv/pyvenv.cfg", text: "home = /usr/bin")
            f.file(root + "/.venv/lib/site.py", bytes: 4096)
            f.age(root, hours: 24 * 90)
            // The environment is equally old everywhere; only the project's own files differ.
            if let days = touchedDaysAgo {
                f.file(root + "/src/main.py", text: "print(2)")
                f.age(root + "/src", hours: 24 * days)
            }
            return root
        }
        let abandoned = project("abandoned", touchedDaysAgo: nil)
        let active = project("active", touchedDaysAgo: 2)
        let occupied = project("occupied", touchedDaysAgo: nil)
        var settings = PepelSettings()
        settings.projectRoots = [f.projects]
        try store.saveSettings(settings)
        let session = process(10, name: "claude", path: "/Users/x/.local/bin/claude", cwd: occupied)
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled, analyzers: [PythonAnalyzer()],
            processSource: FakeProcessSource(processes: [session]), telemetry: { SystemTelemetry(diskTotalBytes: 2000 * Bytes.gb, diskAvailableBytes: 900 * Bytes.gb) })

        var state = await engine.scan()
        func venv(_ root: String) -> StorageItem? { state.items.first { $0.path == root + "/.venv" } }
        #expect(venv(abandoned)?.isStale(days: 30) == true && venv(active)?.isStale(days: 30) == false && venv(occupied)?.isStale(days: 30) == false)
        #expect(venv(abandoned)?.safety == .review, "only marked while the rule is off")
        #expect(await engine.staleProjects().map(\.name) == ["abandoned"])
        #expect(await engine.staleProjects(days: 1).map(\.name).sorted() == ["abandoned", "active"], "a shorter age takes in the project touched two days ago")
        _ = await engine.automaticPass()
        #expect(PathUtil.exists(abandoned + "/.venv"))

        // An agent may not have it done.
        #expect(await engine.cleanStaleProjects(confirmed: true, initiator: .agent)?.succeededCount == 0)
        #expect(PathUtil.exists(abandoned + "/.venv"))

        _ = try await engine.update { $0.cleanStaleProjects = true }
        state = await engine.scan()
        #expect(venv(abandoned)?.safety == .safe && venv(active)?.safety == .review && venv(occupied)?.safety == .review)
        let result = await engine.automaticPass()
        #expect(result.cleanup?.succeededCount == 1)
        #expect(!PathUtil.exists(abandoned + "/.venv") && PathUtil.exists(abandoned + "/src/main.py") && PathUtil.exists(abandoned + "/.git") && PathUtil.exists(abandoned + "/pyproject.toml"))
        #expect(PathUtil.exists(active + "/.venv") && PathUtil.exists(occupied + "/.venv"))
        #expect(store.audit(kinds: [.cleanup]).first?.initiator == "automatic")
    }
}

@Suite("Tool caches")
struct CacheTrimTests {
    @Test("Only entries unused for long enough go; unpacked packages go whole; links and unknown caches are never touched")
    func trimByAge() throws {
        let f = Fixture()
        let go = f.home + "/Library/Caches/go-build"
        f.file(go + "/aa/old-1", bytes: 8192)
        f.file(go + "/aa/old-2", bytes: 8192)
        f.file(go + "/bb/fresh", bytes: 8192)
        f.age(go + "/aa", hours: 24 * 60)
        let uv = f.home + "/.cache/uv/archive-v0"
        f.file(uv + "/stale-pkg/a.py", bytes: 4096)
        f.file(uv + "/stale-pkg/b.py", bytes: 4096)
        f.age(uv + "/stale-pkg", hours: 24 * 60)
        f.file(uv + "/mixed-pkg/old.py", bytes: 4096)
        f.age(uv + "/mixed-pkg", hours: 24 * 60)
        f.file(uv + "/mixed-pkg/used.py", bytes: 4096)
        // A cache that is really a link somewhere else.
        let elsewhere = f.dir(f.root + "/elsewhere")
        f.file(elsewhere + "/precious", bytes: 4096)
        f.age(elsewhere, hours: 24 * 90)
        try FileManager.default.createDirectory(atPath: f.home + "/Library/Caches", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: f.home + "/Library/Caches/pip", withDestinationPath: elsewhere)

        let trimmer = CacheTrimmer(home: f.home)
        let measured = trimmer.measure(days: 30)
        #expect(Set(measured.map(\.id)) == ["go-build", "uv"], "the linked pip cache is not a cache PEPEL manages")
        let goCache = try #require(measured.first { $0.id == "go-build" })
        #expect(goCache.fileCount == 3 && goCache.staleCount == 2 && goCache.staleBytes > 0 && goCache.staleBytes < goCache.totalBytes)
        #expect(measured.first { $0.id == "uv" }?.staleCount == 1, "a package with one recently used file is in use as a whole")

        #expect(trimmer.trim("go-build", days: 30).removed == 2)
        #expect(!PathUtil.exists(go + "/aa") && PathUtil.exists(go + "/bb/fresh") && PathUtil.exists(go), "emptied folders go, the cache itself stays")
        #expect(trimmer.trim("uv", days: 30).removed == 1)
        #expect(!PathUtil.exists(uv + "/stale-pkg") && PathUtil.exists(uv + "/mixed-pkg/old.py") && PathUtil.exists(uv + "/mixed-pkg/used.py"))
        #expect(trimmer.trim("pip", days: 0).removed == 0 && PathUtil.exists(elsewhere + "/precious"))
        #expect(trimmer.trim("no-such-cache", days: 0).removed == 0)
        #expect(trimmer.trim("go-build", days: 30).removed == 0, "nothing left to remove")
    }

    @Test("A size limit removes the least recently used entries first and never what was used in the last day")
    func trimToSize() {
        let f = Fixture()
        let go = f.home + "/Library/Caches/go-build"
        for (name, days) in [("oldest", 20.0), ("older", 10), ("recent", 3), ("today", 0)] {
            f.file(go + "/\(name)", bytes: 1 << 20)
            if days > 0 { f.age(go + "/\(name)", hours: 24 * days) }
        }
        let trimmer = CacheTrimmer(home: f.home)
        #expect(trimmer.trim("go-build", days: 30).removed == 0, "nothing is 30 days old")
        // About 4 MiB in the cache, limit 2.5 MiB: the two least recently used go.
        #expect(trimmer.trim("go-build", days: 30, maxBytes: 5 << 19).removed == 2)
        #expect(!PathUtil.exists(go + "/oldest") && !PathUtil.exists(go + "/older") && PathUtil.exists(go + "/recent") && PathUtil.exists(go + "/today"))
        // A limit of nothing still leaves what was used today.
        #expect(trimmer.trim("go-build", days: 30, maxBytes: 0).removed == 1)
        #expect(PathUtil.exists(go + "/today"))
    }

    @Test("Trimming is a person's to ask for, or a daily rule; agents cannot")
    func trimPolicy() async throws {
        let f = Fixture()
        let go = f.home + "/Library/Caches/go-build"
        f.file(go + "/old", bytes: 8192)
        f.age(go, hours: 24 * 60)
        let store = try PepelStore.inMemory()
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled, analyzers: [],
            processSource: FakeProcessSource(processes: []), telemetry: { SystemTelemetry() })
        #expect(await engine.trimCaches(confirmed: true, initiator: .agent).denial != nil)
        #expect(await engine.trimCaches(confirmed: false, initiator: .user).denial != nil)
        _ = await engine.automaticPass()
        #expect(PathUtil.exists(go + "/old"), "off by default")
        _ = try await engine.update { $0.trimCaches = true }
        _ = await engine.automaticPass()
        #expect(!PathUtil.exists(go + "/old"))
        #expect(store.audit(kinds: [.cleanup]).contains { $0.subject.hasPrefix("Tool caches:") && $0.initiator == "automatic" })
    }
}

@Suite("Application data")
struct ApplicationDataTests {
    static let installed = InstalledApplications(bundleIDs: ["com.example.editor", "company.thebrowser.dia"], names: ["Editor", "Dia", "Notes"])

    @Test("A Library folder's owner is read from its name: running, installed, removed, or unknown")
    func ownership() {
        let apps = Self.installed
        #expect(apps.owner(of: "com.example.editor", running: []) == .installed)
        #expect(apps.owner(of: "com.example.editor.ShipIt", running: []) == .installed, "an updater uses the application's identifier as a prefix")
        #expect(apps.owner(of: "com.example.editor", running: ["com.example.editor"]) == .running)
        #expect(apps.owner(of: "company.thebrowser.dia", running: []) == .installed)
        #expect(apps.owner(of: "com.gone.app", running: []) == .removed && apps.owner(of: "com.gone.app.savedState", running: []) == .removed)
        #expect(apps.owner(of: "Dia", running: ["company.thebrowser.dia"]) == .running && apps.owner(of: "Notes", running: []) == .installed)
        #expect(apps.owner(of: "staticcheck", running: []) == .unknown && apps.owner(of: "some tool.v2", running: []) == .unknown)
    }

    @Test("Only caches of applications that are not running and unused long enough are removed; leftovers go to the Trash only when a person asks")
    func cachesAndLeftovers() async throws {
        let f = Fixture()
        let caches = f.home + "/Library/Caches"
        func cache(_ name: String, daysOld: Double) {
            f.file(caches + "/\(name)/data.bin", bytes: 30 << 20)
            if daysOld > 0 { f.age(caches + "/\(name)", hours: 24 * daysOld) }
        }
        cache("com.example.editor", daysOld: 60)        // installed, unused
        cache("company.thebrowser.dia", daysOld: 60)    // running
        cache("com.gone.app", daysOld: 60)              // removed
        cache("Notes", daysOld: 2)                      // installed, used recently
        cache("staticcheck", daysOld: 60)               // unknown
        cache("go-build", daysOld: 60)                  // managed by the tool cache rules
        cache("com.apple.Safari", daysOld: 60)          // the system's
        let support = f.home + "/Library/Application Support"
        f.file(support + "/com.gone.app/documents.db", bytes: 2 << 20)
        f.age(support + "/com.gone.app", hours: 24 * 200)
        f.file(support + "/com.fresh.gone/state", bytes: 2 << 20)
        f.file(support + "/com.example.editor/state", bytes: 2 << 20)
        f.age(support + "/com.example.editor", hours: 24 * 200)

        let store = try PepelStore.inMemory()
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled, analyzers: [],
            processSource: FakeProcessSource(processes: []), telemetry: { SystemTelemetry() })
        await engine.setInstalledApplications(Self.installed)
        let scanner = ApplicationDataScanner(home: f.home, installed: Self.installed, running: ["company.thebrowser.dia"])
        #expect(Set(scanner.caches().map(\.name)) == ["com.example.editor", "company.thebrowser.dia", "com.gone.app", "Notes", "staticcheck"])
        let removable = PepelEngine.removableCaches(scanner.caches(), days: 30, includeUnknown: false)
        #expect(Set(removable.map(\.name)) == ["com.example.editor", "com.gone.app"])
        #expect(Set(PepelEngine.removableCaches(scanner.caches(), days: 30, includeUnknown: true).map(\.name)) == ["com.example.editor", "com.gone.app", "staticcheck"])
        #expect(scanner.leftovers().map(\.name).sorted() == ["com.fresh.gone", "com.gone.app"], "never the folder of an installed application")
        var outside = scanner.caches()[0]
        outside.path = f.home + "/Documents"
        #expect(!scanner.isManageable(outside), "only a folder directly inside the Library folders is ever touched")

        #expect(await engine.cleanApplicationCaches(confirmed: true, initiator: .agent).denial != nil)
        _ = await engine.automaticPass()
        #expect(PathUtil.exists(caches + "/com.example.editor"), "off by default")
        _ = try await engine.update { $0.cleanAppCaches = true }
        _ = await engine.automaticPass()
        #expect(!PathUtil.exists(caches + "/com.example.editor") && !PathUtil.exists(caches + "/com.gone.app"))
        #expect(PathUtil.exists(caches + "/Notes") && PathUtil.exists(caches + "/staticcheck") && PathUtil.exists(caches + "/go-build") && PathUtil.exists(caches + "/com.apple.Safari"))
        #expect(PathUtil.exists(support + "/com.gone.app/documents.db"), "leftovers are never part of the automatic rule")

        #expect(await engine.trashApplicationLeftovers(confirmed: true, initiator: .automatic).denial != nil)
        #expect(await engine.trashApplicationLeftovers(confirmed: false, initiator: .user).denial != nil)
        #expect(await engine.applicationData().leftovers.map(\.name) == ["com.gone.app"], "only what has been untouched for 90 days is listed")
        #expect(PathUtil.exists(support + "/com.example.editor/state") && PathUtil.exists(support + "/com.fresh.gone/state"))
    }
}

@Suite("Keep markers and the owner's rules")
struct KeepMarkerTests {
    @Test("A folder marked as not to be cleaned is protected, with everything in it, from every rule")
    func markers() async throws {
        let f = Fixture()
        // By file: a cache with the marker in it.
        let go = f.home + "/Library/Caches/go-build"
        f.file(go + "/aa/old", bytes: 8192)
        f.file(go + "/DO_NOT_CLEAN.txt", text: "keep")
        f.age(go, hours: 24 * 60)
        // By attribute on a folder above.
        let uv = f.home + "/.cache/uv/archive-v0"
        f.file(uv + "/pkg/a.py", bytes: 4096)
        f.age(f.home + "/.cache", hours: 24 * 60)
        #expect(setxattr(f.home + "/.cache", "com.avm.do-not-clean", "owner", 5, 0, 0) == 0)
        // An entry marked inside a cache that is otherwise trimmed.
        let bun = f.home + "/.bun/install/cache"
        f.file(bun + "/kept-pkg/index.js", bytes: 4096)
        f.file(bun + "/kept-pkg/.pepel-keep")
        f.file(bun + "/other-pkg/index.js", bytes: 4096)
        f.age(bun, hours: 24 * 60)

        #expect(PathUtil.keepMarker(at: go + "/aa", stopAt: f.home) == go)
        #expect(PathUtil.keepMarker(at: uv + "/pkg", stopAt: f.home) == f.home + "/.cache")
        #expect(PathUtil.keepMarker(at: bun + "/other-pkg", stopAt: f.home) == nil)

        let trimmer = CacheTrimmer(home: f.home)
        #expect(trimmer.measure(days: 30).map(\.id) == ["bun"], "marked caches are not even listed")
        #expect(trimmer.trim("go-build", days: 0).removed == 0 && trimmer.trim("uv", days: 0).removed == 0)
        #expect(trimmer.trim("bun", days: 30).removed == 1)
        #expect(PathUtil.exists(go + "/aa/old") && PathUtil.exists(uv + "/pkg/a.py") && PathUtil.exists(bun + "/kept-pkg/index.js") && !PathUtil.exists(bun + "/other-pkg"))

        // The same in the general cleanup policy and for application caches.
        let marked = f.dir(f.home + "/work/build-output")
        f.file(marked + "/DO_NOT_CLEAN", text: "")
        let context = f.policyContext()
        #expect(CleanupPolicyEngine().pathViolation(marked, context: context)?.contains("marked as not to be cleaned") == true)
        f.file(f.home + "/Library/Caches/com.gone.app/data", bytes: 30 << 20)
        f.file(f.home + "/Library/Caches/com.gone.app/.pepel-keep")
        let scanner = ApplicationDataScanner(home: f.home, installed: InstalledApplications(bundleIDs: [], names: []), running: [])
        #expect(scanner.caches().first.map(scanner.isManageable) == false)
    }

    @Test("A cache is left alone while its tool runs; linked worktrees are outside the untouched-project rule; kept caches stay")
    func ownerRules() async throws {
        let f = Fixture()
        let go = f.home + "/Library/Caches/go-build"
        f.file(go + "/old", bytes: 8192)
        f.age(go, hours: 24 * 60)
        let trimmer = CacheTrimmer(home: f.home)
        #expect(trimmer.trim("go-build", days: 30, running: ["go", "zsh"]).removed == 0, "go is running")
        #expect(trimmer.trim("go-build", days: 30, running: ["zsh"]).removed == 1)

        let caches = [
            ApplicationData(name: "com.openai.atlas", path: "/x", kind: .cache, owner: .installed, bytes: 1, lastUse: .distantPast),
            ApplicationData(name: "com.other.app", path: "/y", kind: .cache, owner: .installed, bytes: 1, lastUse: .distantPast),
        ]
        #expect(PepelEngine.removableCaches(caches, days: 30, includeUnknown: true, keep: ["com.openai.atlas"]).map(\.name) == ["com.other.app"])
        #expect(PepelSettings().keepAppCaches == ["com.openai.atlas"])

        // A linked worktree with an old environment is not offered.
        let main = f.gitRepo(f.projects + "/app")
        let tree = f.worktree(of: main, at: f.projects + "/app-feature", branch: "feature")
        for root in [main, tree] {
            f.file(root + "/pyproject.toml", text: "[project]")
            f.file(root + "/.venv/pyvenv.cfg", text: "home = /usr/bin")
            f.file(root + "/.venv/lib/site.py", bytes: 4096)
            f.age(root, hours: 24 * 90)
        }
        var settings = PepelSettings()
        settings.projectRoots = [f.projects]
        let store = try PepelStore.inMemory()
        try store.saveSettings(settings)
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled, analyzers: [PythonAnalyzer()],
            processSource: FakeProcessSource(processes: []), telemetry: { SystemTelemetry() })
        _ = await engine.scan()
        #expect(await engine.staleProjects().map(\.id) == [main])
    }
}

@Suite("Other places, logs and the disk forecast")
struct OtherPlacesTests {
    @Test("Old large log files go; recent, small and agents' logs stay; a marked log folder is left alone")
    func oldLogs() {
        let f = Fixture()
        let logs = f.home + "/Library/Logs"
        f.file(logs + "/App/big-old.log", bytes: 2 << 20)
        f.file(logs + "/App/small-old.log", bytes: 4096)
        f.file(logs + "/Claude/session-old.log", bytes: 2 << 20)
        f.age(logs, hours: 24 * 30)
        f.file(logs + "/App/big-new.log", bytes: 2 << 20)
        let places = OtherPlaces(home: f.home)
        #expect(places.oldLogs(days: 7).files == [logs + "/App/big-old.log"])
        #expect(places.removeOldLogs(days: 7).removed == 1)
        #expect(!PathUtil.exists(logs + "/App/big-old.log") && PathUtil.exists(logs + "/App/small-old.log") && PathUtil.exists(logs + "/Claude/session-old.log") && PathUtil.exists(logs + "/App/big-new.log"))
        f.file(logs + "/App/another-old.log", bytes: 2 << 20)
        f.age(logs + "/App/another-old.log", hours: 24 * 30)
        f.file(logs + "/DO_NOT_CLEAN.txt")
        #expect(places.oldLogs(days: 7).files.isEmpty && places.removeOldLogs(days: 7).removed == 0)
    }

    @Test("Other places are sized and never removed; the disk forecast needs steady filling over days")
    func placesAndForecast() async throws {
        let f = Fixture()
        f.file(f.home + "/.android/avd/pixel.avd/userdata.img", bytes: 300 << 20)
        f.file(f.home + "/.android/avd/tiny.avd/userdata.img", bytes: 1 << 20)
        let found = OtherPlaces(home: f.home).measure()
        #expect(found.map(\.title) == ["Android emulators · pixel.avd"] && found.first?.kept == false)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let forecast = try #require(DiskForecast.project(grownBytes: 70 * Bytes.gb, over: 7 * 86_400, availableBytes: 200 * Bytes.gb, now: now))
        #expect(forecast.perDayBytes == 10 * Bytes.gb && abs(forecast.fullAt.timeIntervalSince(now) - 20 * 86_400) < 60)
        #expect(DiskForecast.project(grownBytes: 70 * Bytes.gb, over: 86_400, availableBytes: 200 * Bytes.gb) == nil, "one day is too little")
        #expect(DiskForecast.project(grownBytes: -5 * Bytes.gb, over: 7 * 86_400, availableBytes: 200 * Bytes.gb) == nil, "not filling")
        #expect(DiskForecast.project(grownBytes: Bytes.gb, over: 7 * 86_400, availableBytes: 900 * Bytes.gb) == nil, "years away")

        // Daily rules: once in twenty hours, hourly while the disk is low; off by default; not for agents.
        let store = try PepelStore.inMemory()
        f.file(f.home + "/Library/Logs/App/old.log", bytes: 2 << 20)
        f.age(f.home + "/Library/Logs", hours: 24 * 30)
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled, analyzers: [],
            processSource: FakeProcessSource(processes: []), telemetry: { SystemTelemetry(diskTotalBytes: 1000 * Bytes.gb, diskAvailableBytes: 10 * Bytes.gb) })
        #expect(await engine.removeOldLogs(confirmed: true, initiator: .agent).denial != nil)
        _ = await engine.automaticPass()
        #expect(PathUtil.exists(f.home + "/Library/Logs/App/old.log"))
        _ = try await engine.update { $0.cleanOldLogs = true }
        _ = await engine.automaticPass()
        #expect(!PathUtil.exists(f.home + "/Library/Logs/App/old.log"))
        await engine.refreshLive()
        #expect(await engine.dueDaily("test.rule", now: now) == true)
        #expect(await engine.dueDaily("test.rule", now: now.addingTimeInterval(1800)) == false)
        #expect(await engine.dueDaily("test.rule", now: now.addingTimeInterval(3700)) == true, "the disk is low, so hourly")
    }
}

@Suite("Disk map")
struct DiskMapTests {
    @Test("Tiles have areas in proportion to their sizes, fill the space, stay inside it and do not overlap")
    func squarifiedLayout() {
        let weights: [Double] = [600, 300, 200, 150, 100, 60, 40, 30, 15, 5]
        let rect = CGRect(x: 10, y: 20, width: 900, height: 500)
        let rects = Treemap.layout(weights, in: rect)
        let total = weights.reduce(0, +)
        for (weight, tile) in zip(weights, rects) {
            let expected = weight / total * Double(rect.width * rect.height)
            #expect(abs(Double(tile.width * tile.height) - expected) < 0.01 * expected + 0.5)
            #expect(tile.minX >= rect.minX - 0.01 && tile.minY >= rect.minY - 0.01 && tile.maxX <= rect.maxX + 0.01 && tile.maxY <= rect.maxY + 0.01)
        }
        #expect(abs(rects.reduce(0.0) { $0 + Double($1.width * $1.height) } - Double(rect.width * rect.height)) < 1)
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].intersection(rects[j])
                #expect(overlap.isNull || overlap.width * overlap.height < 0.01)
            }
        }
        // The point of squarifying: the large tiles are not slivers.
        #expect(rects.prefix(5).allSatisfy { max($0.width / $0.height, $0.height / $0.width) < 3 })
        #expect(Treemap.layout([], in: rect).isEmpty)
        #expect(Treemap.layout([5, 0, -1], in: rect)[1] == .zero && Treemap.layout([5, 0, -1], in: rect)[0].width == rect.width)
        #expect(Treemap.layout([1, 2], in: .zero) == [.zero, .zero])
    }

    @Test("A folder is measured two levels deep in one walk; links are not followed and guarded folders stay closed until opened")
    func scanning() throws {
        let f = Fixture()
        let root = f.dir(f.home + "/work")
        f.file(root + "/big.bin", bytes: 12 << 20)
        f.file(root + "/note.txt", bytes: 4096)
        f.file(root + "/app/src/main.c", bytes: 8192)
        f.file(root + "/app/build/out.o", bytes: 2 << 20)
        f.file(root + "/app/build/deep/more.o", bytes: 1 << 20)
        f.file(f.root + "/outside/secret.bin", bytes: 20 << 20)
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: f.root + "/outside")

        let levels = DiskMapScanner(home: f.home).scan(root, depth: 2)
        let top = try #require(levels.first { $0.path == root })
        #expect(top.nodes.map(\.name) == ["big.bin", "app", "2 smaller files"], "largest first; the link counts as a small file, not as what it points to")
        #expect(top.nodes[0].kind == .file && top.nodes[1].kind == .folder && top.nodes[2].kind == .smallFiles)
        #expect(top.nodes[1].bytes >= 3 << 20 && top.nodes[1].bytes < 4 << 20 && top.nodes[1].fileCount == 3)
        #expect(top.bytes < 20 << 20, "nothing from outside the folder")
        let app = try #require(levels.first { $0.path == root + "/app" })
        #expect(app.nodes.map(\.name) == ["build", "src"])
        #expect(levels.first { $0.path == root + "/app/build" } == nil, "the third level is measured when it is opened")
        let build = try #require(DiskMapScanner(home: f.home).scan(root + "/app/build").first { $0.path == root + "/app/build" })
        #expect(Set(build.nodes.map(\.name)) == ["deep", "1 smaller files"])

        // Guarded folders: closed from above, read when the walk starts on them.
        f.file(f.home + "/Documents/letter.doc", bytes: 1 << 20)
        f.file(f.home + "/code/a.txt", bytes: 4096)
        let home = try #require(DiskMapScanner(home: f.home).scan(f.home, depth: 1).first { $0.path == f.home })
        let documents = try #require(home.nodes.first { $0.name == "Documents" })
        #expect(documents.kind == .restricted && documents.bytes == 0 && documents.canOpen)
        #expect(home.bytes < 20 << 20)
        let opened = try #require(DiskMapScanner(home: f.home).scan(f.home + "/Documents").first)
        #expect(opened.nodes.first?.fileCount == 1 && opened.bytes >= 1 << 20)
        #expect(DiskMapScanner(home: f.home).scan(f.root + "/missing").isEmpty)

        // A folder that cannot be read does not derail the rest of the walk.
        f.file(root + "/locked/hidden.bin", bytes: 1 << 20)
        chmod(root + "/locked", 0)
        defer { chmod(root + "/locked", 0o755) }
        let withLocked = try #require(DiskMapScanner(home: f.home).scan(root).first { $0.path == root })
        #expect(withLocked.nodes.first { $0.name == "locked" }?.unreadable == 1)
        #expect(withLocked.nodes.first?.name == "big.bin" && withLocked.nodes.contains { $0.name == "app" })
        #expect(DiskMapScanner(home: f.home).scan(root, isCancelled: { true }).allSatisfy(\.complete) == true, "a walk too short to be interrupted finishes")
    }

    final class Updates: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [DiskLevel] = []
        func add(_ level: DiskLevel) { lock.lock(); seen.append(level); lock.unlock() }
        var all: [DiskLevel] { lock.lock(); defer { lock.unlock() }; return seen }
    }

    @Test("A folder is measured folder by folder: each one is reported as it finishes, and nothing outside it is walked")
    func folderByFolder() async throws {
        let f = Fixture()
        let root = f.dir(f.home + "/disk")
        f.file(root + "/alpha/a.bin", bytes: 3 << 20)
        f.file(root + "/alpha/sub/b.bin", bytes: 1 << 20)
        f.file(root + "/beta/c.bin", bytes: 2 << 20)
        f.file(root + "/gamma/d.txt", bytes: 4096)
        f.file(root + "/top.bin", bytes: 9 << 20)
        f.file(root + "/small.txt", bytes: 4096)
        f.file(f.root + "/elsewhere/huge.bin", bytes: 30 << 20)
        try FileManager.default.createSymbolicLink(atPath: root + "/shortcut", withDestinationPath: f.root + "/elsewhere")

        let updates = Updates()
        let levels = await DiskMapScanner(home: f.home).measure(root, concurrency: 2) { updates.add($0) }
        let top = try #require(levels.first { $0.path == root })
        #expect(top.complete && top.pending == 0)
        #expect(top.nodes.prefix(3).map(\.name) == ["top.bin", "alpha", "beta"] && Set(top.nodes.map(\.name)) == ["top.bin", "alpha", "beta", "gamma", "2 smaller files"], "the link is not followed: it counts as a small file")
        #expect(top.bytes < 20 << 20)
        #expect(top.nodes.first { $0.name == "alpha" }?.fileCount == 2)
        // What is directly inside each folder comes with it, and nothing deeper.
        #expect(Set(levels.map(\.path)) == [root, root + "/alpha", root + "/beta", root + "/gamma"])
        #expect(levels.first { $0.path == root + "/alpha" }?.nodes.map(\.name) == ["1 smaller files", "sub"] || levels.first { $0.path == root + "/alpha" }?.nodes.count == 2)
        // It filled in step by step: first the files at once with three folders pending, then one folder at a time.
        let seen = updates.all
        #expect(seen.first?.pending == 3 && seen.first?.nodes.contains { $0.kind == .folder } == false && seen.first?.complete == false)
        #expect(seen.map(\.pending).contains(2) && seen.map(\.pending).contains(1) && seen.last?.pending == 0 && seen.last?.complete == true)

        // Guarded folders: closed by default, read when asked.
        f.file(f.home + "/Documents/letter.doc", bytes: 1 << 20)
        let closed = try #require(await DiskMapScanner(home: f.home).measure(f.home).first { $0.path == f.home })
        #expect(closed.nodes.first { $0.name == "Documents" }?.kind == .restricted)
        let open = try #require(await DiskMapScanner(home: f.home).measure(f.home, includeGuarded: true).first { $0.path == f.home })
        #expect(open.nodes.first { $0.name == "Documents" }?.kind == .folder && (open.nodes.first { $0.name == "Documents" }?.bytes ?? 0) >= 1 << 20)
        #expect(await DiskMapScanner(home: f.home).measure(f.root + "/missing").isEmpty)
        #expect(DiskMapScanner.notFolders.contains("/Volumes") && DiskMapScanner.notFolders.contains("/dev"))
    }
}
