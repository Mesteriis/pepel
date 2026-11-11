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

    @Test("Growth is steady rise over hours, not a spike or a high level, and starts over after a restart")
    func memoryGrowthDetection() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func samples(_ gib: [Double], everyMinutes: Double = 30) -> [MemorySample] {
            gib.enumerated().map { MemorySample(at: start.addingTimeInterval(Double($0.offset) * everyMinutes * 60), bytes: Int64($0.element * Double(1 << 30))) }
        }
        func growth(_ gib: [Double], everyMinutes: Double = 30) -> MemoryGrowth? {
            MemoryGrowthAnalyzer.growth(id: "app:/Applications/X.app", kind: .application, name: "X", samples: samples(gib, everyMinutes: everyMinutes))
        }
        let rising = growth([1.0, 1.1, 1.3, 1.8, 2.2, 2.6, 3.0, 3.2, 3.4])
        #expect(rising?.baselineBytes == Int64(1.1 * Double(1 << 30)) && rising?.currentBytes == Int64(3.2 * Double(1 << 30)))
        #expect(rising.map { $0.perHourBytes > 0 && $0.grownBytes > 2 << 30 } == true)
        #expect(growth([6, 6.1, 6, 6.2, 6.1, 6, 6.1, 6.2, 6.1]) == nil, "large but level")
        #expect(growth([1, 1, 1, 1, 5, 1, 1, 1, 1]) == nil, "one spike")
        #expect(growth([1, 1.2, 1.5, 2, 2.4, 2.8, 3.2, 3.4, 3.6], everyMinutes: 5) == nil, "forty minutes are not enough")
        #expect(growth([1, 2, 3, 4, 5, 6, 1, 1.05, 1.1, 1.1, 1.05, 1.1]) == nil, "it was restarted; the new run is level")
        #expect(growth([1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.6, 1.7, 1.7]) == nil, "less than 1 GiB of growth")
    }

    @Test("An application is asked to quit normally, only by a person, never when sessions live inside it, and never forced")
    func applicationRestart() async throws {
        let f = Fixture()
        let store = try PepelStore.inMemory()
        let alpha = f.gitRepo(f.projects + "/alpha")
        let browser = process(200, name: "Browser", path: "/Applications/Browser.app/Contents/MacOS/Browser", footprint: 3_000_000_000)
        let renderer = process(201, parent: 200, name: "Browser Helper", path: "/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Browser Helper", footprint: 2_000_000_000)
        let terminal = process(100, name: "Terminal", path: "/Applications/Terminal.app/Contents/MacOS/Terminal")
        let session = process(10, parent: 100, name: "claude", path: "/Users/x/.local/bin/claude", cwd: alpha)
        let source = FakeProcessSource(processes: [browser, renderer, terminal, session])
        var settings = PepelSettings()
        settings.projectRoots = [f.projects]
        try store.saveSettings(settings)
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled, analyzers: [],
            processSource: source, telemetry: { SystemTelemetry() })
        let launched = PIDBox()
        let obedient = ApplicationControl(
            isAvailable: true, quit: { pid in _ = source.send(SIGTERM, to: pid); _ = source.send(SIGTERM, to: 201); return true },
            launch: { _ in launched.set(1); return true })

        // A redirected engine cannot touch real applications at all.
        let inert = await engine.performApplication(.restart, bundlePath: "/Applications/Browser.app", confirmed: true, initiator: .user, waitSeconds: 0.05)
        #expect(inert?.quit == false && source.snapshot().count == 4)

        await engine.setApplicationControl(obedient)
        let terminalDecision = await engine.applicationDecision(.restart, bundlePath: "/Applications/Terminal.app", initiator: .user)
        #expect(terminalDecision?.verdict == .denied && terminalDecision?.reasons.first?.contains("agent session") == true)
        for initiator in [Initiator.agent, .automatic] {
            let refused = await engine.performApplication(.restart, bundlePath: "/Applications/Browser.app", confirmed: true, initiator: initiator, waitSeconds: 0.05)
            #expect(refused?.quit == false)
        }
        let unconfirmed = await engine.performApplication(.restart, bundlePath: "/Applications/Browser.app", confirmed: false, initiator: .user, waitSeconds: 0.05)
        #expect(unconfirmed?.quit == false && source.snapshot().count == 4 && launched.pid == nil)

        // An application that keeps running (unsaved changes) is left alone and not reopened.
        await engine.setApplicationControl(ApplicationControl(isAvailable: true, quit: { _ in true }, launch: { _ in launched.set(1); return true }))
        let stubborn = await engine.performApplication(.restart, bundlePath: "/Applications/Browser.app", confirmed: true, initiator: .user, waitSeconds: 0.05)
        #expect(stubborn?.quit == false && stubborn?.note.contains("did not force") == true && launched.pid == nil)
        #expect(source.signals.isEmpty, "PEPEL itself never signals an application")

        await engine.setApplicationControl(obedient)
        let done = await engine.performApplication(.restart, bundlePath: "/Applications/Browser.app", confirmed: true, initiator: .user, waitSeconds: 0.05)
        #expect(done?.quit == true && done?.reopened == true && launched.pid == 1)
        #expect(done?.footprintBefore == 5_000_000_000 && done?.footprintAfter == 0)
        #expect(store.audit(kinds: [.termination]).contains { $0.subject == "Browser" && $0.outcome == "restarted" })
    }

    @Test("Memory is recorded per owner every five minutes and growth is reported only for what still runs")
    func memoryHistory() async throws {
        let f = Fixture()
        let store = try PepelStore.inMemory()
        let browser = process(200, name: "Browser", path: "/Applications/Browser.app/Contents/MacOS/Browser", footprint: 4 << 30)
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled, analyzers: [],
            processSource: FakeProcessSource(processes: [browser]), telemetry: { SystemTelemetry() })
        let now = Date()
        for (hoursAgo, gib) in [(8.0, 1.0), (7, 1.1), (6, 1.4), (5, 1.9), (4, 2.4), (3, 2.9), (2, 3.3), (1, 3.7)] {
            let at = now.addingTimeInterval(-hoursAgo * 3600)
            store.recordUsage(scope: "memory", entries: [("app:/Applications/Browser.app", "Browser", Int64(gib * Double(1 << 30))), ("app:/Applications/Gone.app", "Gone", Int64(gib * Double(1 << 30)))], at: at)
        }
        let live = await engine.refreshLive()
        #expect(live.growth.map(\.name) == ["Browser"], "Gone grew the same way but is not running")
        #expect(store.usageSeries(scope: "memory", since: now.addingTimeInterval(-60))["app:/Applications/Browser.app"]?.samples.count == 1, "this sample was recorded")
        await engine.setApplicationControl(ApplicationControl(isAvailable: true, quit: { _ in true }, launch: { _ in true }))
        let plan = await engine.reclaimPlan()
        #expect(plan.steps.map(\.kind) == [.grownApps] && plan.defaultSelection.isEmpty, "offered, never preselected")
    }

    @Test("An application is unused only when open, long out of front, idle in the background and not kept; quitting it is offered, never preselected")
    func unusedApplications() async throws {
        let f = Fixture()
        let store = try PepelStore.inMemory()
        func app(_ pid: Int32, _ name: String, gib: Int64 = 1, cpuMs: UInt64 = 0) -> ProcessSnapshot {
            process(pid, name: name, path: "/Applications/\(name).app/Contents/MacOS/\(name)", cpu: cpuMs * 1_000_000, footprint: gib << 30)
        }
        // CPU counters as they stand now; the engine records them on its first sample.
        let source = FakeProcessSource(processes: [app(1, "Notes", cpuMs: 600), app(2, "Music", cpuMs: 360_000), app(3, "Mail"), app(4, "Editor"), app(5, "Tiny", gib: 0), app(6, "Fresh")])
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled, analyzers: [],
            processSource: source, telemetry: { SystemTelemetry() })
        let names = ["Notes", "Music", "Mail", "Editor", "Tiny", "Fresh"]
        let running = names.enumerated().map { RunningApplicationInfo(pid: Int32($0.offset + 1), bundlePath: "/Applications/\($0.element).app", name: $0.element, isRegular: true) }
        await engine.setApplicationControl(
            ApplicationControl(isAvailable: true, quit: { pid in source.send(SIGTERM, to: pid) }, launch: { _ in true }, running: { running }))
        let front = PIDBox()
        front.set(4)  // Editor is in front
        await engine.setFrontmostProvider { front.pid }
        let now = Date()
        for name in names where name != "Fresh" { engine.noteActivation(bundlePath: "/Applications/\(name).app", at: now.addingTimeInterval(-7 * 3600)) }
        // Over the last hour Music used 10% of a core, Notes almost nothing; Mail has no readings.
        for (minutesAgo, music, notes) in [(60.0, 0, 0), (30, 180_000, 300), (1, 360_000, 600)] as [(Double, Int64, Int64)] {
            store.recordUsage(scope: "appcpu", entries: [("/Applications/Music.app", "", music), ("/Applications/Notes.app", "", notes)], at: now.addingTimeInterval(-minutesAgo * 60))
        }
        _ = try await engine.update { $0.keepApplications = ["mail"] }

        let live = await engine.refreshLive()
        #expect(live.unusedApplications.map(\.name) == ["Notes"], "Music is busy, Mail is kept, Editor is in front, Tiny is small, Fresh was first seen now")
        #expect(live.unusedApplications.first?.cpuPercent.map { $0 < 0.1 } == true)
        #expect(engine.lastActive()["/Applications/Editor.app"].map { now.timeIntervalSince($0) < 60 } == true, "being in front resets the clock")

        let plan = await engine.reclaimPlan()
        #expect(plan.steps.map(\.kind) == [.unusedApps] && plan.defaultSelection.isEmpty)
        #expect(source.signals.isEmpty)
        let done = await engine.reclaim(["unusedApps"])
        #expect(done.results.first?.done == 1 && !source.snapshot().contains { $0.pid == 1 } && source.snapshot().count == 5)
    }

    @Test("A process living in swap is listed and ended only when a person asks; applications, system processes and agent sessions are not listed")
    func dormantProcesses() async throws {
        let f = Fixture()
        let store = try PepelStore.inMemory()
        func swapped(_ pid: Int32, parent: Int32 = 1, name: String, path: String, resident: Int64 = 20_000_000) -> ProcessSnapshot {
            var p = process(pid, parent: parent, name: name, path: path, footprint: 4_000_000_000)
            p.residentBytes = resident
            return p
        }
        let forgotten = swapped(50, name: "indexer", path: "/Users/x/bin/indexer")
        let inRAM = swapped(51, name: "busy", path: "/Users/x/bin/busy", resident: 3_000_000_000)
        let appHelper = swapped(52, name: "Helper", path: "/Applications/Big.app/Contents/MacOS/Helper")
        let system = swapped(53, name: "mds", path: "/System/Library/Frameworks/mds")
        let session = swapped(10, name: "claude", path: "/Users/x/.local/bin/claude")
        let tool = swapped(11, parent: 10, name: "python3", path: "/usr/local/bin/python3")
        let small = process(54, name: "small", path: "/Users/x/bin/small", footprint: 100_000_000)
        let source = FakeProcessSource(processes: [forgotten, inRAM, appHelper, system, session, tool, small])
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled, analyzers: [],
            processSource: source, telemetry: { SystemTelemetry() })
        let live = await engine.refreshLive()
        #expect(live.dormant.map(\.process.pid) == [50])
        #expect(live.dormant.first?.evidence.first?.contains("in RAM") == true)

        // Never on its own, never for an agent; for a person, after confirmation.
        _ = try await engine.update { $0.autoTerminateAbandoned = true; $0.terminateAppLeftovers = true }
        _ = await engine.automaticPass()
        #expect(source.signals.isEmpty)
        if case .denied = await engine.terminate(forgotten.identity, confirmed: true, force: false, initiator: .agent) {} else { Issue.record("agents must be denied") }
        if case .needsConfirmation = await engine.terminate(forgotten.identity, confirmed: false, force: false, initiator: .user) {} else { Issue.record("must ask first") }
        let plan = await engine.reclaimPlan()
        #expect(plan.steps.contains { $0.kind == .dormantProcesses && !$0.selectedByDefault && $0.estimatedBytes == 0 })
        if case .completed(let report) = await engine.terminate(forgotten.identity, confirmed: true, force: false, initiator: .user) {
            #expect(report.exited)
        } else {
            Issue.record("a confirmed request from a person goes through")
        }
        #expect(source.signals.map(\.pid) == [50])
    }

    @Test("Booted simulators are found from the process table and shut down only by a person; a language server whose editor is gone is ended")
    func simulatorsAndOrphanedTools() async throws {
        let f = Fixture()
        let store = try PepelStore.inMemory()
        let udid = "0A1B2C3D-1111-2222-3333-444455556666"
        let device = f.home + "/Library/Developer/CoreSimulator/Devices/\(udid)"
        try FileManager.default.createDirectory(atPath: device, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["name": "iPhone 17 Pro", "UDID": udid], format: .xml, options: 0).write(to: URL(fileURLWithPath: device + "/device.plist"))
        let launchd = process(300, name: "launchd_sim", path: "/Library/Developer/CoreSimulator/launchd_sim", args: ["launchd_sim", device + "/data/var/run/launchd_bootstrap.plist"], footprint: 50_000_000)
        let springboard = process(301, parent: 300, name: "SpringBoard", path: "/Library/Developer/CoreSimulator/Volumes/iOS/SpringBoard", footprint: 900_000_000)
        let old: UInt64 = UInt64((Date().timeIntervalSince1970 - 3600) * 1_000_000)
        let orphan = process(400, name: "sourcekit-lsp", path: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp", start: old, footprint: 700_000_000)
        let served = process(401, parent: 300, name: "gopls", path: "/Users/x/go/bin/gopls", start: old)
        let listening = process(402, name: "clangd", path: "/usr/local/bin/clangd", start: old, ports: [9000])
        let fresh = process(403, name: "gopls", path: "/Users/x/go/bin/gopls", start: UInt64(Date().timeIntervalSince1970 * 1_000_000))
        let source = FakeProcessSource(processes: [launchd, springboard, orphan, served, listening, fresh])
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled, analyzers: [],
            processSource: source, telemetry: { SystemTelemetry() })
        let live = await engine.refreshLive()
        #expect(live.simulators.map(\.name) == ["iPhone 17 Pro"] && live.simulators.first?.udid == udid)
        #expect(live.simulators.first?.footprintBytes == 1_030_000_000 && live.simulators.first?.inUse == nil, "launchd_sim, SpringBoard and the gopls inside it")
        #expect(live.orphanedTools.map(\.process.pid) == [400], "not the one with a parent, the one on a port, or the one just started")

        // Without simctl nothing is offered or done.
        #expect(await engine.reclaimPlan().steps.map(\.kind) == [.abandonedProcesses])
        let shut = PIDBox()
        await engine.setSimulatorShutdown { id in if id == udid { shut.set(1) }; return id == udid }
        let plan = await engine.reclaimPlan()
        #expect(plan.steps.map(\.kind) == [.abandonedProcesses, .simulators] && plan.defaultSelection == ["abandonedProcesses", "simulators"])
        #expect(await engine.shutdownSimulator(udid: udid, initiator: .agent).done == false)
        #expect(await engine.shutdownSimulator(udid: udid, initiator: .automatic).done == false && shut.pid == nil)
        #expect(await engine.shutdownSimulator(udid: "not-booted", initiator: .user).done == false)

        // The orphaned language server: off by default, then ended by the automatic pass.
        _ = await engine.automaticPass()
        #expect(source.signals.isEmpty)
        _ = try await engine.update { $0.autoTerminateAbandoned = true }
        _ = await engine.automaticPass()
        #expect(source.signals.map(\.pid) == [400])

        let done = await engine.reclaim(["simulators"])
        #expect(done.results.first?.done == 1 && shut.pid == 1)
    }

    @Test("A standing instruction runs only preselected steps and never one that would raise a prompt")
    func standingInstruction() async throws {
        let f = Fixture()
        let store = try PepelStore.inMemory()
        let old: UInt64 = UInt64((Date().timeIntervalSince1970 - 3600) * 1_000_000)
        let orphan = process(400, name: "gopls", path: "/Users/x/go/bin/gopls", start: old)
        let forgotten: ProcessSnapshot = {
            var p = process(50, name: "indexer", path: "/Users/x/bin/indexer", footprint: 4_000_000_000)
            p.residentBytes = 20_000_000
            return p
        }()
        let source = FakeProcessSource(processes: [orphan, forgotten])
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled, analyzers: [],
            processSource: source, telemetry: { SystemTelemetry(cachedFileBytes: 6 * Bytes.gb) })
        let flushes = FlushCounter()
        await engine.setFileCacheFlusher(FileCacheFlusher(isAvailable: true, hasPermission: { false }, flush: { flushes.bump(); return .flushed }))
        let first = await engine.reclaimOnStandingInstruction(trigger: "screen locked")
        #expect(first?.results.map(\.kind) == [.abandonedProcesses], "the cache flush would prompt; the process living in swap is not preselected")
        #expect(source.signals.map(\.pid) == [400] && flushes.count == 0)
        #expect(store.audit(kinds: [.termination]).contains { $0.subject == "Free memory, standing instruction" && $0.outcome == "screen locked" })

        // With the permission in place the flush is part of it; with nothing to do, nothing runs.
        await engine.setFileCacheFlusher(FileCacheFlusher(isAvailable: true, hasPermission: { true }, flush: { flushes.bump(); return .flushed }))
        let second = await engine.reclaimOnStandingInstruction(trigger: "notification")
        #expect(second?.results.map(\.kind) == [.fileCache] && flushes.count == 1)
        await engine.setFileCacheFlusher(.unavailable)
        #expect(await engine.reclaimOnStandingInstruction(trigger: "notification") == nil)
        #expect(source.snapshot().map(\.pid) == [50])
    }

    @Test("A memory budget only raises an alert; a budget by name wins over one for the kind")
    func memoryBudgets() async throws {
        let f = Fixture()
        let store = try PepelStore.inMemory()
        func app(_ pid: Int32, _ name: String, gib: Int64) -> ProcessSnapshot {
            process(pid, name: name, path: "/Applications/\(name).app/Contents/MacOS/\(name)", footprint: gib << 30)
        }
        let source = FakeProcessSource(processes: [app(1, "Browser", gib: 6), app(2, "Editor", gib: 3), app(3, "Notes", gib: 1)])
        var settings = PepelSettings()
        settings.memoryBudgets = [MemoryBudget(match: "kind:application", bytes: 2 << 30), MemoryBudget(match: "browser", bytes: 8 << 30)]
        try store.saveSettings(settings)
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled, analyzers: [],
            processSource: source, telemetry: { SystemTelemetry() })
        let live = await engine.refreshLive()
        #expect(live.overBudget.map(\.name) == ["Editor"], "Browser has its own, larger budget; Notes is within the kind's")
        #expect(live.overBudget.first?.excessBytes == 1 << 30)
        let alerts = await engine.alerts()
        #expect(alerts.contains { $0.id == "memory-budget-app:/Applications/Editor.app" && $0.severity == .warning })
        _ = await engine.automaticPass()
        #expect(source.signals.isEmpty && source.snapshot().count == 3, "a budget never ends anything")
    }

    @Test("Inside an agent's server only an older, idle copy of a program is marked, and it is ended only when a person asks")
    func serviceBranches() async throws {
        let f = Fixture()
        let store = try PepelStore.inMemory()
        let now = Date()
        func micro(_ hoursAgo: Double) -> UInt64 { UInt64((now.timeIntervalSince1970 - hoursAgo * 3600) * 1_000_000) }
        let server = process(500, name: "codex", path: "/Applications/ChatGPT.app/Contents/Resources/codex", args: ["codex", "app-server"], start: micro(30))
        func tool(_ pid: Int32, _ script: String, hoursAgo: Double, cpu: UInt64 = 0) -> ProcessSnapshot {
            process(pid, parent: 500, name: "node", path: "/usr/local/bin/node", args: ["node", "/opt/tools/\(script)"], start: micro(hoursAgo), cpu: cpu, footprint: 300_000_000)
        }
        let oldest = tool(510, "search.js", hoursAgo: 20)
        let oldestChild = process(511, parent: 510, name: "rg", path: "/usr/local/bin/rg", start: micro(20), footprint: 50_000_000)
        let older = tool(520, "search.js", hoursAgo: 10)
        let newest = tool(530, "search.js", hoursAgo: 1)
        let only = tool(540, "files.js", hoursAgo: 20)
        // Another program in two copies; the older one has been working.
        let busyOld = tool(550, "build.js", hoursAgo: 9, cpu: 600 * 1_000_000_000)
        let busyNew = tool(560, "build.js", hoursAgo: 2)
        let all = [server, oldest, oldestChild, older, newest, only, busyOld, busyNew]
        // Three hours of readings: nothing used CPU except the old build tool.
        for hoursAgo in [3.0, 2, 1, 0.1] {
            store.recordObservations(all.map { p in var copy = p; copy.cpuTimeNs = p.pid == 550 ? UInt64((3 - hoursAgo) * 200) * 1_000_000_000 : 0; return copy }, at: now.addingTimeInterval(-hoursAgo * 3600))
        }
        let source = FakeProcessSource(processes: all)
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled, analyzers: [],
            processSource: source, telemetry: { SystemTelemetry() })
        let live = await engine.refreshLive()
        #expect(live.serviceBranches.count == 6)
        #expect(Set(live.serviceBranches.filter(\.isStale).map(\.root.pid)) == [510, 520], "not the newest copy, the only copy, or the copy that is working")
        #expect(live.serviceBranches.first { $0.root.pid == 510 }?.footprintBytes == 350_000_000)
        #expect(live.agentSessions.first?.isService == true)

        _ = try await engine.update { $0.autoTerminateAbandoned = true; $0.terminateSleepingAgents = true }
        _ = await engine.automaticPass()
        #expect(source.signals.isEmpty, "never on its own")
        if case .denied = await engine.terminate(oldest.identity, confirmed: true, force: false, initiator: .agent) {} else { Issue.record("agents must be denied") }
        if case .completed = await engine.terminate(newest.identity, confirmed: true, force: false, initiator: .user) { Issue.record("the newest copy is not PEPEL's to end") }
        let plan = await engine.reclaimPlan()
        #expect(plan.steps.contains { $0.kind == .serviceBranches && !$0.selectedByDefault && $0.estimatedBytes == 650_000_000 })
        _ = await engine.reclaim(["serviceBranches"])
        #expect(Set(source.signals.map(\.pid)) == [510, 511, 520], "each old copy with what it started")
        #expect(Set(source.snapshot().map(\.pid)) == [500, 530, 540, 550, 560])
    }

    @Test("Only idle tab processes of a real browser are offered for unloading, and only a person can unload them")
    func browserTabs() async throws {
        let f = Fixture()
        let store = try PepelStore.inMemory()
        let now = Date()
        let helper = "/Applications/Dia.app/Contents/Frameworks/Core.framework/Helpers/Browser Helper"
        func renderer(_ pid: Int32, path: String = helper, extra: [String] = [], mb: Int64 = 400, cpu: UInt64 = 0) -> ProcessSnapshot {
            process(pid, parent: 600, name: "Browser Helper", path: path, args: [path, "--type=renderer"] + extra, cpu: cpu * 1_000_000_000, footprint: mb * 1_000_000)
        }
        let main = process(600, name: "Dia", path: "/Applications/Dia.app/Contents/MacOS/Dia", footprint: 600_000_000)
        let idle = renderer(601)
        let busy = renderer(602, cpu: 300)
        let small = renderer(603, mb: 40)
        let extensionHost = renderer(604, extra: ["--extension-process"])
        let gpu = process(605, parent: 600, name: "Browser Helper", path: helper, args: [helper, "--type=gpu-process"], footprint: 500_000_000)
        let electron = renderer(606, path: "/Applications/Notes.app/Contents/Frameworks/Notes Helper.app/Contents/MacOS/Notes Helper")
        let unwatched = renderer(607)
        let all = [main, idle, busy, small, extensionHost, gpu, electron, unwatched]
        for minutesAgo in [90.0, 60, 30, 1] {
            store.recordObservations(all.filter { $0.pid != 607 }.map { p in var copy = p; copy.cpuTimeNs = 0; return copy }, at: now.addingTimeInterval(-minutesAgo * 60))
        }
        let source = FakeProcessSource(processes: all)
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled, analyzers: [],
            processSource: source, telemetry: { SystemTelemetry() })
        let live = await engine.refreshLive()
        #expect(Set(live.browserTabs.map(\.root.pid)) == [601, 602, 607], "not the small one, the extension host, the GPU process or an Electron application")
        #expect(live.idleTabs.map(\.process.pid) == [601], "602 used CPU; 607 has not been watched long enough")
        #expect(live.dormant.isEmpty && live.browserTabs.first?.browser == "Dia")

        _ = try await engine.update { $0.autoTerminateAbandoned = true }
        _ = await engine.automaticPass()
        #expect(source.signals.isEmpty)
        if case .denied = await engine.terminate(idle.identity, confirmed: true, force: false, initiator: .agent) {} else { Issue.record("agents must be denied") }
        if case .needsConfirmation = await engine.terminate(idle.identity, confirmed: false, force: false, initiator: .user) {} else { Issue.record("must ask first") }
        let plan = await engine.reclaimPlan()
        #expect(plan.steps.contains { $0.kind == .browserTabs && !$0.selectedByDefault && $0.estimatedBytes == 400_000_000 })
        _ = await engine.reclaim(["browserTabs"])
        #expect(source.signals.map(\.pid) == [601] && source.snapshot().count == 7)
    }

    @Test("Only system components macOS brings back by itself can be restarted, and only when a person asks")
    func systemProcesses() async throws {
        let f = Fixture()
        let store = try PepelStore.inMemory()
        let chronod = process(700, name: "chronod", path: "/System/Library/PrivateFrameworks/ChronoCore.framework/Support/chronod", footprint: 800_000_000)
        let web = process(701, name: "com.apple.WebKit.WebContent", path: "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent", footprint: 900_000_000)
        let dock = process(702, name: "Dock", path: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock", footprint: 80_000_000)
        let impostor = process(703, name: "Finder", path: "/Users/x/bin/Finder", footprint: 900_000_000)
        let other = process(704, name: "chronod", path: "/System/Library/PrivateFrameworks/ChronoCore.framework/Support/chronod", footprint: 900_000_000, uid: getuid() + 1)
        let source = FakeProcessSource(processes: [chronod, web, dock, impostor, other])
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled, analyzers: [],
            processSource: source, telemetry: { SystemTelemetry() })
        let live = await engine.refreshLive()
        #expect(live.systemProcesses.map(\.root.pid) == [700, 701], "restartable first; not the small Dock, a program merely named Finder, or another user's process")
        #expect(live.restartableSystem.map(\.process.pid) == [700])

        _ = try await engine.update { $0.autoTerminateAbandoned = true }
        _ = await engine.automaticPass()
        #expect(source.signals.isEmpty)
        if case .completed = await engine.terminate(web.identity, confirmed: true, force: false, initiator: .user) { Issue.record("web content is not PEPEL's to end") }
        if case .denied = await engine.terminate(chronod.identity, confirmed: true, force: false, initiator: .agent) {} else { Issue.record("agents must be denied") }
        if case .needsConfirmation = await engine.terminate(chronod.identity, confirmed: false, force: false, initiator: .cli) {} else { Issue.record("must ask first") }
        let plan = await engine.reclaimPlan()
        #expect(plan.steps.contains { $0.kind == .systemProcesses && !$0.selectedByDefault })
        if case .completed(let report) = await engine.terminate(chronod.identity, confirmed: true, force: false, initiator: .cli) { #expect(report.exited) } else { Issue.record("a person's confirmed request goes through") }
        #expect(source.signals.map(\.pid) == [700])
    }

    @Test("A forecast is made only from a steady rise that reaches the threshold soon; noise, a level line and a far-off date give none")
    func memoryForecast() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let total: Int64 = 64 << 30
        func samples(_ gib: [Double], everyMinutes: Double = 5) -> [MemorySample] {
            gib.enumerated().map { MemorySample(at: now.addingTimeInterval(-Double(gib.count - 1 - $0.offset) * everyMinutes * 60), bytes: Int64($0.element * Double(1 << 30))) }
        }
        // 2 GiB every five minutes from 40 GiB: 57.6 GiB (90%) is 3.6 GiB, nine minutes, away.
        let rising = try #require(MemoryForecast.project(samples: samples([40, 42, 44, 46, 48, 50, 52, 54]), totalBytes: total, now: now))
        #expect(abs(rising.reachesAt.timeIntervalSince(now) - 9 * 60) < 30)
        #expect(abs(Double(rising.perHourBytes) / Double(1 << 30) - 24) < 0.5)
        #expect(MemoryForecast.project(samples: samples([40, 40.1, 39.9, 40, 40.1, 40, 39.9, 40]), totalBytes: total, now: now) == nil, "level")
        #expect(MemoryForecast.project(samples: samples([40, 48, 39, 47, 41, 49, 40, 46]), totalBytes: total, now: now) == nil, "noise")
        #expect(MemoryForecast.project(samples: samples([20, 20.3, 20.6, 20.9, 21.2, 21.5, 21.8, 22.1]), totalBytes: total, now: now) == nil, "ten hours away")
        #expect(MemoryForecast.project(samples: samples([50, 52, 54]), totalBytes: total, now: now) == nil, "too few readings")
        #expect(MemoryForecast.project(samples: samples([58, 59, 60, 61, 62, 63]), totalBytes: total, now: now) == nil, "already past the threshold")

        // In the engine: readings from the store plus the current one; the alert carries the Free memory button.
        let f = Fixture()
        let store = try PepelStore.inMemory()
        let live0 = Date()
        for (index, gib) in [40.0, 42, 44, 46, 48, 50, 52].enumerated() {
            store.recordTelemetry(
                SystemTelemetry(timestamp: live0.addingTimeInterval(-Double(7 - index) * 300), memoryTotalBytes: total, appMemoryBytes: Int64(gib * Double(1 << 30))), reclaimable: nil)
        }
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled, analyzers: [],
            processSource: FakeProcessSource(processes: []), telemetry: { SystemTelemetry(memoryTotalBytes: total, appMemoryBytes: 54 << 30) })
        let live = await engine.refreshLive()
        #expect(live.forecast != nil)
        #expect(await engine.alerts().contains { $0.id.hasPrefix("memory-forecast-") && $0.severity == .warning })
        _ = try await engine.update { $0.forecastWarnMinutes = 0 }
        #expect(await engine.alerts().contains { $0.id.hasPrefix("memory-forecast-") } == false)
    }

    @Test("Swap on disk is read from the swap directory and explained by how much of it is in use")
    func swapOnDisk() throws {
        let f = Fixture()
        let directory = f.root + "/vm"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for name in ["swapfile0", "swapfile1", "sleepimage", "kernelcore"] {
            try Data(count: 1 << 20).write(to: URL(fileURLWithPath: directory + "/" + name))
        }
        try FileManager.default.createSymbolicLink(atPath: directory + "/swapfile9", withDestinationPath: "/etc/hosts")
        let report = SwapReport.read(directory: directory, usedBytes: 100_000)
        #expect(report.fileCount == 2, "two swap files; the link and the other files are not counted")
        #expect(report.onDiskBytes >= 2 << 20 && report.onDiskBytes < 4 << 20 && report.sleepImageBytes >= 1 << 20)
        #expect(report.oldestFile != nil)

        let empty = SwapReport(fileCount: 0, onDiskBytes: 0, usedBytes: 0, sleepImageBytes: 0, oldestFile: nil)
        #expect(empty.explanation.contains("no swap files"))
        let mostlyEmpty = SwapReport(fileCount: 6, onDiskBytes: 6 * Bytes.gb, usedBytes: 500 * Bytes.mb, sleepImageBytes: 0, oldestFile: nil)
        #expect(mostlyEmpty.slackBytes == 6 * Bytes.gb - 500 * Bytes.mb && mostlyEmpty.explanation.contains("Most of it is empty"))
        let heavy = SwapReport(fileCount: 6, onDiskBytes: 6 * Bytes.gb, usedBytes: 5 * Bytes.gb, sleepImageBytes: 2 * Bytes.gb, oldestFile: nil)
        #expect(heavy.explanation.contains("memory was short") && heavy.explanation.contains("hibernation image"))
        #expect(SwapReport.read(directory: f.root + "/missing", usedBytes: 0).fileCount == 0)
    }

    @Test("The daily summary says what the audit log recorded in the period, and nothing from outside it")
    func dailySummary() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func entry(_ kind: AuditKind, _ subject: String, _ outcome: String, hoursAgo: Double, initiator: String = "user", bytes: Int64 = 0) -> AuditEntry {
            var e = AuditEntry(kind: kind, initiator: initiator, subject: subject, outcome: outcome, bytes: bytes)
            e.timestamp = now.addingTimeInterval(-hoursAgo * 3600)
            return e
        }
        let audit = [
            entry(.termination, "node (PID 1)", "terminated", hoursAgo: 2, initiator: "automatic"),
            entry(.termination, "claude (PID 2)", "terminated", hoursAgo: 3),
            entry(.termination, "Claude Code (PID 3)", "suspended", hoursAgo: 4, initiator: "automatic"),
            entry(.termination, "Claude Code (PID 3)", "woken", hoursAgo: 3, initiator: "engine"),
            entry(.termination, "Browser", "restarted", hoursAgo: 5, bytes: 3 * Bytes.gb),
            entry(.termination, "Free memory", "memory used 40 GB → 38 GB", hoursAgo: 6, bytes: 2 * Bytes.gb),
            entry(.container, "Docker Desktop VM memory", "measured", hoursAgo: 7, bytes: 20 * Bytes.gb),
            entry(.container, "app (3 containers)", "stopped", hoursAgo: 8, initiator: "automatic"),
            entry(.cleanup, "~/Library/Caches/x", "removed", hoursAgo: 9, bytes: 5 * Bytes.gb),
            entry(.scan, "storage scan", "248 items", hoursAgo: 1),
            entry(.termination, "old (PID 9)", "terminated", hoursAgo: 30),
        ]
        let summary = DailySummary.make(audit: audit, open: ["1 application is open but unused, holding 2 GB."], from: now.addingTimeInterval(-86_400), to: now)
        #expect(summary.memoryFreedBytes == 22 * Bytes.gb && summary.diskFreedBytes == 5 * Bytes.gb)
        #expect(summary.done.contains("Ended 2 processes, 1 of them by PEPEL's own rules."), "the one from 30 hours ago is not counted")
        #expect(summary.done.contains("Suspended agent sessions 1 time and woke them 1 time.") && summary.done.contains("Restarted Browser."))
        #expect(summary.done.contains { $0.hasPrefix("Restarted the Docker VM 1 time") } && summary.done.contains("Stopped the containers of 1 project."))
        #expect(summary.done.count == 7 && summary.open.count == 1)
        let quiet = DailySummary.make(audit: [entry(.scan, "storage scan", "248 items", hoursAgo: 1)], open: [], from: now.addingTimeInterval(-86_400), to: now)
        #expect(quiet.done.isEmpty && quiet.headline == "PEPEL did not need to do anything.")
    }

    @Test("The journal records a reading every five minutes with agents, browsers and actions, only when asked to, and prunes old days")
    func memoryJournal() async throws {
        let f = Fixture()
        let store = try PepelStore.inMemory()
        let alpha = f.gitRepo(f.projects + "/alpha")
        let helper = "/Applications/Dia.app/Contents/Frameworks/Core.framework/Helpers/Browser Helper"
        let browser = process(600, name: "Dia", path: "/Applications/Dia.app/Contents/MacOS/Dia", footprint: 600_000_000)
        let tab = process(601, parent: 600, name: "Browser Helper", path: helper, args: [helper, "--type=renderer"], footprint: 400_000_000)
        let session = process(10, name: "claude", path: "/Users/x/.local/bin/claude", args: ["claude", "--api-key", "sk-secret"], cwd: alpha, footprint: 300_000_000)
        let source = FakeProcessSource(processes: [browser, tab, session])
        var settings = PepelSettings()
        settings.projectRoots = [f.projects]
        try store.saveSettings(settings)
        let paths = AppPaths(home: f.home, supportDirectory: f.root + "/support")
        let engine = try PepelEngine(
            paths: paths, store: store, tools: .disabled, analyzers: [], processSource: source,
            telemetry: { SystemTelemetry(memoryTotalBytes: 64 << 30, appMemoryBytes: 20 << 30, wiredBytes: 8 << 30, compressedBytes: 4 << 30, swapUsedBytes: 2 << 30) })
        let journal = engine.journal
        let start = Date()

        // A one-off command does not add readings.
        await engine.refreshLive(now: start)
        try await Task.sleep(for: .milliseconds(150))
        #expect(journal.files().isEmpty)

        await engine.setJournaling(true)
        store.appendAudit(AuditEntry(kind: .termination, initiator: "automatic", subject: "node (PID 9)", outcome: "terminated"))
        await engine.refreshLive(now: start.addingTimeInterval(1))
        await engine.refreshLive(now: start.addingTimeInterval(60))  // too soon for a second reading
        await engine.refreshLive(now: start.addingTimeInterval(301))
        try await Task.sleep(for: .milliseconds(300))
        let readings = journal.read(since: start.addingTimeInterval(-10))
        #expect(readings.count == 2)
        let first = try #require(readings.first)
        #expect(first.wired == 8 << 30 && first.used == 32 << 30 && first.swap == 2 << 30 && first.pressure == "normal")
        #expect(first.agents.map(\.agent) == ["Claude Code"] && first.agents.first?.project == "alpha" && first.agents.first?.bytes == 300_000_000)
        #expect(first.browsers.map(\.name) == ["Dia"] && first.browsers.first?.bytes == 1_000_000_000 && first.browsers.first?.tabs == 1)
        #expect(first.actions.map(\.outcome) == ["terminated"] && readings[1].actions.isEmpty, "an action appears in the reading after it, once")
        let raw = try String(contentsOfFile: journal.path(for: first.ts), encoding: .utf8)
        #expect(!raw.contains("sk-secret") && !raw.contains(alpha), "names only: no command lines, no paths")
        let mode = try FileManager.default.attributesOfItem(atPath: journal.path(for: first.ts))[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)

        // Switched off: nothing more is written.
        _ = try await engine.update { $0.journalEnabled = false }
        await engine.refreshLive(now: start.addingTimeInterval(700))
        try await Task.sleep(for: .milliseconds(150))
        #expect(journal.read(since: start.addingTimeInterval(-10)).count == 2)

        // Old days go; a file the journal did not write stays.
        let old = JournalSample(ts: start.addingTimeInterval(-40 * 86_400), total: 1, used: 1, app: 1, wired: 1, compressed: 0, cached: 0, free: 0, swap: 0, pressure: "normal", owners: [], agents: [], browsers: [], counts: [:], forecastMinutes: nil, actions: [])
        #expect(journal.append(old))
        try Data("keep".utf8).write(to: URL(fileURLWithPath: journal.directory + "/notes.txt"))
        #expect(journal.files().count == 2)
        journal.prune(keepDays: 30, now: start)
        #expect(journal.files().count == 1 && FileManager.default.fileExists(atPath: journal.directory + "/notes.txt"))
    }

    @Test("The digest reads ranges, shares and per-holder figures out of the journal")
    func journalDigest() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func sample(_ index: Int, used: Int64, wired: Int64, pressure: String, sessions: [(String, String, Bool, Int64)], dia: Int64?, action: String? = nil) -> JournalSample {
            JournalSample(
                ts: start.addingTimeInterval(Double(index) * 300), total: 64, used: used, app: used, wired: wired, compressed: 0, cached: 0, free: 0, swap: Int64(index), pressure: pressure,
                owners: [JournalSample.Owner(name: "Dia", kind: "application", bytes: dia ?? 0, resident: 0, procs: 1)].filter { _ in dia != nil },
                agents: sessions.map { JournalSample.Agent(agent: "Claude Code", project: $0.0, pid: 1, state: $0.1, suspended: $0.2, bytes: $0.3, resident: 0, procs: 1, quietMinutes: nil, ageMinutes: 1) },
                browsers: dia.map { [JournalSample.Browser(name: "Dia", bytes: $0, resident: 0, procs: 3, tabs: 4, idleTabs: 1, idleBytes: 100, largestTab: 50)] } ?? [],
                counts: [:], forecastMinutes: index == 2 ? 30 : nil,
                actions: action.map { [JournalSample.Action(at: start, by: "automatic", subject: "x", outcome: $0, bytes: 0)] } ?? [])
        }
        let digest = JournalDigest.make([
            sample(0, used: 30, wired: 8, pressure: "normal", sessions: [("a", "working", false, 10), ("a", "idle", false, 20)], dia: 100),
            sample(1, used: 40, wired: 9, pressure: "normal", sessions: [("a", "idle", true, 30)], dia: 200, action: "suspended"),
            sample(2, used: 50, wired: 10, pressure: "elevated", sessions: [("b", "sleeping", false, 5)], dia: 300, action: "suspended"),
            sample(3, used: 44, wired: 11, pressure: "normal", sessions: [], dia: nil),
        ])
        #expect(digest.samples == 4 && digest.used == JournalDigest.Range(min: 30, average: 41, max: 50) && digest.wired.max == 11 && digest.swap.max == 3)
        #expect(digest.pressure == ["normal": 0.75, "elevated": 0.25])
        #expect(digest.agentSessions == JournalDigest.Range(min: 0, average: 1, max: 2) && digest.agentMemory.max == 30)
        #expect(digest.agentStates == ["working": 0.25, "idle": 0.25, "suspended": 0.25, "sleeping": 0.25])
        let a = digest.agents.first { $0.name == "Claude Code · a" }
        #expect(a?.memory == JournalDigest.Range(min: 30, average: 30, max: 30) && a?.presence == 0.5, "two sessions in one project count together")
        let dia = digest.browsers.first
        #expect(dia?.memory == JournalDigest.Range(min: 100, average: 200, max: 300) && dia?.change == 200 && dia?.presence == 0.75)
        #expect(digest.actions == ["suspended": 2] && digest.forecasts == 1 && digest.browserTabs.max == 4)
        #expect(JournalDigest.make([]).samples == 0)
    }

    @Test("Two PEPEL processes on one store see each other's settings and do not overwrite them")
    func sharedSettings() async throws {
        let f = Fixture()
        let store = try PepelStore.inMemory()
        let paths = AppPaths(home: f.home, supportDirectory: f.root + "/support")
        func make() throws -> PepelEngine {
            try PepelEngine(paths: paths, store: store, tools: .disabled, analyzers: [], processSource: FakeProcessSource(processes: []), telemetry: { SystemTelemetry() })
        }
        let app = try make(), cli = try make()
        _ = try await cli.update { $0.trimCaches = true }
        #expect(await app.currentSettings().trimCaches == false, "not yet sampled")
        await app.refreshLive()
        #expect(await app.currentSettings().trimCaches == true, "the running app adopts what the command line saved")
        // A change in the app does not undo the one made on the command line meanwhile.
        _ = try await cli.update { $0.cacheUnusedDays = 10 }
        _ = try await app.update { $0.logDays = 3 }
        let final = store.loadSettings(home: f.home)
        #expect(final.cacheUnusedDays == 10 && final.logDays == 3 && final.trimCaches)
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
