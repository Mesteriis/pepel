import Foundation
import Testing
@testable import PEPELEngine
@testable import PEPELStorage

@Suite("Projects, analyzers, accounting and scanning")
struct StorageTests {
    // MARK: Project discovery and attribution

    @Test("Repositories, linked worktrees outside the roots and nested manifests are discovered and grouped")
    func discoveryAndWorktrees() {
        let f = Fixture()
        let main = f.gitRepo(f.projects + "/Makosh", branch: "main", remote: "https://me:ghp_secret@github.com/me/makosh.git")
        f.file(main + "/Package.swift")
        f.file(main + "/tools/web/package.json")  // monorepo package: same project
        let feature = f.worktree(of: main, at: f.home + "/worktrees/makosh-feature", branch: "feature/x")
        f.file(feature + "/Package.swift")
        f.file(f.projects + "/scratch/pyproject.toml")  // manifest without git

        let projects = ProjectDiscovery(home: f.home).discover(roots: [f.projects])
        let byID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let mainProject = byID[main], worktree = byID[feature], scratch = byID[f.projects + "/scratch"]

        #expect(projects.count == 3)
        #expect(mainProject?.kinds.isSuperset(of: [.git, .swiftpm, .node]) == true)
        #expect(mainProject?.git?.branch == "main" && mainProject?.confidence == .verified)
        #expect(mainProject?.git?.remoteURL == "https://github.com/me/makosh.git", "credentials must be stripped from remotes")
        #expect(worktree?.git?.isLinkedWorktree == true && worktree?.git?.branch == "feature/x")
        #expect(worktree?.groupID == mainProject?.groupID && worktree?.groupName == "Makosh")
        #expect(scratch?.confidence == .probable && scratch?.git == nil)
    }

    @Test("Attribution uses the longest matching root, resolves symlinked aliases, and reports nothing for unrelated paths")
    func attribution() {
        let f = Fixture()
        let outer = f.gitRepo(f.projects + "/mono")
        let inner = f.gitRepo(f.projects + "/mono/vendor-tool")
        f.dir(inner + "/src")
        symlink(outer, f.home + "/alias-to-mono")
        let index = ProjectIndex(ProjectDiscovery(home: f.home).discover(roots: [f.projects], registered: [inner]))

        #expect(index.attribute(path: inner + "/src/main.rs")?.projectID == inner)
        #expect(index.attribute(path: outer + "/README.md")?.projectID == outer)
        #expect(index.attribute(path: f.home + "/alias-to-mono/README.md")?.projectID == outer)
        #expect(index.attribute(path: f.projects + "/monolith/x") == nil, "a name prefix is not containment")
        #expect(index.attribute(path: f.home + "/Documents/notes.txt") == nil)
    }

    @Test("Discovery never follows symlinked directories and honours exclusions")
    func discoveryIgnoresSymlinksAndExclusions() {
        let f = Fixture()
        let outside = f.gitRepo(f.root + "/outside/secret-repo")
        symlink((outside as NSString).deletingLastPathComponent, f.projects + "/link")
        let excluded = f.gitRepo(f.projects + "/archive/old")
        let kept = f.gitRepo(f.projects + "/app")
        let projects = ProjectDiscovery(home: f.home).discover(roots: [f.projects], excluded: [f.projects + "/archive"])
        #expect(projects.map(\.id) == [kept])
        _ = excluded
    }

    // MARK: Filesystem accounting

    @Test("Hard-linked files are counted once and sparse files by allocated blocks, not length")
    func accounting() {
        let f = Fixture()
        let base = f.dir(f.root + "/acct")
        f.file(base + "/a.bin", bytes: 1_000_000)
        link(base + "/a.bin", base + "/a-link.bin")
        let sparse = base + "/sparse.img"
        FileManager.default.createFile(atPath: sparse, contents: nil)
        let handle = FileHandle(forWritingAtPath: sparse)!
        try! handle.truncate(atOffset: 200_000_000)
        try! handle.close()

        let info = DirectorySizer().measure(base)
        #expect(info.fileCount == 3)
        #expect(info.logicalBytes >= 202_000_000, "logical size counts both links and the sparse length")
        #expect(info.allocatedBytes < 3_000_000, "allocated: one copy of the linked file, almost nothing for the hole")
        #expect(info.allocatedBytes >= 1_000_000)
        #expect(info.hardLinkedBytes >= 2_000_000 && info.isApproximate)
    }

    @Test("Data shared between items through hard links is not double-counted across a scan")
    func sharedAcrossItems() {
        let f = Fixture()
        let store = f.dir(f.root + "/store"), project = f.dir(f.root + "/project/node_modules")
        f.file(store + "/pkg.tgz", bytes: 2_000_000)
        link(store + "/pkg.tgz", project + "/pkg.tgz")
        let ledger = HardLinkLedger()
        let first = DirectorySizer().measure(store, ledger: ledger)
        let second = DirectorySizer().measure(project, ledger: ledger)
        #expect(first.allocatedBytes >= 2_000_000)
        #expect(second.allocatedBytes < 100_000, "the second item must not claim the shared blocks again")
        #expect(second.hardLinkedBytes >= 2_000_000)
    }

    @Test("Measuring never follows a symlink out of the tree")
    func sizerDoesNotFollowSymlinks() {
        let f = Fixture()
        let big = f.dir(f.root + "/elsewhere")
        f.file(big + "/huge.bin", bytes: 5_000_000)
        let tree = f.dir(f.root + "/tree")
        f.file(tree + "/small.bin", bytes: 1_000)
        symlink(big, tree + "/escape")
        let info = DirectorySizer().measure(tree)
        #expect(info.logicalBytes < 100_000)
        #expect(DirectorySizer().measure(tree + "/escape").logicalBytes == 0, "a symlink root is measured as a link, not as its target")
    }

    @Test("Unreadable directories are reported, not fatal, and make the figure approximate")
    func permissionFailures() {
        let f = Fixture()
        let tree = f.dir(f.root + "/restricted")
        f.file(tree + "/open/visible.bin", bytes: 10_000)
        f.file(tree + "/locked/hidden.bin", bytes: 10_000)
        chmod(tree + "/locked", 0o000)
        defer { chmod(tree + "/locked", 0o755) }
        let info = DirectorySizer().measure(tree)
        #expect(info.inaccessibleCount >= 1)
        #expect(info.logicalBytes >= 10_000 && info.logicalBytes < 20_000)
        #expect(info.isApproximate && info.complete)
        #expect(DirectorySizer().measure(f.root + "/does-not-exist").inaccessibleCount == 1)
    }

    @Test("Measurement stops promptly when cancelled and says the result is incomplete")
    func sizerCancellation() {
        let f = Fixture()
        let tree = f.dir(f.root + "/many")
        for index in 0..<9000 { FileManager.default.createFile(atPath: tree + "/f\(index)", contents: nil) }
        let cancelled = DirectorySizer().measure(tree) { true }
        #expect(!cancelled.complete && cancelled.fileCount < 9000 && cancelled.isApproximate)
        #expect(DirectorySizer().measure(tree) { false }.fileCount == 9000)
    }

    // MARK: Analyzers

    @Test("Xcode DerivedData folders are attributed through their recorded workspace; orphaned ones are safe")
    func derivedData() async {
        let f = Fixture()
        let project = f.gitRepo(f.projects + "/Makosh")
        f.dir(project + "/Makosh.xcodeproj")
        let derived = f.home + "/Library/Developer/Xcode/DerivedData"
        func make(_ name: String, workspace: String) {
            f.file(derived + "/\(name)/Build/Products/Debug-iphonesimulator/App.bin", bytes: 50_000)
            (["WorkspacePath": workspace] as NSDictionary).write(toFile: derived + "/\(name)/info.plist", atomically: true)
        }
        make("Makosh-aaaabbbbccccdddd", workspace: project + "/Makosh.xcodeproj")
        make("Gone-eeeeffffgggghhhh", workspace: f.projects + "/Deleted/Deleted.xcodeproj")
        f.file(derived + "/ModuleCache.noindex/x.pcm", bytes: 10_000)

        let output = await XcodeDerivedDataAnalyzer().discover(await f.scanContext())
        let live = output.items.first { $0.path.hasSuffix("Makosh-aaaabbbbccccdddd") }
        let gone = output.items.first { $0.path.hasSuffix("Gone-eeeeffffgggghhhh") }
        #expect(output.items.count == 3)
        #expect(live?.projectID == project && live?.projectConfidence == .verified && live?.safety == .review)
        #expect(live?.build?.system == .xcode && live?.build?.configuration == "Debug-iphonesimulator" && live?.build?.branch == "main")
        #expect(gone?.safety == .safe && gone?.build?.sourceMissing == true && gone?.projectID == nil)
        #expect(output.items.first { $0.path.hasSuffix("ModuleCache.noindex") }?.category == .toolCache)
        #expect(XcodeDerivedDataAnalyzer().validate(live!) == nil)
        var elsewhere = live!
        elsewhere.path = project
        #expect(XcodeDerivedDataAnalyzer().validate(elsewhere) != nil)
    }

    @Test("SwiftPM build directories split into generations per configuration, with dependency checkouts separate")
    func swiftPM() async {
        let f = Fixture()
        let project = f.gitRepo(f.projects + "/Tool", branch: "dev")
        f.file(project + "/Package.swift")
        f.file(project + "/.build/arm64-apple-macosx/debug/Tool", bytes: 20_000)
        f.file(project + "/.build/arm64-apple-macosx/release/Tool", bytes: 20_000)
        f.file(project + "/.build/checkouts/dep/Package.swift")
        symlink(project + "/.build/arm64-apple-macosx/debug", project + "/.build/debug")  // SwiftPM's convenience link
        f.file(f.projects + "/NotSwift/.build/arm64-apple-macosx/debug/x")  // no Package.swift: ignored

        let items = await SwiftPMAnalyzer().discover(await f.scanContext()).items
        let builds = items.filter { $0.category == .buildOutput }
        #expect(builds.count == 2)
        #expect(Set(builds.compactMap { $0.build?.configuration }) == ["debug (arm64-apple-macosx)", "release (arm64-apple-macosx)"])
        #expect(builds.allSatisfy { $0.projectID == project && $0.build?.branch == "dev" && $0.safety == .review })
        #expect(items.contains { $0.category == .dependencyCache && $0.path.hasSuffix("/.build/checkouts") })
        #expect(!items.contains { $0.path.contains("NotSwift") })
    }

    @Test("Python caches are safe; virtual environments are never safe and never judged by age")
    func python() async {
        let f = Fixture()
        let project = f.gitRepo(f.projects + "/svc")
        f.file(project + "/pyproject.toml")
        f.file(project + "/.pytest_cache/v/cache/lastfailed")
        f.file(project + "/.ruff_cache/0.4/x")
        f.file(project + "/.venv/pyvenv.cfg")
        f.file(project + "/venv/not-a-venv.txt")  // named like one but without pyvenv.cfg
        f.age(project + "/.venv", hours: 24 * 400)
        let items = await PythonAnalyzer().discover(await f.scanContext()).items
        #expect(items.first { $0.path.hasSuffix(".pytest_cache") }?.safety == .safe)
        #expect(items.first { $0.path.hasSuffix(".ruff_cache") }?.safety == .safe)
        let venv = items.first { $0.path.hasSuffix("/.venv") }
        #expect(venv?.safety == .review && venv?.category == .virtualEnvironment)
        #expect(!items.contains { $0.path.hasSuffix("/venv") })
    }

    @Test("Ambiguous output names are only reported when git confirms they are not source; Cargo targets need Cargo's markers")
    func ambiguousNames() async {
        let f = Fixture()
        let web = f.gitRepo(f.projects + "/web")
        f.file(web + "/package.json")
        f.file(web + "/dist/index.js")
        f.file(web + "/node_modules/left-pad/index.js")
        let crate = f.gitRepo(f.projects + "/crate")
        f.file(crate + "/Cargo.toml")
        f.file(crate + "/target/CACHEDIR.TAG")
        f.file(crate + "/target/debug/app")
        let fake = f.gitRepo(f.projects + "/docs")
        f.file(fake + "/Cargo.toml")
        f.file(fake + "/target/audience.md")  // a real source directory that happens to be called target

        var context = await f.scanContext()
        #expect(context.hits.allSatisfy { $0.gitIgnored == nil })  // git not consulted in this fixture
        var node = await NodeAnalyzer().discover(context).items
        #expect(node.contains { $0.path.hasSuffix("/node_modules") })
        #expect(!node.contains { $0.path.hasSuffix("/dist") }, "dist without git confirmation must be left alone")

        context.hits = context.hits.map { hit in
            var h = hit
            h.gitIgnored = true
            return h
        }
        node = await NodeAnalyzer().discover(context).items
        #expect(node.contains { $0.path.hasSuffix("/dist") })

        let rust = await RustAnalyzer().discover(context).items
        #expect(rust.map(\.path) == [crate + "/target/debug"])
    }

    @Test("Agent state and model weights are reported as protected and the policy refuses them independently")
    func aiTools() async {
        let f = Fixture()
        f.file(f.home + "/.claude/projects/session.jsonl")
        f.file(f.home + "/.codex/sessions/x.json")
        f.file(f.home + "/.ollama/models/blobs/sha256-abc", bytes: 100_000)
        f.file(f.home + "/.cache/huggingface/hub/model/weights.safetensors", bytes: 100_000)
        // Agent scratch space older than three days is offered for review, never as safe.
        f.file(f.root + "/shared-tmp/claude-\(getuid())/old-session/notes.txt")
        f.age(f.root + "/shared-tmp", hours: 24 * 5)
        f.file(f.root + "/shared-tmp/claude-\(getuid())/live-session/notes.txt")
        let all = await AIToolsAnalyzer().discover(await f.scanContext()).items
        let scratch = all.filter { $0.category == .temporary }
        #expect(scratch.map(\.title) == ["Agent scratch old-session"] && scratch.allSatisfy { $0.safety == .review })
        let items = all.filter { $0.category != .temporary }
        #expect(items.count == 4)
        #expect(items.allSatisfy { $0.safety == .protected && $0.method == .none })
        // Defence in depth: even if an analyzer mislabelled them, the policy engine says no.
        for item in items {
            var mislabelled = item
            mislabelled.safety = .safe
            mislabelled.method = .filesystem
            #expect(CleanupPolicyEngine().evaluate(mislabelled, initiator: .user, context: f.policyContext()).verdict == .denied)
        }
    }

    @Test("Docker sizes are parsed; volumes can never be cleaned")
    func dockerParsing() {
        #expect(DockerAnalyzer.parseSize("1.5GB") == 1_500_000_000)
        #expect(DockerAnalyzer.parseSize("512MB") == 512_000_000)
        #expect(DockerAnalyzer.parseSize("3.4kB") == 3_400)
        #expect(DockerAnalyzer.parseSize("0B") == 0)
        #expect(DockerAnalyzer.parseSize("garbage") == nil)
        #expect(!ToolCleanup.allCases.contains { $0.commandDescription.contains("volume") })
    }

    // MARK: Overlaps and duplicates

    @Test("Duplicate and nested results collapse into one item that inherits the strictest classification")
    func overlapResolution() {
        func item(_ path: String, _ safety: SafetyClass, _ title: String) -> StorageItem {
            StorageItem(analyzerID: "t", category: .toolCache, path: path, title: title, explanation: "", safety: safety, safetyReason: "r", reproducible: true)
        }
        let resolved = ScanCoordinator.resolveOverlaps([
            item("/h/.cache", .review, "cache"), item("/h/.cache/huggingface", .protected, "models"), item("/h/.cache/uv", .safe, "uv"),
            item("/h/proj/.build", .review, "build"), item("/h/proj/.build", .safe, "build duplicate"),
            item("/h/proj/.build-tools", .safe, "sibling"), item("tool://docker/build-cache", .review, "docker"),
            item("tool://docker/build-cache", .review, "docker again"),
        ])
        #expect(Set(resolved.map(\.path)) == ["/h/.cache", "/h/proj/.build", "/h/proj/.build-tools", "tool://docker/build-cache"])
        let cache = resolved.first { $0.path == "/h/.cache" }
        #expect(cache?.safety == .protected && cache?.method == CleanupMethod.none, "an outer item containing protected data becomes protected")
        #expect(resolved.first { $0.path == "/h/proj/.build" }?.safety == .review)
    }

    // MARK: Scan coordination

    @Test("A scan measures items; a later scan with no changes reuses measurements and re-measures only what changed")
    func incrementalScan() async {
        let f = Fixture()
        let project = f.gitRepo(f.projects + "/svc")
        f.file(project + "/pyproject.toml")
        f.file(project + "/.pytest_cache/a", bytes: 4_000)
        f.file(project + "/.ruff_cache/b", bytes: 4_000)
        let coordinator = ScanCoordinator(analyzers: [PythonAnalyzer()])

        let first = await coordinator.scan(context: await f.scanContext())
        #expect(first.items.count == 2 && first.reusedMeasurements == 0)
        #expect(first.items.allSatisfy { ($0.size?.allocatedBytes ?? 0) > 0 && $0.identity != nil })

        let unchanged = await coordinator.scan(context: await f.scanContext(), changes: ChangeSet())
        #expect(unchanged.reusedMeasurements == 2)

        f.file(project + "/.pytest_cache/deep/new", bytes: 50_000)
        let changed = await coordinator.scan(context: await f.scanContext(), changes: ChangeSet(paths: [project + "/.pytest_cache/deep"]))
        #expect(changed.reusedMeasurements == 1)
        #expect(changed.items.first { $0.path.hasSuffix(".pytest_cache") }?.size?.logicalBytes == 54_000)

        let everything = await coordinator.scan(context: await f.scanContext(), changes: ChangeSet(everything: true))
        #expect(everything.reusedMeasurements == 0)
    }

    @Test("A cancelled scan reports that it was cancelled")
    func scanCancellation() async {
        let f = Fixture()
        let project = f.gitRepo(f.projects + "/svc")
        f.file(project + "/pyproject.toml")
        for index in 0..<40 { f.file(project + "/pkg\(index)/.pytest_cache/x", bytes: 1_000) }
        let coordinator = ScanCoordinator(analyzers: [PythonAnalyzer()], maxConcurrentMeasurements: 2)
        let context = await f.scanContext()
        let task = Task { await coordinator.scan(context: context) }
        task.cancel()
        let result = await task.value
        #expect(result.cancelled)
        #expect(result.items.contains { $0.size == nil }, "unmeasured items are left unmeasured, not guessed")
    }

    @Test("Excluded paths never produce items")
    func exclusions() async {
        let f = Fixture()
        let project = f.gitRepo(f.projects + "/svc")
        f.file(project + "/pyproject.toml")
        f.file(project + "/.pytest_cache/a")
        var settings = PepelSettings()
        settings.excludedPaths = [project]
        let result = await ScanCoordinator(analyzers: [PythonAnalyzer()]).scan(context: await f.scanContext(settings: settings))
        #expect(result.items.isEmpty)
    }
}
