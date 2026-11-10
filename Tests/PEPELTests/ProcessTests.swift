import Foundation
import Testing
@testable import PEPELCleanup
@testable import PEPELEngine

@Suite("Process identity, classification and lifecycle")
struct ProcessTests {
    // MARK: Classification

    @Test("Roles are recognised from executables and command lines", arguments: [
        (["python3", "-m", "pytest", "tests/"], "/usr/bin/python3", ProcessRole.testRunner),
        (["/x/.venv/bin/pytest", "-q"], "/x/.venv/bin/python3", .testRunner),
        (["uvicorn", "app:api", "--reload"], "/x/.venv/bin/python3", .devServer),
        (["python", "manage.py", "runserver"], "/usr/bin/python3", .devServer),
        (["node", "/p/node_modules/.bin/vite"], "/usr/local/bin/node", .devServer),
        (["node", "/p/node_modules/.bin/vitest", "run"], "/usr/local/bin/node", .testRunner),
        (["node", "/p/node_modules/.bin/next", "dev"], "/usr/local/bin/node", .devServer),
        (["node", "/p/node_modules/.bin/next", "build"], "/usr/local/bin/node", .buildTool),
        (["xcodebuild", "-scheme", "App", "test"], "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild", .testRunner),
        (["xcodebuild", "-scheme", "App", "build"], "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild", .buildTool),
        (["swift", "test"], "/usr/bin/swift", .testRunner),
        (["swift-build", "-c", "release"], "/usr/bin/swift-build", .buildTool),
        (["cargo", "test"], "/Users/x/.cargo/bin/cargo", .testRunner),
        (["cargo", "build"], "/Users/x/.cargo/bin/cargo", .buildTool),
        (["/p/target/debug/deps/app-1a2b"], "/p/target/debug/deps/app-1a2b", .testRunner),
        (["claude"], "/Users/x/.local/bin/claude", .agent),
        (["codex", "exec"], "/opt/homebrew/bin/codex", .agent),
        (["opencode"], "/opt/homebrew/bin/opencode", .agent),
        (["/Applications/Claude.app/Contents/MacOS/Claude"], "/Applications/Claude.app/Contents/MacOS/Claude", .userApp),
        (["com.docker.backend"], "/Applications/Docker.app/Contents/MacOS/com.docker.backend", .container),
        (["launchd"], "/sbin/launchd", .system),
        (["Safari"], "/Applications/Safari.app/Contents/MacOS/Safari", .userApp),
    ] as [([String], String, ProcessRole)])
    func roles(args: [String], path: String, expected: ProcessRole) {
        let p = process(10, name: (path as NSString).lastPathComponent, path: path, args: args)
        #expect(RoleClassifier.role(of: p) == expected, "\(args.joined(separator: " "))")
    }

    @Test("Secrets in command lines are masked before display or storage")
    func argumentRedaction() {
        let p = process(1, name: "tool", args: ["tool", "--api-key", "sk-live-123", "TOKEN=abc", "--url", "https://user:pw@example.com/x", "--verbose"])
        let shown = p.displayCommand
        #expect(!shown.contains("sk-live-123") && !shown.contains("abc") && !shown.contains("user:pw"))
        #expect(shown.contains("--verbose") && shown.contains("example.com/x"))
        #expect(GitInspector.stripCredentials("https://me:ghp_secret@github.com/a/b.git") == "https://github.com/a/b.git")
    }

    // MARK: Identity and PID reuse

    @Test("A parent PID that now belongs to a younger process is not treated as the parent")
    func parentPIDReuse() {
        let child = process(200, parent: 100, name: "pytest", start: 5_000_000)
        let impostor = process(100, parent: 1, name: "zsh", start: 9_000_000)  // started after the child
        let tree = ProcessTree([child, impostor])
        #expect(tree.parent(of: child) == nil)
        #expect(tree.isOrphan(child))
        #expect(tree.children(of: impostor).isEmpty)

        let genuine = process(100, parent: 1, name: "zsh", start: 1_000_000)
        #expect(ProcessTree([child, genuine]).parent(of: child)?.identity == genuine.identity)
    }

    @Test("Identity is PID plus start time; the same PID with another start time is another process")
    func identityEquality() {
        #expect(ProcessIdentity(pid: 7, startTime: 1) != ProcessIdentity(pid: 7, startTime: 2))
        let tree = ProcessTree([process(7, name: "a", start: 2)])
        #expect(tree.process(ProcessIdentity(pid: 7, startTime: 1)) == nil)
    }

    @Test("The terminator signals nothing when the PID was reused since the assessment")
    func terminatorRefusesReusedPID() async {
        let assessed = process(4242, name: "pytest", start: 1_000)
        let control = FakeProcessControl([ProcessIdentity(pid: 4242, startTime: 9_999)])  // a different process now
        let approval = ApprovedTermination(
            target: ProcessAssessment(process: assessed, role: .testRunner, lifecycle: .abandonedSubprocess, confidence: .verified, eligibility: .automaticEligible),
            descendants: [], allowForce: true, graceSeconds: 1, initiator: .user)
        var terminator = ProcessTerminator(control: control, store: nil)
        terminator.settle = .milliseconds(1)
        let report = await terminator.terminate(approval) { SystemTelemetry() }
        #expect(control.sent.isEmpty)
        #expect(!report.exited)
    }

    // MARK: Lifecycle

    private func context(_ processes: [ProcessSnapshot], idle: [ProcessSnapshot] = [], project: String, rules: [ProtectionRule] = [], now: Date) -> AssessmentContext {
        AssessmentContext(
            processes: processes, history: idleHistory(idle, now: now), protections: rules,
            attributor: ProjectIndex([Project(id: project, name: "app", kinds: [.git])]), now: now, idleWindow: 30 * 60)
    }

    @Test("An orphaned, idle test runner with verified ownership is an abandoned subprocess, eligible for automatic termination")
    func abandonedTestRunner() {
        let f = Fixture()
        let project = f.dir(f.projects + "/app")
        let now = Date()
        let pytest = process(300, parent: 1, name: "python3", args: ["python3", "-m", "pytest"], cwd: project)
        let worker = process(301, parent: 300, name: "python3", args: ["python3", "-c", "worker"], cwd: project, start: 1_000_100)
        let result = ProcessGuardian.assess(context([pytest, worker], idle: [pytest, worker], project: project, now: now))
        let a = result.first { $0.process.pid == 300 }
        #expect(a?.lifecycle == .abandonedSubprocess)
        #expect(a?.confidence == .verified)
        #expect(a?.eligibility == .automaticEligible)
        #expect(a?.projectConfidence == .verified)
        #expect(a?.descendantCount == 1)
        #expect(a?.evidence.contains { $0.contains("parent process has exited") } == true)
    }

    @Test("A dead parent alone proves nothing: without enough observation the verdict is unknown")
    func orphanWithoutHistoryIsUnknown() {
        let f = Fixture()
        let project = f.dir(f.projects + "/app")
        let pytest = process(300, parent: 1, name: "pytest", cwd: project)
        let a = ProcessGuardian.assess(context([pytest], project: project, now: Date())).first
        #expect(a?.lifecycle == .unknown)
        #expect(a?.lifecycle.isAbandonedCandidate == false)
        if case .approvalRequired = a?.eligibility {} else { Issue.record("must require approval, got \(String(describing: a?.eligibility))") }
    }

    @Test("A detached dev server is treated as an intentional background service, never as garbage")
    func nohupServerIsNotAbandoned() {
        let f = Fixture()
        let project = f.dir(f.projects + "/app")
        let now = Date()
        let server = process(400, parent: 1, name: "uvicorn", args: ["uvicorn", "app:api"], cwd: project, ports: [8000])
        let a = ProcessGuardian.assess(context([server], idle: [server], project: project, now: now)).first
        #expect(a?.lifecycle == .backgroundService)
        #expect(a?.lifecycle.isAbandonedCandidate == false)
        #expect(a?.eligibility != .automaticEligible)
    }

    @Test("A registered persistent service is protected")
    func protectedService() {
        let f = Fixture()
        let project = f.dir(f.projects + "/app")
        let now = Date()
        let server = process(400, parent: 1, name: "pytest", args: ["pytest", "--looponfail"], cwd: project)
        for rule in [ProtectionRule(kind: .processName, value: "pytest"), ProtectionRule(kind: .command, value: "--looponfail")] {
            let a = ProcessGuardian.assess(context([server], idle: [server], project: project, rules: [rule], now: now)).first
            #expect(a?.lifecycle == .backgroundService)
            #expect(a?.eligibility.isNever == true)
        }
        let listening = process(401, parent: 1, name: "uvicorn", cwd: project, ports: [8000])
        let byPort = ProcessGuardian.assess(context([listening], idle: [listening], project: project, rules: [ProtectionRule(kind: .port, value: "8000")], now: now)).first
        #expect(byPort?.eligibility.isNever == true)
    }

    @Test("Builds under a live agent session or a terminal are active and never terminated")
    func activeBuilds() {
        let f = Fixture()
        let project = f.dir(f.projects + "/app")
        let now = Date()
        let agent = process(500, parent: 1, name: "claude", path: "/Users/x/.local/bin/claude", cwd: project)
        let shell = process(501, parent: 500, name: "zsh", path: "/bin/zsh", start: 1_000_100)
        let build = process(502, parent: 501, name: "swift-build", cwd: project, start: 1_000_200)
        let interactive = process(600, parent: 1, name: "cargo", args: ["cargo", "build"], cwd: project, tty: true)
        let assessed = ProcessGuardian.assess(context([agent, shell, build, interactive], idle: [agent, shell, build], project: project, now: now))

        let underAgent = assessed.first { $0.process.pid == 502 }
        #expect(underAgent?.lifecycle == .activeBuildOrTest)
        #expect(underAgent?.agentAncestor == agent.identity)
        #expect(underAgent?.eligibility.isNever == true)
        #expect(assessed.first { $0.process.pid == 500 }?.lifecycle == .agentSession)
        #expect(assessed.first { $0.process.pid == 500 }?.eligibility.isNever == true)
        // Orphaned but attached to a terminal and unobserved: not a candidate.
        #expect(assessed.first { $0.process.pid == 600 }?.lifecycle.isAbandonedCandidate == false)
    }

    @Test("An idle parent with a busy worker is not idle; an orphan still using CPU is only suspicious")
    func busySubtree() {
        let f = Fixture()
        let project = f.dir(f.projects + "/app")
        let now = Date()
        let runner = process(700, parent: 1, name: "pytest", cwd: project)
        var worker = process(701, parent: 700, name: "python3", args: ["python3", "-c", "w"], cwd: project, start: 1_000_100)
        let history = idleHistory([runner, worker], now: now)
        worker.cpuTimeNs = 600 * 1_000_000_000  // ten CPU-minutes since the first observation
        let ctx = AssessmentContext(
            processes: [runner, worker], history: history, attributor: ProjectIndex([Project(id: project, name: "app", kinds: [.git])]),
            now: now, idleWindow: 30 * 60)
        let a = ProcessGuardian.assess(ctx).first { $0.process.pid == 700 }
        #expect(a?.lifecycle == .suspiciousOrphan)
        #expect(a?.eligibility != .automaticEligible)
    }

    @Test("Processes that cannot be tied to a project are never eligible for automatic termination")
    func unresolvedOwnership() {
        let f = Fixture()
        let project = f.dir(f.projects + "/app")
        let now = Date()
        let stray = process(800, parent: 1, name: "pytest", cwd: f.dir(f.home + "/somewhere-else"))
        let a = ProcessGuardian.assess(context([stray], idle: [stray], project: project, now: now)).first
        #expect(a?.projectConfidence == .unknown)
        #expect(a?.eligibility != .automaticEligible)
    }

    // MARK: Termination policy and workflow

    private func abandoned(_ p: ProcessSnapshot, eligibility: TerminationEligibility = .automaticEligible, lifecycle: LifecycleClass = .abandonedSubprocess) -> ProcessAssessment {
        ProcessAssessment(process: p, role: .testRunner, lifecycle: lifecycle, confidence: .verified, projectID: "/p", projectConfidence: .verified, eligibility: eligibility)
    }

    @Test("Automatic termination is opt-in and limited to verified abandoned processes; agents can never request it")
    func terminationPolicy() {
        let engine = CleanupPolicyEngine()
        let target = abandoned(process(900, name: "pytest"))
        var settings = PepelSettings()
        func verdict(_ a: ProcessAssessment, _ initiator: Initiator) -> CleanupVerdict {
            engine.evaluateTermination(a, descendants: [], descendantAssessments: [], initiator: initiator, settings: settings, ownPID: 1).verdict
        }
        #expect(verdict(target, .automatic) == .denied)  // not enabled
        settings.autoTerminateAbandoned = true
        #expect(verdict(target, .automatic) == .allowed)
        #expect(verdict(abandoned(process(901, name: "pytest"), eligibility: .approvalRequired(warning: "x")), .automatic) == .denied)
        #expect(verdict(abandoned(process(902, name: "pytest"), lifecycle: .suspiciousOrphan), .automatic) == .denied)
        #expect(verdict(target, .agent) == .denied)
        #expect(verdict(target, .user) == .needsConfirmation)
        #expect(verdict(abandoned(process(903, name: "claude"), eligibility: .never(reason: "agent")), .user) == .denied)
        #expect(verdict(abandoned(process(904, name: "pytest", uid: 0)), .user) == .denied)  // another user's process

        // Never without confirmation, and force only when the user asked for it.
        let decision = engine.evaluateTermination(target, descendants: [], descendantAssessments: [], initiator: .user, settings: settings, ownPID: 1)
        #expect(engine.approveTermination(decision, confirmed: false, force: true, initiator: .user, settings: settings) == nil)
        #expect(engine.approveTermination(decision, confirmed: true, force: false, initiator: .user, settings: settings)?.allowForce == false)
        let automatic = engine.evaluateTermination(target, descendants: [], descendantAssessments: [], initiator: .automatic, settings: settings, ownPID: 1)
        #expect(engine.approveTermination(automatic, confirmed: false, force: true, initiator: .automatic, settings: settings)?.allowForce == false)
    }

    @Test("A process with a protected descendant is not terminated")
    func protectedDescendant() {
        let parent = abandoned(process(910, name: "pytest"))
        let child = process(911, parent: 910, name: "claude", start: 1_000_100)
        let childAssessment = ProcessAssessment(process: child, role: .agent, lifecycle: .agentSession, confidence: .verified, eligibility: .never(reason: "Agent sessions are never terminated by PEPEL."))
        let decision = CleanupPolicyEngine().evaluateTermination(
            parent, descendants: [child], descendantAssessments: [childAssessment], initiator: .user, settings: PepelSettings(), ownPID: 1)
        #expect(decision.verdict == .denied)
    }

    @Test("Graceful termination waits for exit, cleans up children, and records before/after measurements")
    func gracefulTermination() async {
        let store = try! PepelStore.inMemory()
        let target = process(920, name: "pytest", footprint: 900_000_000)
        let child = ProcessIdentity(pid: 921, startTime: 1_000_100)
        let control = FakeProcessControl([target.identity, child])
        var terminator = ProcessTerminator(control: control, store: store)
        terminator.settle = .milliseconds(1)
        var assessment = abandoned(target)
        assessment.subtreeFootprintBytes = 1_000_000_000
        let approval = ApprovedTermination(target: assessment, descendants: [child], allowForce: false, graceSeconds: 2, initiator: .user)
        let samples = TelemetrySequence([SystemTelemetry(appMemoryBytes: 40_000_000_000, pressure: .elevated), SystemTelemetry(appMemoryBytes: 39_400_000_000, pressure: .normal)])
        let report = await terminator.terminate(approval) { samples.next() }

        #expect(report.exited && !report.forced)
        #expect(control.sent.map(\.signal) == [SIGTERM, SIGTERM])
        #expect(control.sent.map(\.pid) == [920, 921])
        #expect(report.observedMemoryChange == -600_000_000)  // measured, not the 1 GB footprint
        #expect(report.footprintBefore == 1_000_000_000)
        let entry = store.audit().first
        #expect(entry?.kind == .termination && entry?.outcome == "terminated")
        #expect(entry?.detail["pressureBefore"] == "elevated" && entry?.detail["pressureAfter"] == "normal")
    }

    @Test("A process that ignores SIGTERM is killed only when force was authorised")
    func escalation() async {
        let target = process(930, name: "pytest")
        for (force, expectKilled) in [(false, false), (true, true)] {
            let control = FakeProcessControl([target.identity], ignoringSIGTERM: [930])
            var terminator = ProcessTerminator(control: control, store: nil)
            terminator.settle = .milliseconds(1)
            terminator.pollInterval = .milliseconds(20)
            let approval = ApprovedTermination(target: abandoned(target), descendants: [], allowForce: force, graceSeconds: 1, initiator: .user)
            let report = await terminator.terminate(approval) { SystemTelemetry() }
            #expect(report.exited == expectKilled)
            #expect(report.forced == expectKilled)
            #expect(control.sent.contains { $0.signal == SIGKILL } == expectKilled)
        }
    }

    // MARK: Memory guardian

    @Test("Under high memory pressure only abandoned processes are proposed, never merely large ones")
    func memoryPressureProposals() {
        let big = process(1000, parent: 50, name: "Xcode", path: "/Applications/Xcode.app/Contents/MacOS/Xcode", footprint: 30_000_000_000)
        let orphan = process(1001, name: "pytest", footprint: 2_000_000_000)
        let active = process(1002, parent: 50, name: "swift-build", footprint: 9_000_000_000)
        let assessments = [
            abandoned(orphan),
            ProcessAssessment(process: active, role: .buildTool, lifecycle: .activeBuildOrTest, confidence: .verified, eligibility: .never(reason: "active")),
        ]
        let telemetry = SystemTelemetry(memoryTotalBytes: 64_000_000_000, compressedBytes: 20_000_000_000, pressure: .critical, swapUsedBytes: 12_000_000_000)
        let advice = MemoryGuardian.advise(telemetry: telemetry, processes: [big, orphan, active], assessments: assessments)
        #expect(advice.level == .critical)
        #expect(advice.proposals.map(\.process.pid) == [1001])
        #expect(advice.topConsumers.first?.identity.pid == 1000)  // shown for context only
        #expect(advice.proposalFootprintBytes == 2_000_000_000)

        let calm = MemoryGuardian.advise(telemetry: SystemTelemetry(cachedFileBytes: 30_000_000_000, freeBytes: 100_000_000, pressure: .normal), processes: [big], assessments: [])
        #expect(calm.headline == "Memory is healthy")  // low free memory is not a problem
        #expect(calm.proposals.isEmpty)
    }

    // MARK: Agents

    @Test("Several concurrent agents are detected with their process trees and projects")
    func concurrentAgents() {
        let f = Fixture()
        let a = f.dir(f.projects + "/alpha"), b = f.dir(f.projects + "/beta")
        let index = ProjectIndex([Project(id: a, name: "alpha", kinds: [.git]), Project(id: b, name: "beta", kinds: [.git])])
        let processes = [
            process(10, name: "claude", path: "/Users/x/.local/bin/claude", cwd: a, footprint: 300_000_000),
            process(11, parent: 10, name: "zsh", path: "/bin/zsh", start: 1_000_100, footprint: 5_000_000),
            process(12, parent: 11, name: "swift-build", cwd: a, start: 1_000_200, footprint: 700_000_000),
            process(20, name: "codex", path: "/opt/homebrew/bin/codex", cwd: b),
            process(21, parent: 20, name: "codex", path: "/opt/homebrew/bin/codex", args: ["codex", "--helper"], cwd: b, start: 1_000_100),
            process(30, name: "opencode", path: "/opt/homebrew/bin/opencode", cwd: f.home),
        ]
        let sessions = AgentDetector.sessions(processes: processes, attributor: index)
        #expect(sessions.count == 3)  // the codex helper belongs to its parent session
        let claude = sessions.first { $0.kind == .claudeCode }
        #expect(claude?.projectID == a && claude?.processCount == 3 && claude?.activeBuildCount == 1)
        #expect(claude?.footprintBytes == 1_005_000_000)
        #expect(sessions.first { $0.kind == .codex }?.processCount == 2)
        #expect(sessions.first { $0.kind == .openCode }?.projectID == nil)
    }

    // MARK: Real macOS behaviour

    @Test("The real process table contains this test process with a stable identity")
    func realEnumeration() {
        let me = getpid()
        let snapshot = ProcessEnumerator().snapshot()
        let own = snapshot.first { $0.pid == me }
        #expect(own != nil)
        #expect(own?.identity == ProcessEnumerator.identity(of: me))
        #expect(own?.footprintBytes ?? 0 > 0)
        #expect(own?.executablePath?.isEmpty == false)
        #expect(snapshot.allSatisfy { $0.uid == getuid() })
        #expect(ProcessEnumerator.identity(of: 99_999_999) == nil)
    }

    @Test("A real child process is terminated gracefully through the terminator and its exit is confirmed")
    func realTermination() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["300"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let pid = child.processIdentifier
        let snapshot = try #require(ProcessEnumerator.describe(pid))
        #expect(snapshot.arguments == ["/bin/sleep", "300"] || snapshot.arguments == ["sleep", "300"])

        var terminator = ProcessTerminator(control: SourceProcessControl(source: ProcessEnumerator()), store: nil)
        terminator.settle = .milliseconds(1)
        let approval = ApprovedTermination(target: abandoned(snapshot), descendants: [], allowForce: false, graceSeconds: 5, initiator: .user)
        let report = await terminator.terminate(approval) { TelemetryReader().read() }
        child.waitUntilExit()
        #expect(report.exited)
        #expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGTERM)
        #expect(report.before.memoryTotalBytes > 0)
    }

    @Test("System telemetry reads plausible disk and memory figures")
    func realTelemetry() {
        let t = TelemetryReader().read()
        #expect(t.diskTotalBytes > 0 && t.diskAvailableBytes > 0 && t.diskAvailableBytes <= t.diskTotalBytes)
        #expect(t.memoryTotalBytes == Int64(ProcessInfo.processInfo.physicalMemory))
        #expect(t.memoryUsedBytes > 0 && t.memoryUsedBytes <= t.memoryTotalBytes)
    }
}

/// Hands out telemetry samples in order (before, after).
final class TelemetrySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [SystemTelemetry]

    init(_ samples: [SystemTelemetry]) { self.samples = samples }

    func next() -> SystemTelemetry {
        lock.lock()
        defer { lock.unlock() }
        return samples.count > 1 ? samples.removeFirst() : samples[0]
    }
}
