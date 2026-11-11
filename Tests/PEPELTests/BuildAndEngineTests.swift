import Foundation
import Testing
@testable import PEPELAgents
@testable import PEPELEngine

@Suite("Build retention")
struct RetentionTests {
    let now = Date()

    private func generation(_ id: String, hoursAgo: Double, status: BuildStatus = .unknown, gb: Int64 = 10, active: Bool = false, pinned: Bool = false, sourceMissing: Bool = false) -> GenerationInput {
        GenerationInput(
            id: id, timestamp: now.addingTimeInterval(-hoursAgo * 3600), status: status, sizeBytes: gb * Bytes.gb, isActive: active,
            isPinned: pinned, sourceMissing: sourceMissing)
    }

    @Test("Keeps the newest builds, the last known good and the last failed report; proposes the rest once old enough")
    func counts() {
        var policy = RetentionPolicy()
        policy.budgetBytes = nil
        let verdicts = RetentionEngine.evaluate(
            [
                generation("newest", hoursAgo: 60, status: .failed), generation("good-1", hoursAgo: 70, status: .succeeded),
                generation("good-2", hoursAgo: 80, status: .succeeded), generation("good-3", hoursAgo: 90, status: .succeeded),
                generation("failed-old", hoursAgo: 100, status: .failed), generation("unknown-old", hoursAgo: 110),
            ], policy: policy, now: now)
        #expect(verdicts["newest"] == .keep(reason: "Most recent build."))
        #expect(verdicts["good-1"] == .keep(reason: "Last known good build."))
        #expect(verdicts["good-2"]?.isCandidate == false)  // second of the last two builds
        #expect(verdicts["good-3"]?.isCandidate == true)
        #expect(verdicts["failed-old"]?.isCandidate == true, "only the most recent failed report is kept")
        #expect(verdicts["unknown-old"]?.isCandidate == true)
    }

    @Test("Active and pinned generations are always kept, whatever their age or the budget")
    func activeAndPinned() {
        var policy = RetentionPolicy()
        policy.budgetBytes = 1 * Bytes.gb
        policy.maxAgeDays = 1
        let verdicts = RetentionEngine.evaluate(
            [
                generation("new", hoursAgo: 1), generation("active-old", hoursAgo: 900, active: true),
                generation("pinned-old", hoursAgo: 900, pinned: true), generation("old", hoursAgo: 900),
            ], policy: policy, now: now)
        #expect(verdicts["active-old"] == .keep(reason: "Build is active."))
        #expect(verdicts["pinned-old"] == .keep(reason: "Pinned by you."))
        #expect(verdicts["new"]?.isCandidate == false)
        #expect(verdicts["old"]?.isCandidate == true)
    }

    @Test("Nothing younger than the review threshold is proposed")
    func youngBuildsAreKept() {
        let verdicts = RetentionEngine.evaluate((0..<8).map { generation("g\($0)", hoursAgo: Double($0) + 1) }, policy: RetentionPolicy(), now: now)
        #expect(verdicts.values.allSatisfy { !$0.isCandidate })
    }

    @Test("A project over budget gets its oldest unprotected generations proposed until it fits")
    func budget() {
        var policy = RetentionPolicy()
        policy.keepSuccessful = 5
        policy.budgetBytes = 25 * Bytes.gb
        let verdicts = RetentionEngine.evaluate((0..<5).map { generation("g\($0)", hoursAgo: 50 + Double($0) * 10) }, policy: policy, now: now)
        // 5 × 10 GB kept by count; the budget of 25 GB forces the three oldest out.
        #expect(verdicts["g0"]?.isCandidate == false && verdicts["g1"]?.isCandidate == false)
        #expect(["g2", "g3", "g4"].allSatisfy { verdicts[$0]?.reason.contains("budget") == true })
    }

    @Test("Builds whose source is gone are candidates even when recent; age limits apply when configured")
    func sourceMissingAndMaxAge() {
        var policy = RetentionPolicy()
        policy.keepSuccessful = 10
        policy.maxAgeDays = 7
        policy.budgetBytes = nil
        let verdicts = RetentionEngine.evaluate(
            [generation("new", hoursAgo: 2), generation("orphan", hoursAgo: 3, sourceMissing: true), generation("ancient", hoursAgo: 24 * 30)],
            policy: policy, now: now)
        #expect(verdicts["orphan"]?.isCandidate == true)
        #expect(verdicts["ancient"] == .candidate(reason: "Older than 7 days."))
        #expect(verdicts["new"]?.isCandidate == false)
    }

    @Test("Hundreds of gigabytes of synthetic build metadata produce the expected narrative and verdicts")
    func makoshNarrative() {
        let project = "/Users/dev/projects/Makosh"
        let index = ProjectIndex([Project(id: project, name: "Makosh", kinds: [.git, .xcode])])
        // 11 generations, 142 GB in total; no bytes are written to disk.
        let ages: [Double] = [1, 5, 60, 70, 80, 90, 100, 110, 120, 130, 140]
        let items = ages.enumerated().map { index, hours -> StorageItem in
            let bytes = (index == 10 ? 12 : 13) * Bytes.gb
            return StorageItem(
                analyzerID: "xcode.derived-data", category: .buildOutput, path: "/Users/dev/Library/Developer/Xcode/DerivedData/Makosh-\(index)",
                title: "Makosh", explanation: "", safety: .review, safetyReason: "", reproducible: true, projectID: project,
                projectConfidence: .verified,
                size: SizeInfo(logicalBytes: bytes, allocatedBytes: bytes, fileCount: 100_000, newestModification: now.addingTimeInterval(-hours * 3600)),
                build: BuildMetadata(system: .xcode, configuration: "Debug"))
        }
        let report = BuildGuardian.report(
            items: items, projects: index, groupName: { _ in "Makosh" }, pinned: [items[4].path],
            activity: [items[2].id: "xcodebuild (PID 1) is running in this project.", items[3].id: "Referenced by running swift-frontend (PID 2)."],
            settings: PepelSettings(), now: now)

        let summary = report.summaries[0]
        #expect(summary.generations.count == 11 && summary.totalBytes == 142 * Bytes.gb)
        #expect(summary.protectedCount == 3 && summary.activeCount == 2 && summary.candidateCount == 6)
        #expect(summary.narrative == "Makosh has 11 detected build generations consuming 142 GB. Three are protected, two appear active, and six are candidates for cleanup. This is over the 40.0 GB budget.")
        #expect(summary.overBudget && report.totalBytes == 142 * Bytes.gb && !report.overGlobalBudget)

        // Candidates stay "review" unless the user opted into treating them as safe.
        let candidateIDs = Set(summary.generations.filter { $0.verdict.isCandidate && !$0.isActive }.map(\.id))
        #expect(report.items.filter { candidateIDs.contains($0.id) }.allSatisfy { $0.safety == .review })
        var optedIn = PepelSettings()
        optedIn.retentionCandidatesAreSafe = true
        let strict = BuildGuardian.report(items: items, projects: index, groupName: { _ in "Makosh" }, pinned: [items[4].path], settings: optedIn, now: now)
        #expect(strict.items.filter { $0.safety == .safe }.count == strict.summaries[0].candidateCount)
    }

    @Test("Worktrees of one repository form one group; a wrapped build's outcome becomes the generation's status")
    func worktreesAndWrapperStatus() {
        let main = "/p/Makosh", feature = "/w/makosh-feature"
        let index = ProjectIndex([
            Project(id: main, name: "Makosh", kinds: [.git], git: GitInfo(commonDirectory: "/p/Makosh/.git", branch: "main"), groupID: "/p/Makosh/.git", groupName: "Makosh"),
            Project(id: feature, name: "makosh-feature", kinds: [.git], git: GitInfo(commonDirectory: "/p/Makosh/.git", branch: "feature", isLinkedWorktree: true), groupID: "/p/Makosh/.git", groupName: "Makosh"),
        ])
        func item(_ project: String, hours: Double) -> StorageItem {
            StorageItem(
                analyzerID: "swiftpm", category: .buildOutput, path: project + "/.build/arm64/debug", title: "debug", explanation: "",
                safety: .review, safetyReason: "", reproducible: true, projectID: project, projectConfidence: .verified,
                size: SizeInfo(allocatedBytes: Bytes.gb, newestModification: now.addingTimeInterval(-hours * 3600)), build: BuildMetadata(system: .swiftpm))
        }
        let failed = BuildRecord(
            projectID: feature, workingDirectory: feature, command: "swift build", startedAt: now.addingTimeInterval(-3 * 3600 - 120),
            finishedAt: now.addingTimeInterval(-3 * 3600 + 30), exitCode: 1)
        let running = BuildRecord(projectID: main, workingDirectory: main, command: "swift build", wrapperPID: 4242)
        let report = BuildGuardian.report(
            items: [item(main, hours: 1), item(feature, hours: 3)], projects: index, groupName: { _ in "Makosh" }, records: [failed, running],
            settings: PepelSettings(), now: now, isAlive: { $0 == 4242 })
        #expect(report.summaries.count == 1 && report.summaries[0].generations.count == 2)
        let byPath = Dictionary(uniqueKeysWithValues: report.summaries[0].generations.map { ($0.path, $0) })
        #expect(byPath[feature + "/.build/arm64/debug"]?.status == .failed)
        #expect(byPath[main + "/.build/arm64/debug"]?.status == .running && byPath[main + "/.build/arm64/debug"]?.isActive == true)
    }

    @Test("Monitoring adapts: slower on battery and when idle, faster under pressure, deferred during builds, off when paused")
    func cadence() {
        var c = MonitorConditions()
        c.sinceLastFullScan = 10
        #expect(CadencePolicy.cadence(for: c).lightInterval == 10)
        c.onBattery = true
        #expect(CadencePolicy.cadence(for: c).lightInterval == 30)
        c.pressure = .critical
        #expect(CadencePolicy.cadence(for: c).lightInterval == 4)
        c = MonitorConditions()
        c.userIdleSeconds = 3600
        c.sinceLastFullScan = 10
        #expect(CadencePolicy.cadence(for: c).lightInterval == 45)

        c = MonitorConditions()
        #expect(CadencePolicy.cadence(for: c).runFullScan, "first scan runs")
        c.sinceLastFullScan = CadencePolicy.fullScanInterval + 1
        #expect(CadencePolicy.cadence(for: c).runFullScan)
        c.activeBuilds = 2
        #expect(!CadencePolicy.cadence(for: c).runFullScan, "scans wait for builds")
        c.sinceLastFullScan = CadencePolicy.maxDeferral + 1
        #expect(CadencePolicy.cadence(for: c).runFullScan, "but not forever")
        c.activeBuilds = 0
        c.sinceLastFullScan = CadencePolicy.fullScanInterval + 1
        c.changesPending = false
        #expect(!CadencePolicy.cadence(for: c).runFullScan, "nothing changed, nothing to rescan")
        c.changesPending = true
        c.mode = .manual
        #expect(!CadencePolicy.cadence(for: c).runFullScan)
        c.mode = .notifyOnly
        c.paused = true
        #expect(!CadencePolicy.cadence(for: c).runFullScan)
    }
}

@Suite("Persistence, agent API and engine")
struct EngineTests {
    @Test("Settings survive unknown and missing keys; quiet hours wrap past midnight")
    func settings() throws {
        let store = try PepelStore.inMemory()
        var settings = PepelSettings()
        settings.projectRoots = ["~/code"]
        settings.defaultRetention.keepSuccessful = 7
        try store.saveSettings(settings)
        #expect(store.loadSettings() == settings)

        let partial = Data(#"{"projectRoots":["~/x"],"futureKey":123,"defaultRetention":{"keepSuccessful":4}}"#.utf8)
        let decoded = PepelSettings.decodeLenient(partial)
        #expect(decoded.projectRoots == ["~/x"] && decoded.defaultRetention.keepSuccessful == 4)
        #expect(decoded.defaultRetention.keepFailed == 1 && decoded.monitoringMode == .notifyOnly)

        var quiet = QuietHours()
        quiet.enabled = true
        #expect(quiet.contains(hour: 23) && quiet.contains(hour: 3) && !quiet.contains(hour: 12))
    }

    @Test("Growth is computed from recorded snapshots and admits when history is shorter than the window")
    func growth() throws {
        let store = try PepelStore.inMemory()
        let now = Date()
        func record(minutesAgo: Double, usedGB: Int64) {
            store.recordTelemetry(
                SystemTelemetry(timestamp: now.addingTimeInterval(-minutesAgo * 60), diskTotalBytes: 2000 * Bytes.gb, diskAvailableBytes: (2000 - usedGB) * Bytes.gb), reclaimable: nil)
        }
        #expect(store.diskGrowth(window: 3600, now: now) == nil)
        record(minutesAgo: 180, usedGB: 1000)
        record(minutesAgo: 60, usedGB: 1010)
        record(minutesAgo: 10, usedGB: 1012)
        record(minutesAgo: 5, usedGB: 1030)
        let hour = try #require(store.diskGrowth(window: 3600, now: now))
        #expect(hour.deltaBytes == 20 * Bytes.gb && hour.coversWindow)
        let week = try #require(store.diskGrowth(window: 7 * 86_400, now: now))
        #expect(week.deltaBytes == 30 * Bytes.gb && !week.coversWindow && week.actualSpan < 4 * 3600)
        let spikes = store.storageSpikes(since: now.addingTimeInterval(-86_400))
        #expect(spikes.count == 1 && spikes[0].deltaBytes == 18 * Bytes.gb)
    }

    @Test("The agent API leases and protects but exposes no way to delete or terminate")
    func agentAPI() async throws {
        let f = Fixture()
        let store = try PepelStore.inMemory()
        let service = AgentAPIService(store: store, home: f.home)
        let workspace = f.dir(f.projects + "/app/.agent-tmp")

        #expect(!AgentAPIService.operations.contains { $0.contains("delete") || $0.contains("terminate") || $0.contains("kill") || $0 == "cleanup.run" })
        await #expect(throws: APIError.self) { try await service.handle(op: "cleanup.run", args: [:]) }
        await #expect(throws: APIError.self) { try await service.handle(op: "lease.acquire", args: ["owner": "a", "path": "/"]) }
        await #expect(throws: APIError.self) { try await service.handle(op: "lease.acquire", args: ["owner": "a", "path": "~"]) }

        // A disposable mark is only accepted inside a workspace the same agent registered.
        await #expect(throws: APIError.self) { try await service.handle(op: "artifact.disposable", args: ["owner": "codex", "path": workspace + "/out"]) }
        _ = try await service.handle(op: "workspace.register", args: ["owner": "codex", "path": workspace, "seconds": "600"])
        _ = try await service.handle(op: "artifact.disposable", args: ["owner": "codex", "path": workspace + "/out"])
        await #expect(throws: APIError.self) { try await service.handle(op: "artifact.disposable", args: ["owner": "other", "path": workspace + "/out"]) }
        #expect(service.disposables().map(\.path) == [workspace + "/out"])

        let leases = store.leases()
        #expect(leases.count == 1 && leases[0].owner == "codex" && leases[0].path == workspace)
        // Durations are capped.
        let long = try await service.handle(op: "lease.acquire", args: ["owner": "codex", "path": f.projects + "/app/.build", "seconds": "99999999"])
        let lease = try JSONSerialization.jsonObject(with: long) as? [String: Any]
        let id = try #require(lease?["id"] as? String)
        #expect(store.leases().first { $0.id == id }!.expiresAt.timeIntervalSinceNow <= Double(AgentAPIService.maxLeaseSeconds) + 5)

        _ = try await service.handle(op: "lease.release", args: ["id": id])
        await #expect(throws: APIError.self) { try await service.handle(op: "lease.release", args: ["id": id]) }
        _ = try await service.handle(op: "task.complete", args: ["owner": "codex"])
        #expect(store.leases().isEmpty)
        _ = try await service.handle(op: "artifact.protect", args: ["owner": "codex", "path": f.projects + "/app/data"])
        #expect(store.protections().map(\.value) == [f.projects + "/app/data"])
    }

    @Test("The local socket requires the token and is owner-only")
    func socketAuthentication() async throws {
        let f = Fixture()
        let socketPath = f.root + "/s.sock"
        let tokenPath = f.root + "/token"
        let token = try APIToken.loadOrCreate(at: tokenPath)
        let again = try APIToken.loadOrCreate(at: tokenPath)
        #expect(token.count == 64 && again == token)
        var st = stat()
        stat(tokenPath, &st)
        #expect(st.st_mode & 0o777 == 0o600)

        let server = LocalAPIServer(socketPath: socketPath, token: token, service: AgentAPIService(store: try PepelStore.inMemory(), home: f.home))
        try server.start()
        defer { server.stop() }
        stat(socketPath, &st)
        #expect(st.st_mode & 0o777 == 0o600)

        let pong = try LocalAPIClient(socketPath: socketPath, token: token).send(op: "ping")
        #expect(String(decoding: pong, as: UTF8.self).contains("pepel"))
        #expect(throws: APIError.self) { try LocalAPIClient(socketPath: socketPath, token: String(repeating: "0", count: 64)).send(op: "ping") }
        #expect(throws: APIError.self) { try LocalAPIClient(socketPath: socketPath, token: token).send(op: "no.such.op") }
        server.stop()
        #expect(throws: APIError.self) { try LocalAPIClient(socketPath: socketPath, token: token).send(op: "ping") }
    }

    /// A small workstation: two projects, an agent building in one of them, an abandoned test
    /// runner in the other.
    private func workstation(_ f: Fixture) -> (alpha: String, beta: String, processes: [ProcessSnapshot]) {
        let alpha = f.gitRepo(f.projects + "/alpha")
        f.file(alpha + "/Package.swift")
        f.file(alpha + "/Sources/main.swift", text: "print(1)")
        f.file(alpha + "/.build/arm64-apple-macosx/debug/alpha", bytes: 30_000)
        f.file(alpha + "/.pytest_cache/v/x", bytes: 5_000)
        let beta = f.gitRepo(f.projects + "/beta")
        f.file(beta + "/pyproject.toml")
        f.file(beta + "/app.py", text: "x = 1")
        f.file(beta + "/.pytest_cache/v/x", bytes: 5_000)
        f.file(beta + "/.ruff_cache/x", bytes: 5_000)
        f.file(beta + "/.venv/pyvenv.cfg")
        f.file(f.home + "/.claude/history.jsonl", bytes: 9_000)
        f.age(f.home, hours: 100)
        let processes = [
            process(10, name: "claude", path: "/Users/x/.local/bin/claude", cwd: alpha),
            process(11, parent: 10, name: "swift-build", cwd: alpha, start: 1_000_100, cpu: 5_000_000_000),
            process(20, parent: 1, name: "pytest", args: ["pytest", "-x"], cwd: beta, footprint: 400_000_000),
        ]
        return (alpha, beta, processes)
    }

    private func makeEngine(_ f: Fixture, processes: [ProcessSnapshot], store: PepelStore) throws -> PepelEngine {
        var settings = PepelSettings()
        settings.projectRoots = [f.projects]
        try store.saveSettings(settings)
        return try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled,
            analyzers: [XcodeDerivedDataAnalyzer(), SwiftPMAnalyzer(), PythonAnalyzer(), AIToolsAnalyzer()],
            processSource: FakeProcessSource(processes: processes), telemetry: { SystemTelemetry(diskTotalBytes: 2000 * Bytes.gb, diskAvailableBytes: 900 * Bytes.gb) })
    }

    @Test("End to end: scan, protect what is in use, preview without deleting, then clean only what is safe")
    func endToEnd() async throws {
        let f = Fixture()
        let store = try PepelStore.inMemory()
        let (alpha, beta, processes) = workstation(f)
        let engine = try makeEngine(f, processes: processes, store: store)

        let state = await engine.scan()
        #expect(state.projects.map(\.name).sorted() == ["alpha", "beta"])
        #expect(state.builds.count == 1 && state.builds[0].name == "alpha" && state.builds[0].activeCount == 1)
        let live = try #require(await engine.live)
        #expect(live.agentSessions.count == 1 && live.agentSessions[0].projectID == alpha)
        #expect(live.activeBuildCount == 1)

        let plan = await engine.cleanupPlan(initiator: .user)
        func verdict(_ suffix: String) -> CleanupVerdict? { plan.decisions.first { $0.item.path.hasSuffix(suffix) }?.verdict }
        #expect(verdict("alpha/.build/arm64-apple-macosx/debug") == .denied, "an agent is building there")
        #expect(verdict("alpha/.pytest_cache") == .denied, "a build is running in the project")
        #expect(verdict("beta/.venv") == .needsConfirmation)
        #expect(verdict("beta/.ruff_cache") == .allowed)
        #expect(!plan.decisions.contains { $0.item.path.hasSuffix("/.claude") }, "protected items are not offered at all")
        #expect(state.items.first { $0.path.hasSuffix("/.claude") }?.safety == .protected)

        // Dry run: every check runs, nothing changes.
        let preview = await engine.executeCleanup(plan, confirmed: Set(plan.decisions.map(\.id)), dryRun: true)
        #expect(preview.outcomes.allSatisfy { $0.status == .wouldApply })
        #expect(PathUtil.exists(beta + "/.ruff_cache") && PathUtil.exists(beta + "/.venv/pyvenv.cfg"))

        // Real run with nothing confirmed: only safe items go.
        let report = await engine.executeCleanup(plan, confirmed: [], dryRun: false)
        #expect(report.outcomes.map(\.path).sorted() == [beta + "/.pytest_cache", beta + "/.ruff_cache"])
        #expect(report.outcomes.allSatisfy { $0.status == .removed })
        #expect(!PathUtil.exists(beta + "/.ruff_cache") && !PathUtil.exists(beta + "/.pytest_cache"))
        for survivor in [beta + "/app.py", beta + "/.venv/pyvenv.cfg", beta + "/.git/HEAD", alpha + "/Sources/main.swift", alpha + "/.build/arm64-apple-macosx/debug/alpha", alpha + "/.pytest_cache/v/x", f.home + "/.claude/history.jsonl"] {
            #expect(PathUtil.exists(survivor), "\(survivor) must survive")
        }
        let remaining = await engine.storage?.items.map(\.path) ?? []
        #expect(!remaining.contains(beta + "/.ruff_cache"))
        let kinds = store.audit().map(\.kind)
        #expect(kinds.filter { $0 == .cleanup }.count == 2 && kinds.contains(.cleanupPreview) && kinds.contains(.scan))
    }

    @Test("An engine pointed at another home directory cannot see or clean the real machine")
    func redirectedHomeIsIsolated() async throws {
        let f = Fixture()
        let paths = AppPaths(home: f.home, supportDirectory: f.root + "/support")
        #expect(paths.isRedirected)
        #expect(PathUtil.isInside(paths.temporaryDirectory, root: f.home) && PathUtil.isInside(paths.sharedTemporaryDirectory, root: f.home))
        #expect(!AppPaths().isRedirected && AppPaths().temporaryDirectory == PathUtil.canonical(NSTemporaryDirectory()))

        // A stale Go work directory in the *real* temp folder, and one in the fixture's.
        let real = PathUtil.canonical(NSTemporaryDirectory()) + "/go-build-pepel-isolation-" + String(UUID().uuidString.prefix(6))
        f.file(real + "/b001/x.o")
        f.age(real, hours: 72)
        defer { try? FileManager.default.removeItem(atPath: real) }
        f.file(paths.temporaryDirectory + "/go-build123/b001/x.o")
        f.age(paths.temporaryDirectory + "/go-build123", hours: 72)

        var settings = PepelSettings()
        settings.projectRoots = [f.projects]
        let store = try PepelStore.inMemory()
        try store.saveSettings(settings)
        // Default tools and the full analyzer set, exactly as the CLI would run with PEPEL_HOME.
        let engine = try PepelEngine(paths: paths, store: store, processSource: FakeProcessSource(processes: []), telemetry: { SystemTelemetry() })
        #expect(engine.tools.locate("docker") == nil && engine.tools.locate("go") == nil && engine.tools.locate("xcrun") == nil)

        let state = await engine.scan()
        #expect(state.items.map(\.path) == [paths.temporaryDirectory + "/go-build123"])
        #expect(state.items.allSatisfy { PathUtil.isInside($0.path, root: f.root) }, "nothing outside the fixture may be reported")

        let plan = await engine.cleanupPlan(initiator: .cli)
        _ = await engine.executeCleanup(plan, confirmed: [], dryRun: false)
        #expect(!PathUtil.exists(paths.temporaryDirectory + "/go-build123"))
        #expect(PathUtil.exists(real + "/b001/x.o"), "the real temporary folder must be untouched")

        // Even an item pointing at the real temp folder is refused by the policy in this mode.
        let foreign = f.item(real)
        let context = await engine.policyContext(for: [foreign])
        #expect(CleanupPolicyEngine().evaluate(foreign, initiator: .cli, context: context).verdict == .denied)
    }

    @Test("Automatic mode cleans safe items only when enabled, and leaves agent-occupied projects alone")
    func automaticPass() async throws {
        let f = Fixture()
        let store = try PepelStore.inMemory()
        let (alpha, beta, processes) = workstation(f)
        let engine = try makeEngine(f, processes: processes, store: store)
        _ = await engine.scan()

        let off = await engine.automaticPass()
        #expect(off.cleanup == nil && PathUtil.exists(beta + "/.ruff_cache"))

        _ = try await engine.update { $0.monitoringMode = .automaticSafe }
        let on = await engine.automaticPass()
        #expect(on.cleanup?.succeededCount == 2)
        #expect(!PathUtil.exists(beta + "/.ruff_cache"))
        #expect(PathUtil.exists(alpha + "/.pytest_cache/v/x"), "safe, but a build and an agent are active in that project")
        #expect(PathUtil.exists(beta + "/.venv/pyvenv.cfg"))
        #expect(on.terminations.isEmpty, "automatic termination was not enabled")
    }

    @Test("The engine refuses to terminate agents and active builds, and asks before terminating anything else")
    func engineTermination() async throws {
        let f = Fixture()
        let store = try PepelStore.inMemory()
        let (_, _, processes) = workstation(f)
        let engine = try makeEngine(f, processes: processes, store: store)
        _ = await engine.refreshLive()

        if case .denied = await engine.terminate(processes[0].identity, confirmed: true, force: true, initiator: .user) {} else { Issue.record("agent session must be denied") }
        if case .denied = await engine.terminate(processes[1].identity, confirmed: true, force: true, initiator: .user) {} else { Issue.record("active build must be denied") }
        if case .needsConfirmation = await engine.terminate(processes[2].identity, confirmed: false, force: false, initiator: .user) {} else { Issue.record("must ask first") }
        if case .denied = await engine.terminate(processes[2].identity, confirmed: true, force: false, initiator: .agent) {} else { Issue.record("agents must be denied") }
        if case .notFound = await engine.terminate(ProcessIdentity(pid: 20, startTime: 42), confirmed: true, force: false, initiator: .user) {} else { Issue.record("a reused PID is a different process") }
        #expect(store.audit(kinds: [.terminationDenied]).count >= 3)
        #expect(store.audit(kinds: [.termination]).isEmpty, "nothing was signalled")
    }

    @Test("With the setting on, the engine terminates a sleeping session and its servers, and leaves a working one alone")
    func engineTerminatesSleepingAgents() async throws {
        let f = Fixture()
        let store = try PepelStore.inMemory()
        let alpha = f.gitRepo(f.projects + "/alpha"), beta = f.gitRepo(f.projects + "/beta")
        let now = Date()
        var sleeper = process(10, name: "claude", path: "/Users/x/.local/bin/claude", cwd: alpha, footprint: 300_000_000)
        sleeper.diskBytesWritten = 5_000_000
        let sleeperServer = process(11, parent: 10, name: "python3", args: ["python3", "mcp-server"], cwd: alpha, start: 1_000_100, footprint: 100_000_000)
        var worker = process(20, name: "claude", path: "/Users/x/.local/bin/claude", cwd: beta)
        worker.diskBytesWritten = 9_000_000
        worker.cpuTimeNs = 400 * 1_000_000_000
        // Three hours of recorded history: the sleeper never wrote; the worker wrote a minute ago.
        func record(_ p: ProcessSnapshot, written: [(minutesAgo: Double, bytes: UInt64)]) {
            for point in written {
                var copy = p
                copy.diskBytesWritten = point.bytes
                copy.cpuTimeNs = 0  // all of the worker's CPU time falls in the last minute: it is busy now
                store.recordObservations([copy], at: now.addingTimeInterval(-point.minutesAgo * 60))
            }
        }
        record(sleeper, written: [(170, 5_000_000), (120, 5_000_000), (60, 5_000_000), (2, 5_000_000)])
        record(sleeperServer, written: [(170, 0), (2, 0)])
        record(worker, written: [(170, 1_000_000), (60, 4_000_000), (1, 8_500_000)])

        let source = FakeProcessSource(processes: [sleeper, sleeperServer, worker])
        var settings = PepelSettings()
        settings.projectRoots = [f.projects]
        settings.gracefulTerminationSeconds = 2
        try store.saveSettings(settings)
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled,
            analyzers: [], processSource: source, telemetry: { SystemTelemetry() })

        let live = await engine.refreshLive()
        let states = Dictionary(uniqueKeysWithValues: live.agentSessions.map { ($0.root.pid, $0.state) })
        #expect(states[10] == .sleeping && states[20] == .working)

        // Off by default: nothing happens.
        let off = await engine.automaticPass()
        #expect(off.terminations.isEmpty && source.signals.isEmpty)

        _ = try await engine.update { $0.terminateSleepingAgents = true }
        let on = await engine.automaticPass()
        #expect(on.terminations.map(\.target.pid) == [10])
        #expect(source.signals.map(\.pid) == [10, 11], "the session, then the server it left behind")
        #expect(source.signals.allSatisfy { $0.signal == SIGTERM })
        #expect(source.snapshot().map(\.pid) == [20], "the working session is untouched")
        #expect(store.audit(kinds: [.termination]).first?.initiator == "automatic")
    }

    @Test("Free memory ends sleeping sessions by default, idle ones only when chosen, and never a working one")
    func freeMemoryPass() async throws {
        let f = Fixture()
        let store = try PepelStore.inMemory()
        let alpha = f.gitRepo(f.projects + "/alpha"), beta = f.gitRepo(f.projects + "/beta"), gamma = f.gitRepo(f.projects + "/gamma")
        let now = Date()
        var sleeper = process(10, name: "claude", path: "/Users/x/.local/bin/claude", cwd: alpha, footprint: 300_000_000)
        sleeper.diskBytesWritten = 5_000_000
        let sleeperServer = process(11, parent: 10, name: "python3", args: ["python3", "mcp-server"], cwd: alpha, start: 1_000_100, footprint: 100_000_000)
        var worker = process(20, name: "claude", path: "/Users/x/.local/bin/claude", cwd: beta)
        worker.diskBytesWritten = 9_000_000
        worker.cpuTimeNs = 400 * 1_000_000_000
        var idler = process(30, name: "claude", path: "/Users/x/.local/bin/claude", cwd: gamma, footprint: 200_000_000)
        idler.diskBytesWritten = 4_000_000
        func record(_ p: ProcessSnapshot, written: [(minutesAgo: Double, bytes: UInt64)]) {
            for point in written {
                var copy = p
                copy.diskBytesWritten = point.bytes
                copy.cpuTimeNs = 0
                store.recordObservations([copy], at: now.addingTimeInterval(-point.minutesAgo * 60))
            }
        }
        record(sleeper, written: [(170, 5_000_000), (120, 5_000_000), (60, 5_000_000), (2, 5_000_000)])
        record(sleeperServer, written: [(170, 0), (2, 0)])
        record(worker, written: [(170, 1_000_000), (60, 4_000_000), (1, 8_500_000)])
        // Wrote half an hour ago and nothing since: quiet, but not for the two-hour window.
        idler.cpuTimeNs = 60 * 1_000_000_000
        for (minutesAgo, bytes, cpuSeconds) in [(170.0, 1_000_000, 0), (32, 1_000_000, 0), (30, 4_000_000, 60), (2, 4_000_000, 60)] as [(Double, UInt64, UInt64)] {
            var copy = idler
            copy.diskBytesWritten = bytes
            copy.cpuTimeNs = cpuSeconds * 1_000_000_000
            store.recordObservations([copy], at: now.addingTimeInterval(-minutesAgo * 60))
        }

        let source = FakeProcessSource(processes: [sleeper, sleeperServer, worker, idler])
        var settings = PepelSettings()
        settings.projectRoots = [f.projects]
        settings.gracefulTerminationSeconds = 2
        try store.saveSettings(settings)
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled,
            analyzers: [], processSource: source, telemetry: { SystemTelemetry() })

        let plan = await engine.reclaimPlan()
        let seen = await engine.live?.agentSessions.map { "\($0.root.pid):\($0.state):\($0.evidence)" } ?? []
        #expect(plan.steps.map(\.kind) == [.sleepingAgents, .idleAgents], "\(plan.steps.map { "\($0.kind) \($0.targets)" }) \(seen)")
        #expect(plan.defaultSelection == ["sleepingAgents"], "idle sessions are offered, not preselected")
        #expect(plan.steps[0].estimatedBytes == 400_000_000)
        #expect(source.signals.isEmpty, "making a plan signals nothing")

        // Agents cannot use this to end sessions.
        let asAgent = await engine.reclaim(["sleepingAgents", "idleAgents"], initiator: .agent)
        #expect(asAgent.results.allSatisfy { $0.done == 0 } && source.signals.isEmpty)

        let first = await engine.reclaim(plan.defaultSelection)
        #expect(first.results.map(\.done) == [1])
        #expect(source.signals.map(\.pid) == [10, 11])
        #expect(Set(source.snapshot().map(\.pid)) == [20, 30])

        // Asking for a step that is not in the plan (working sessions never are) does nothing.
        let second = await engine.reclaim(["idleAgents", "workingAgents"])
        #expect(second.results.map(\.kind) == [.idleAgents] && second.results[0].done == 1)
        #expect(source.snapshot().map(\.pid) == [20], "the working session is never touched")
        #expect(store.audit(kinds: [.termination]).contains { $0.subject == "Free memory" })

        let empty = await engine.reclaimPlan()
        #expect(empty.steps.isEmpty)
    }

    final class PIDBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int32?
        func set(_ pid: Int32?) { lock.lock(); value = pid; lock.unlock() }
        var pid: Int32? { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test("A quiet session is suspended only behind another application, wakes when its own comes forward or work arrives, and is never left stopped")
    func freezing() async throws {
        let f = Fixture()
        let store = try PepelStore.inMemory()
        let alpha = f.gitRepo(f.projects + "/alpha"), beta = f.gitRepo(f.projects + "/beta"), gamma = f.gitRepo(f.projects + "/gamma")
        let now = Date()
        let terminal = process(100, name: "Terminal", path: "/Applications/Terminal.app/Contents/MacOS/Terminal")
        let shell = process(101, parent: 100, name: "zsh", path: "/bin/zsh")
        var quiet = process(10, parent: 101, name: "claude", path: "/Users/x/.local/bin/claude", cwd: alpha, footprint: 200_000_000)
        quiet.diskBytesWritten = 4_000_000
        quiet.cpuTimeNs = 60 * 1_000_000_000
        let helper = process(11, parent: 10, name: "python3", args: ["python3", "mcp-server"], cwd: alpha, footprint: 100_000_000)
        var worker = process(20, parent: 101, name: "claude", path: "/Users/x/.local/bin/claude", cwd: beta)
        worker.diskBytesWritten = 9_000_000
        worker.cpuTimeNs = 400 * 1_000_000_000
        // Same quiet history, but inside tmux: no application to come back to.
        var detached = process(30, name: "claude", path: "/Users/x/.local/bin/claude", cwd: gamma)
        detached.diskBytesWritten = 4_000_000
        detached.cpuTimeNs = 60 * 1_000_000_000
        for session in [quiet, detached] {
            for (minutesAgo, bytes, cpuSeconds) in [(170.0, 1_000_000, 0), (32, 1_000_000, 0), (30, 4_000_000, 60), (2, 4_000_000, 60)] as [(Double, UInt64, UInt64)] {
                var copy = session
                copy.diskBytesWritten = bytes
                copy.cpuTimeNs = cpuSeconds * 1_000_000_000
                store.recordObservations([copy], at: now.addingTimeInterval(-minutesAgo * 60))
            }
        }
        for (minutesAgo, bytes) in [(170.0, 1_000_000), (60, 4_000_000), (1, 8_500_000)] as [(Double, UInt64)] {
            var copy = worker
            copy.diskBytesWritten = bytes
            copy.cpuTimeNs = 0
            store.recordObservations([copy], at: now.addingTimeInterval(-minutesAgo * 60))
        }
        let source = FakeProcessSource(processes: [terminal, shell, quiet, helper, worker, detached])
        var settings = PepelSettings()
        settings.projectRoots = [f.projects]
        try store.saveSettings(settings)
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled, analyzers: [],
            processSource: source, telemetry: { SystemTelemetry() })
        let front = PIDBox()
        await engine.setFrontmostProvider { front.pid }
        func stops() -> [Int32] { source.signals.filter { $0.signal == SIGSTOP }.map(\.pid) }
        func continues() -> [Int32] { source.signals.filter { $0.signal == SIGCONT }.map(\.pid) }

        let live = await engine.refreshLive()
        #expect(Dictionary(uniqueKeysWithValues: live.agentSessions.map { ($0.root.pid, $0.state) }) == [10: .idle, 20: .working, 30: .idle])

        // Off by default; and with it on, not while PEPEL cannot see what is in front, nor under Terminal itself.
        front.set(999)
        _ = await engine.automaticPass()
        _ = try await engine.update { $0.freezeIdleAgents = true }
        front.set(nil)
        _ = await engine.automaticPass()
        front.set(100)
        _ = await engine.automaticPass()
        #expect(source.signals.isEmpty)

        front.set(999)
        _ = await engine.automaticPass()
        #expect(stops() == [11, 10], "the helper first, then the session; neither the working one nor the one inside tmux")
        #expect(engine.frozenTrees().map(\.root.pid) == [10] && engine.frozenTrees().first?.ownerAppName == "Terminal")
        #expect(await engine.refreshLive().agentSessions.first { $0.root.pid == 10 }?.frozenSince != nil)
        #expect(Set(source.snapshot().map(\.pid)) == [100, 101, 10, 11, 20, 30], "nothing was ended")

        // Coming back to Terminal wakes it at once.
        engine.applicationActivated(pid: 100)
        #expect(Set(continues()) == [10, 11] && engine.frozenTrees().isEmpty)

        // Just woken: left alone for a full quiet period, then suspended again.
        source.clearSignals()
        _ = await engine.automaticPass()
        #expect(stops().isEmpty)
        let later = Date().addingTimeInterval(21 * 60)
        await engine.freezePass(now: later)
        #expect(stops() == [11, 10])

        // A peek with nothing waiting puts it back; a peek that finds work leaves it awake.
        source.clearSignals()
        let peekAt = later.addingTimeInterval(11 * 60)
        await engine.freezePass(now: peekAt)
        #expect(Set(continues()) == [10, 11] && engine.frozenTrees().first?.isPeeking == true)
        await engine.freezePass(now: peekAt.addingTimeInterval(5))
        #expect(stops().isEmpty, "a peek lasts at least twenty seconds")
        await engine.freezePass(now: peekAt.addingTimeInterval(25))
        #expect(stops() == [11, 10] && engine.frozenTrees().first?.isPeeking == false)

        source.clearSignals()
        let second = peekAt.addingTimeInterval(25 + 11 * 60)
        await engine.freezePass(now: second)
        source.mutate(10) { $0.cpuTimeNs += 5 * 1_000_000_000 }
        await engine.refreshLive()
        await engine.freezePass(now: second.addingTimeInterval(25))
        #expect(stops().isEmpty && engine.frozenTrees().isEmpty, "it had work to do, so it stays awake")
        #expect(store.audit(kinds: [.termination]).contains { $0.outcome == "woken" && ($0.detail["reason"] ?? "").contains("work was waiting") })

        // By hand: an agent cannot, a person can, also without an application to return to; then everything is woken.
        let asAgent = await engine.freeze(detached.identity, confirmed: true, initiator: .agent)
        #expect(asAgent?.verdict == .denied)
        let working = await engine.freeze(worker.identity, confirmed: true, initiator: .user)
        #expect(working?.verdict == .denied)
        source.clearSignals()
        let byHand = await engine.freeze(detached.identity, confirmed: true, initiator: .cli)
        #expect(byHand?.verdict == .needsConfirmation && stops() == [30])
        #expect(byHand?.warnings.contains { $0.contains("pepel thaw") } == true)

        _ = await engine.freeze(quiet.identity, confirmed: true, initiator: .user)
        #expect(engine.thawAll(reason: "PEPEL quit") == 2 && engine.frozenTrees().isEmpty)

        // Ending a suspended session wakes it first, or SIGTERM would never be acted on.
        _ = await engine.freeze(detached.identity, confirmed: true, initiator: .user)
        source.clearSignals()
        _ = await engine.reclaim(["idleAgents"])
        let order = source.signals.filter { $0.pid == 30 }.map(\.signal)
        #expect(order.first == SIGCONT && order.contains(SIGTERM))
        #expect(engine.frozenTrees().isEmpty)
    }

    final class FlushCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test("The file cache is flushed only for a person, only when asked, and a dismissed prompt is reported as such")
    func fileCacheFlush() async throws {
        let f = Fixture()
        let store = try PepelStore.inMemory()
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled, analyzers: [],
            processSource: FakeProcessSource(processes: []), telemetry: { SystemTelemetry(cachedFileBytes: 6 * Bytes.gb, freeBytes: Bytes.gb) })

        // A redirected engine has no flusher: a test must never raise an administrator prompt.
        #expect(await engine.reclaimPlan().steps.isEmpty)

        let counter = FlushCounter()
        await engine.setFileCacheFlusher(FileCacheFlusher(isAvailable: true) { counter.bump(); return .flushed })
        let plan = await engine.reclaimPlan()
        #expect(plan.steps.map(\.kind) == [.fileCache] && plan.defaultSelection == ["fileCache"])
        #expect(plan.estimatedBytes(plan.defaultSelection) == 0, "cached files are not counted as memory given back")
        #expect(counter.count == 0)

        for initiator in [Initiator.agent, .automatic] {
            let refused = await engine.reclaim(["fileCache"], initiator: initiator)
            #expect(refused.results.first?.done == 0)
        }
        #expect(counter.count == 0, "neither an agent nor the automatic pass flushes the cache")

        let done = await engine.reclaim(["fileCache"], initiator: .user)
        #expect(done.results.first?.done == 1 && counter.count == 1)

        await engine.setFileCacheFlusher(FileCacheFlusher(isAvailable: true) { .cancelled })
        let cancelled = await engine.reclaim(["fileCache"], initiator: .cli)
        #expect(cancelled.results.first?.done == 0 && cancelled.results.first?.notes.first?.contains("dismissed") == true)
    }

    @Test("The standing permission is one fixed sudo rule for purge, and the plan says whether a prompt will appear")
    func fileCachePermission() async throws {
        #expect(FileCacheFlusher.rule(uid: 501) == "#501 ALL=(root) NOPASSWD: /usr/sbin/purge \"\"")
        let script = FileCacheFlusher.grantScript(uid: 501)
        #expect(script.contains("/usr/sbin/visudo -cf") && script.contains("install -m 0440 -o root -g wheel") && script.hasSuffix("; /usr/sbin/purge"))
        #expect(script.contains(FileCacheFlusher.rulePath) && !script.contains("rm -rf"))
        // Quotes and backslashes survive the trip through AppleScript.
        #expect(FileCacheFlusher.appleScript(shell: "a \"b\" \\n", prompt: "p") == "do shell script \"a \\\"b\\\" \\\\n\" with prompt \"p\" with administrator privileges")

        let f = Fixture()
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: try PepelStore.inMemory(), tools: .disabled, analyzers: [],
            processSource: FakeProcessSource(processes: []), telemetry: { SystemTelemetry(cachedFileBytes: 6 * Bytes.gb) })
        #expect(await engine.fileCachePermission() == (false, false))
        let revoked = FlushCounter()
        await engine.setFileCacheFlusher(FileCacheFlusher(isAvailable: true, hasPermission: { false }, flush: { .flushed }))
        #expect(await engine.reclaimPlan().steps.first?.detail.contains("this once") == true)
        await engine.setFileCacheFlusher(FileCacheFlusher(isAvailable: true, hasPermission: { true }, flush: { .flushed }, revoke: { revoked.bump(); return .flushed }))
        #expect(await engine.reclaimPlan().steps.first?.detail.contains("without a prompt") == true)
        #expect(await engine.fileCachePermission() == (true, true))
        #expect(await engine.revokeFileCachePermission(initiator: .agent) != .flushed && revoked.count == 0, "an agent cannot change the permission")
        #expect(await engine.revokeFileCachePermission(initiator: .user) == .flushed && revoked.count == 1)
    }

    @Test("Under memory pressure thresholds shorten only when the setting is on, and never below their floors")
    func pressureAdaptation() {
        var settings = PepelSettings()
        #expect(settings.adapted(to: .critical).agentSleepMinutes == 120, "off by default")
        settings.adaptToMemoryPressure = true
        #expect(settings.adapted(to: .normal).agentSleepMinutes == 120)
        #expect(settings.adapted(to: .elevated).agentSleepMinutes == 60 && settings.adapted(to: .elevated).projectIdleGraceMinutes == 30)
        #expect(settings.adapted(to: .critical).agentSleepMinutes == 30 && settings.adapted(to: .critical).projectIdleGraceMinutes == 15)
        settings.agentSleepMinutes = 40
        #expect(settings.adapted(to: .critical).agentSleepMinutes == 30)

        // The Docker VM: outside the night window it restarts only under pressure with the setting on.
        let policy = CleanupPolicyEngine()
        var report = ContainerReport(product: "Docker Desktop", vmLimitBytes: 32 * Bytes.gb, cpus: 8, running: 0, total: 0, groups: [], hostFootprintBytes: 30 * Bytes.gb)
        report.baselineOverheadBytes = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let noon = Date(timeIntervalSince1970: TimeInterval(1_800_000_000 - 1_800_000_000 % 86_400 + 12 * 3600))
        settings.refreshContainerVMNightly = true
        func verdict(_ pressure: MemoryPressureLevel, hoursSinceLast: Double, working: Int = 0) -> CleanupVerdict {
            policy.evaluateVMRefresh(
                report, workingSessions: working, initiator: .automatic, settings: settings, lastRefresh: noon.addingTimeInterval(-hoursSinceLast * 3600),
                pressure: pressure, now: noon, calendar: calendar
            ).verdict
        }
        #expect(report.excessBytes >= settings.vmRefreshMinimumExcessBytes)
        #expect(verdict(.normal, hoursSinceLast: 8) == .denied)
        #expect(verdict(.elevated, hoursSinceLast: 8) == .allowed)
        #expect(verdict(.elevated, hoursSinceLast: 3) == .denied, "not more often than every six hours")
        #expect(verdict(.critical, hoursSinceLast: 8, working: 1) == .denied, "never under a working session")
        settings.adaptToMemoryPressure = false
        #expect(verdict(.critical, hoursSinceLast: 8) == .denied)
    }

    @Test("The engine notices an application quitting, reports what it left, and terminates it only when enabled")
    func engineHandlesLeftovers() async throws {
        let f = Fixture()
        let store = try PepelStore.inMemory()
        let app = "/Applications/Editor.app"
        let main = process(100, name: "Editor", path: app + "/Contents/MacOS/Editor")
        let helper = process(101, parent: 100, name: "Editor Helper", path: app + "/Contents/Frameworks/Editor Helper.app/Contents/MacOS/Editor Helper", start: 1_000_100, footprint: 500_000_000)
        var settings = PepelSettings()
        settings.projectRoots = [f.projects]
        settings.gracefulTerminationSeconds = 2
        settings.appLeftoverGraceMinutes = 10
        try store.saveSettings(settings)
        let paths = AppPaths(home: f.home, supportDirectory: f.root + "/support")
        let now = Date()

        // The application is seen running, then the engine stops (as if PEPEL was restarted).
        var first: PepelEngine? = try PepelEngine(paths: paths, store: store, tools: .disabled, analyzers: [], processSource: FakeProcessSource(processes: [main, helper]), telemetry: { SystemTelemetry() })
        _ = await first!.refreshLive(now: now.addingTimeInterval(-1800))
        first = nil

        // A new engine starts after the application quit; the helper is still there.
        var orphan = helper
        orphan.parentPID = 1
        let source = FakeProcessSource(processes: [orphan])
        let engine = try PepelEngine(paths: paths, store: store, tools: .disabled, analyzers: [], processSource: source, telemetry: { SystemTelemetry() })
        _ = await engine.refreshLive(now: now.addingTimeInterval(-900))  // the quit is noticed here
        let live = await engine.refreshLive(now: now)
        #expect(live.leftovers.map(\.appName) == ["Editor"] && live.leftovers.first?.processes.map(\.process.pid) == [101])
        #expect(live.leftovers.first?.processes.first?.eligibility == .automaticEligible, "15 minutes after the quit, past the 10-minute grace")

        let off = await engine.automaticPass()
        #expect(off.terminations.isEmpty && source.signals.isEmpty, "off by default")
        if case .needsConfirmation = await engine.terminate(orphan.identity, confirmed: false, force: false, initiator: .user) {} else { Issue.record("manual termination must ask first") }

        _ = try await engine.update { $0.terminateAppLeftovers = true }
        let on = await engine.automaticPass()
        #expect(on.terminations.map(\.target.pid) == [101] && source.signals.map(\.pid) == [101])
        let after = await engine.refreshLive()
        #expect(after.leftovers.isEmpty)
    }

    @Test("Alerts warn about low disk space and budgets without claiming to prevent growth")
    func alerts() {
        let live = LiveState(
            telemetry: SystemTelemetry(diskTotalBytes: 2000 * Bytes.gb, diskAvailableBytes: 20 * Bytes.gb), assessments: [], agentSessions: [],
            memory: MemoryGuardian.advise(telemetry: SystemTelemetry(), processes: [], assessments: []), activeBuildCount: 0, userProcessCount: 0, sampledAt: Date())
        let alerts = AlertEvaluator.alerts(live: live, storage: nil, growth: nil, settings: PepelSettings())
        #expect(alerts.map(\.id) == ["disk-low"])
        #expect(alerts[0].message.contains("run a scan to diagnose"))
    }
}
