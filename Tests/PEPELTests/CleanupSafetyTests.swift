import Foundation
import Testing
@testable import PEPELCleanup
@testable import PEPELEngine

@Suite("Cleanup policy and executor")
struct CleanupSafetyTests {
    let engine = CleanupPolicyEngine()

    // MARK: Policy enforcement

    @Test("Safe items are allowed, review items need confirmation, protected items are denied")
    func classificationDrivesVerdict() {
        let f = Fixture()
        let context = f.policyContext()
        #expect(engine.evaluate(f.item(f.projects + "/app/.pytest_cache", safety: .safe), initiator: .user, context: context).verdict == .allowed)
        #expect(engine.evaluate(f.item(f.projects + "/app/.venv", safety: .review), initiator: .user, context: context).verdict == .needsConfirmation)
        #expect(engine.evaluate(f.item(f.projects + "/app/models", safety: .protected), initiator: .user, context: context).verdict == .denied)
    }

    @Test("Paths that must never be removed are denied even when an analyzer calls them safe", arguments: [
        ".ssh/cache", ".gnupg/tmp", ".aws/cache", ".claude/projects", ".codex/sessions", ".ollama/models",
        "Library/Application Support/SomeApp", "Library/Keychains/x", "projects/app/.git/objects",
    ])
    func forbiddenLocations(relative: String) {
        let f = Fixture()
        let item = f.item(f.home + "/" + relative, safety: .safe)
        let decision = engine.evaluate(item, initiator: .user, context: f.policyContext())
        #expect(decision.verdict == .denied, "\(relative) must be denied: \(decision.reasons)")
    }

    @Test("Source code is never removable: project roots, their parents, and git working trees")
    func sourceCodeIsProtected() {
        let f = Fixture()
        let repo = f.gitRepo(f.projects + "/app")
        f.file(repo + "/main.swift")
        let roots = [repo]
        for path in [repo, f.projects, f.home] {
            let item = f.item(path, safety: .safe)
            #expect(engine.evaluate(item, initiator: .user, context: f.policyContext(projectRoots: roots)).verdict == .denied, "\(path)")
        }
        // Even without knowing the project, a directory containing `.git` is refused.
        #expect(engine.pathViolation(repo, context: f.policyContext()) != nil)
    }

    @Test("Paths outside the home directory and temporary folders are refused")
    func outsideManagedAreas() {
        let f = Fixture()
        for path in ["/usr/local", "/Applications", "/", "relative/path", f.home + "/projects/../.."] {
            #expect(engine.pathViolation(path, context: f.policyContext()) != nil, "\(path)")
        }
    }

    @Test("Automatic cleanup only touches safe items, and only when the user enabled it")
    func automaticInitiator() {
        let f = Fixture()
        let safe = f.item(f.projects + "/app/.ruff_cache", safety: .safe)
        let review = f.item(f.projects + "/app/node_modules", safety: .review)
        #expect(engine.evaluate(safe, initiator: .automatic, context: f.policyContext()).verdict == .denied)
        var settings = PepelSettings()
        settings.monitoringMode = .automaticSafe
        #expect(engine.evaluate(safe, initiator: .automatic, context: f.policyContext(settings: settings)).verdict == .allowed)
        #expect(engine.evaluate(review, initiator: .automatic, context: f.policyContext(settings: settings)).verdict == .denied)
        settings.paused = true
        #expect(engine.evaluate(safe, initiator: .automatic, context: f.policyContext(settings: settings)).verdict == .denied)
    }

    @Test("Agents can preview but never obtain an executable approval")
    func agentsCannotClean() {
        let f = Fixture()
        let item = f.item(f.projects + "/app/.pytest_cache", safety: .safe)
        let plan = engine.plan(items: [item], initiator: .agent, context: f.policyContext())
        #expect(plan.decisions.first?.verdict == .denied)
        #expect(engine.approve(plan, confirmed: [item.id], context: f.policyContext()).isEmpty)
    }

    @Test("Protection rules, pins and excluded projects block cleanup")
    func protectionRules() {
        let f = Fixture()
        let project = f.projects + "/app"
        let item = f.item(project + "/.build/debug", safety: .safe, category: .buildOutput, projectID: project)
        for rule in [
            ProtectionRule(kind: .path, value: project + "/.build"), ProtectionRule(kind: .pin, value: item.path),
            ProtectionRule(kind: .project, value: project),
        ] {
            #expect(engine.evaluate(item, initiator: .user, context: f.policyContext(protections: [rule])).verdict == .denied, "\(rule.kind)")
        }
    }

    @Test("Items in use or written moments ago are denied")
    func activeBuildProtection() {
        let f = Fixture()
        let item = f.item(f.projects + "/app/.build/debug", safety: .safe, category: .buildOutput)
        let busy = engine.evaluate(item, initiator: .user, context: f.policyContext(usage: [item.id: "swift-build (PID 4242) is running in this project."]))
        #expect(busy.verdict == .denied)
        #expect(busy.reasons.contains { $0.contains("In use") })

        let fresh = f.item(f.projects + "/app/.build/release", safety: .safe, category: .buildOutput, ageHours: 0.01)
        let decision = engine.evaluate(fresh, initiator: .user, context: f.policyContext())
        #expect(decision.verdict == .denied)
        #expect(decision.reasons.contains { $0.contains("may still be being written") })
    }

    // MARK: Leases

    @Test("An active lease blocks cleanup; an expired or released one does not, and never makes anything safe")
    func leaseLifecycle() {
        let f = Fixture()
        let item = f.item(f.projects + "/app/.build/debug", safety: .review, category: .buildOutput)
        let now = Date()
        let active = ResourceLease(owner: "codex", path: f.projects + "/app/.build", expiresAt: now.addingTimeInterval(600))
        let expired = ResourceLease(owner: "codex", path: f.projects + "/app/.build", createdAt: now.addingTimeInterval(-7200), expiresAt: now.addingTimeInterval(-60))
        var released = active
        released.releasedAt = now

        #expect(engine.evaluate(item, initiator: .user, context: f.policyContext(leases: [active])).verdict == .denied)
        // After expiry the item is judged on its own merits again: still review, not silently safe.
        #expect(engine.evaluate(item, initiator: .user, context: f.policyContext(leases: [expired])).verdict == .needsConfirmation)
        #expect(engine.evaluate(item, initiator: .user, context: f.policyContext(leases: [released])).verdict == .needsConfirmation)
        // …and usage found by revalidation still wins over an expired lease.
        #expect(engine.evaluate(item, initiator: .user, context: f.policyContext(leases: [expired], usage: [item.id: "in use"])).verdict == .denied)
        var settings = PepelSettings()
        settings.monitoringMode = .automaticSafe
        #expect(engine.evaluate(item, initiator: .automatic, context: f.policyContext(settings: settings, leases: [expired])).verdict == .denied)
    }

    // MARK: Agent session protection

    @Test("A running agent session in a project blocks automatic cleanup and forces confirmation for manual cleanup")
    func agentSessionProtection() {
        let f = Fixture()
        let project = f.projects + "/app"
        let item = f.item(project + "/.build/debug", safety: .safe, category: .buildOutput, projectID: project)
        let session = AgentSession(
            kind: .claudeCode, root: ProcessIdentity(pid: 500, startTime: 1), workingDirectory: project, projectID: project,
            projectConfidence: .verified, processCount: 3, footprintBytes: 1, activeBuildCount: 0, recentlyActive: true, startedAt: Date())
        var settings = PepelSettings()
        settings.monitoringMode = .automaticSafe
        #expect(engine.evaluate(item, initiator: .automatic, context: f.policyContext(settings: settings, sessions: [session])).verdict == .denied)
        let manual = engine.evaluate(item, initiator: .user, context: f.policyContext(sessions: [session]))
        #expect(manual.verdict == .needsConfirmation)
        #expect(manual.reasons.contains { $0.contains("Claude Code") })
    }

    // MARK: Dry run and real removal

    @Test("A dry run reports what would happen and removes nothing")
    func dryRunRemovesNothing() async {
        let f = Fixture()
        let store = try! PepelStore.inMemory()
        let item = f.item(f.projects + "/app/.pytest_cache", safety: .safe)
        let context = f.policyContext()
        let approved = engine.approve(engine.plan(items: [item], initiator: .user, context: context), confirmed: [], context: context)
        let report = await CleanupExecutor(store: store, tools: .disabled).run(approved, dryRun: true, context: context)
        #expect(report.outcomes.map(\.status) == [.wouldApply])
        #expect(PathUtil.exists(item.path + "/data.bin"))
        #expect(store.audit().first?.kind == .cleanupPreview)
    }

    @Test("Approved safe items are removed and the action is audited; review items go to the Trash only when confirmed")
    func realRemoval() async {
        let f = Fixture()
        let store = try! PepelStore.inMemory()
        let safe = f.item(f.projects + "/app/.pytest_cache", safety: .safe)
        let review = f.item(f.projects + "/app/.tox", safety: .review)
        let context = f.policyContext()
        let plan = engine.plan(items: [safe, review], initiator: .user, context: context)

        // Nothing confirmed: only the safe item is approved.
        let approved = engine.approve(plan, confirmed: [], context: context)
        #expect(approved.map(\.id) == [safe.id])
        let report = await CleanupExecutor(store: store, tools: .disabled).run(approved, dryRun: false, context: context)
        #expect(report.outcomes.first?.status == .removed)
        #expect(!PathUtil.exists(safe.path))
        #expect(PathUtil.exists(review.path))
        let entry = store.audit().first
        #expect(entry?.kind == .cleanup && entry?.outcome == "removed")
        // No tombstone is left behind next to the removed directory.
        #expect(PathUtil.list(f.projects + "/app")?.contains { $0.hasPrefix(".pepel-removing") } == false)
    }

    @Test("Permanent deletion mode and Trash mode choose the matching action")
    func deletionModes() {
        let f = Fixture()
        let safe = f.item(f.projects + "/app/.mypy_cache", safety: .safe)
        let review = f.item(f.projects + "/app/.tox", safety: .review)
        var settings = PepelSettings()
        #expect(engine.evaluate(safe, initiator: .user, context: f.policyContext(settings: settings)).action == .removePermanently)
        #expect(engine.evaluate(review, initiator: .user, context: f.policyContext(settings: settings)).action == .trash)
        settings.deletionMode = .trash
        #expect(engine.evaluate(safe, initiator: .user, context: f.policyContext(settings: settings)).action == .trash)
        settings.deletionMode = .permanent
        let decision = engine.evaluate(review, initiator: .user, context: f.policyContext(settings: settings))
        #expect(decision.action == .removePermanently)
        #expect(decision.warnings.contains("This cannot be undone."))
    }

    // MARK: Symlinks

    @Test("A symbolic link is never accepted as a cleanup target")
    func symlinkTargetsAreRefused() {
        let f = Fixture()
        let precious = f.dir(f.home + "/precious")
        f.file(precious + "/thesis.txt")
        f.dir(f.projects + "/app")
        let link = f.projects + "/app/.pytest_cache"
        symlink(precious, link)
        let item = StorageItem(
            analyzerID: "test", category: .toolCache, path: link, title: "link", explanation: "", safety: .safe, safetyReason: "",
            reproducible: true, identity: PathUtil.identity(link))
        let decision = engine.evaluate(item, initiator: .user, context: f.policyContext())
        #expect(decision.verdict == .denied)
        #expect(decision.reasons.contains { $0.contains("symbolic link") })
    }

    @Test("A path reached through a symlinked parent is refused")
    func symlinkedParentIsRefused() {
        let f = Fixture()
        let real = f.dir(f.home + "/elsewhere/cache")
        f.file(real + "/x")
        f.dir(f.projects)
        symlink(f.home + "/elsewhere", f.projects + "/alias")
        #expect(engine.pathViolation(f.projects + "/alias/cache", context: f.policyContext())?.contains("symbolic link") == true)
    }

    @Test("Removing a directory removes links inside it without following them")
    func linksInsideAreNotFollowed() async {
        let f = Fixture()
        let precious = f.file(f.home + "/precious/thesis.txt")
        let item = f.item(f.projects + "/app/.pytest_cache", safety: .safe)
        symlink((precious as NSString).deletingLastPathComponent, item.path + "/escape")
        f.age(item.path, hours: 72)
        var rescanned = item
        rescanned.size = DirectorySizer().measure(item.path)
        let context = f.policyContext()
        let approved = engine.approve(engine.plan(items: [rescanned], initiator: .user, context: context), confirmed: [], context: context)
        let report = await CleanupExecutor(store: nil, tools: .disabled).run(approved, dryRun: false, context: context)
        #expect(report.outcomes.first?.status == .removed)
        #expect(PathUtil.exists(precious), "the link target must survive")
    }

    // MARK: Races between scan and cleanup

    @Test("A directory swapped for a symlink after approval is skipped and the link target survives")
    func swappedForSymlinkAfterApproval() async {
        let f = Fixture()
        let precious = f.file(f.home + "/precious/thesis.txt")
        let item = f.item(f.projects + "/app/.pytest_cache", safety: .safe)
        let context = f.policyContext()
        let approved = engine.approve(engine.plan(items: [item], initiator: .user, context: context), confirmed: [], context: context)
        #expect(approved.count == 1)

        // Time of check has passed. Now the path changes underneath.
        try! FileManager.default.removeItem(atPath: item.path)
        symlink((precious as NSString).deletingLastPathComponent, item.path)

        let report = await CleanupExecutor(store: nil, tools: .disabled).run(approved, dryRun: false, context: context)
        guard case .skipped = report.outcomes.first?.status else {
            Issue.record("expected a skip, got \(String(describing: report.outcomes.first?.status))")
            return
        }
        #expect(PathUtil.exists(precious))
    }

    @Test("A directory recreated after the scan is a different object and is skipped")
    func recreatedAfterScan() async {
        let f = Fixture()
        let item = f.item(f.projects + "/app/.pytest_cache", safety: .safe)
        let context = f.policyContext()
        let approved = engine.approve(engine.plan(items: [item], initiator: .user, context: context), confirmed: [], context: context)
        try! FileManager.default.removeItem(atPath: item.path)
        f.file(item.path + "/new-results.bin")
        f.age(item.path, hours: 72)
        let report = await CleanupExecutor(store: nil, tools: .disabled).run(approved, dryRun: false, context: context)
        guard case .skipped = report.outcomes.first?.status else {
            Issue.record("expected a skip")
            return
        }
        #expect(PathUtil.exists(item.path + "/new-results.bin"))
    }

    @Test("Cleanup racing a build that is writing into the directory backs off")
    func concurrentBuildWrites() async {
        let f = Fixture()
        let item = f.item(f.projects + "/app/.build/debug", safety: .safe, category: .buildOutput)
        let context = f.policyContext()
        let approved = engine.approve(engine.plan(items: [item], initiator: .user, context: context), confirmed: [], context: context)
        #expect(approved.count == 1)

        // A "build" starts writing after approval and keeps going during cleanup.
        let directory = item.path
        let writer = Task.detached {
            var index = 0
            while !Task.isCancelled {
                FileManager.default.createFile(atPath: directory + "/object-\(index).o", contents: Data(repeating: 1, count: 512))
                index += 1
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        try? await Task.sleep(for: .milliseconds(60))
        let report = await CleanupExecutor(store: nil, tools: .disabled).run(approved, dryRun: false, context: context)
        writer.cancel()
        _ = await writer.value

        guard case .skipped(let reason) = report.outcomes.first?.status else {
            Issue.record("expected a skip, got \(String(describing: report.outcomes.first?.status))")
            return
        }
        #expect(reason.contains("modified"))
        #expect(PathUtil.exists(item.path + "/object-0.o"), "the build's output must be intact")
    }

    @Test("State that changes between approval and execution is re-checked per item")
    func contextIsRevalidatedAtExecution() async {
        let f = Fixture()
        let item = f.item(f.projects + "/app/.pytest_cache", safety: .safe)
        let calm = f.policyContext()
        let approved = engine.approve(engine.plan(items: [item], initiator: .user, context: calm), confirmed: [], context: calm)
        // By the time the executor runs, a test run has started in the project.
        let busy = f.policyContext(usage: [item.id: "pytest (PID 77) is running in this project."])
        let report = await CleanupExecutor(store: nil, tools: .disabled).run(approved, dryRun: false, context: busy)
        guard case .skipped = report.outcomes.first?.status else {
            Issue.record("expected a skip")
            return
        }
        #expect(PathUtil.exists(item.path))
    }

    @Test("A trashed item can be restored; restoring over an existing path is refused")
    func undoTrash() async {
        let f = Fixture()
        let store = try! PepelStore.inMemory()
        let executor = CleanupExecutor(store: store, tools: .disabled)
        let original = f.dir(f.projects + "/app") + "/.tox"
        let trashed = f.root + "/trash/.tox"
        f.file(trashed + "/env/bin/python")
        #expect(executor.restore(trashedPath: trashed, originalPath: original) == nil)
        #expect(PathUtil.exists(original + "/env/bin/python"))
        f.file(trashed + "/again")
        #expect(executor.restore(trashedPath: trashed, originalPath: original) != nil)
    }

    // MARK: Usage detection

    @Test("Artifacts referenced by a running build, used as a working directory, or in a building project count as in use")
    func usageInspection() {
        let f = Fixture()
        let project = f.projects + "/Makosh"
        let derived = f.item(f.home + "/Library/Developer/Xcode/DerivedData/Makosh-abc", category: .buildOutput, projectID: project)
        let venv = f.item(project + "/.venv", safety: .review, category: .virtualEnvironment, projectID: project)
        let other = f.item(f.projects + "/Other/.build/debug", category: .buildOutput, projectID: f.projects + "/Other")
        let sharedCache = f.item(f.home + "/Library/Caches/org.swift.swiftpm", safety: .review, category: .dependencyCache)

        let xcodebuild = process(900, parent: 800, name: "xcodebuild", args: ["xcodebuild", "-derivedDataPath", derived.path, "build"], cwd: project)
        let assessment = ProcessAssessment(
            process: xcodebuild, role: .buildTool, lifecycle: .activeBuildOrTest, confidence: .verified, projectID: project,
            projectConfidence: .verified, eligibility: .never(reason: "active"))
        let shell = process(901, name: "zsh", cwd: other.path)

        let usage = UsageInspector.inspect(items: [derived, venv, other, sharedCache], processes: [xcodebuild, shell], assessments: [assessment])
        #expect(usage[derived.id]?.contains("Referenced by running xcodebuild") == true)
        #expect(usage[venv.id]?.contains("running in this project") == true)
        #expect(usage[other.id]?.contains("working directory") == true)
        #expect(usage[sharedCache.id]?.contains("shared caches") == true)

        // With nothing running, nothing is in use.
        #expect(UsageInspector.inspect(items: [derived, venv, other, sharedCache], processes: [], assessments: []).isEmpty)
    }
}
