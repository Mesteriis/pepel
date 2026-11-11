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

    // MARK: Memory attribution

    @Test("Memory is grouped by owner: apps with their helpers, agent sessions with their tools, VMs with their runtime")
    func memoryAttribution() {
        let f = Fixture()
        let project = f.dir(f.projects + "/alpha")
        let index = ProjectIndex([Project(id: project, name: "alpha", kinds: [.git])])
        func p(_ pid: Int32, _ parent: Int32, _ name: String, _ path: String, footprint: Int64, resident: Int64, cwd: String? = nil, start: UInt64 = 1_000_000, args: [String]? = nil) -> ProcessSnapshot {
            var s = process(pid, parent: parent, name: name, path: path, args: args, cwd: cwd, start: start, footprint: footprint)
            s.residentBytes = resident
            return s
        }
        let gb = Bytes.gb
        let processes = [
            // Docker Desktop: the VM is a child of launchd and is tied to the runtime by start time.
            p(100, 1, "com.docker.backend", "/Applications/Docker.app/Contents/MacOS/com.docker.backend", footprint: gb / 2, resident: gb / 2, start: 5_000_000),
            p(101, 1, "com.apple.Virtualization.VirtualMachine", "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine", footprint: 34 * gb, resident: 7 * gb, start: 5_400_000),
            // An application with a deeply nested helper.
            p(200, 1, "Dia", "/Applications/Dia.app/Contents/MacOS/Dia", footprint: gb, resident: gb),
            p(201, 200, "Browser Helper (Renderer)", "/Applications/Dia.app/Contents/Frameworks/ArcCore.framework/Helpers/Browser Helper (Renderer).app/Contents/MacOS/Browser Helper (Renderer)", footprint: 2 * gb, resident: gb, start: 1_000_100),
            // An agent session: the CLI, a shell, an MCP server and a build.
            p(300, 1, "claude", "/Users/x/.local/bin/claude", footprint: gb / 4, resident: gb / 4, cwd: project),
            p(301, 300, "zsh", "/bin/zsh", footprint: gb / 100, resident: gb / 100, start: 1_000_100),
            p(302, 300, "python3", "/usr/bin/python3", footprint: gb / 10, resident: gb / 10, cwd: project, start: 1_000_100, args: ["python3", "serena", "start-mcp-server"]),
            p(303, 301, "swift-build", "/usr/bin/swift-build", footprint: gb / 2, resident: gb / 2, cwd: project, start: 1_000_200),
            // A stand-alone program started by hand, twice.
            p(400, 1, "xerj", "/Users/x/.local/bin/xerj", footprint: 2 * gb, resident: gb),
            p(401, 1, "xerj", "/Users/x/.local/bin/xerj", footprint: gb, resident: gb, start: 2_000_000),
            p(500, 1, "cfprefsd", "/usr/sbin/cfprefsd", footprint: gb / 50, resident: gb / 50),
        ]
        let sessions = AgentDetector.sessions(processes: processes, attributor: index)
        let assessments = ProcessGuardian.assess(AssessmentContext(processes: processes, attributor: index))
        let owners = MemoryAttributor.attribute(processes: processes, assessments: assessments, sessions: sessions) { index.project(id: $0)?.name }
        let byID = Dictionary(uniqueKeysWithValues: owners.map { ($0.id, $0) })

        #expect(owners.first?.id == "vm:Docker Desktop", "largest first")
        let vm = byID["vm:Docker Desktop"]
        #expect(vm?.kind == .virtualMachine && vm?.processCount == 2 && vm?.footprintBytes == 34 * gb + gb / 2)
        #expect(vm?.notInRAMBytes == 27 * gb, "footprint minus resident, per process")
        #expect(vm?.confidence == .probable, "the VM's owner is inferred from start time, not proven")

        let app = byID["app:/Applications/Dia.app"]
        #expect(app?.name == "Dia" && app?.processCount == 2 && app?.footprintBytes == 3 * gb && app?.notInRAMBytes == gb)

        let agent = owners.first { $0.kind == .agentSession }
        #expect(agent?.name == "Claude Code · alpha" && agent?.processCount == 4 && agent?.projectID == project)
        #expect(byID["exe:xerj"]?.processCount == 2 && byID["exe:xerj"]?.footprintBytes == 3 * gb)
        #expect(byID["system"]?.processCount == 1)
        // Every process is counted exactly once.
        #expect(owners.reduce(0) { $0 + $1.processCount } == processes.count)
        #expect(owners.reduce(Int64(0)) { $0 + $1.footprintBytes } == processes.reduce(Int64(0)) { $0 + $1.footprintBytes })

        let telemetry = SystemTelemetry(memoryTotalBytes: 68 * gb, compressedBytes: 26 * gb, pressure: .elevated, swapUsedBytes: 13 * gb)
        let text = MemoryAttributor.explanation(owners: owners, telemetry: telemetry)
        #expect(text.contains("Docker Desktop is charged 34.5 GB") && text.contains("about 27.0 GB is not in RAM") && text.contains("estimate"))
    }

    @Test("A virtual machine with no runtime nearby is reported as unidentified, not guessed")
    func unidentifiedVirtualMachine() {
        let vm = process(101, name: "com.apple.Virtualization.VirtualMachine", path: "/System/Library/Frameworks/Virtualization.framework/x/com.apple.Virtualization.VirtualMachine", footprint: 8 * Bytes.gb)
        let owners = MemoryAttributor.attribute(processes: [vm], assessments: [], sessions: []) { _ in nil }
        #expect(owners.first?.kind == .virtualMachine && owners.first?.confidence == .unknown)
        #expect(owners.first?.name.contains("not identified") == true)
    }

    // MARK: Containers

    @Test("Container memory is read from the runtime, grouped by compose project and tied to projects by Docker's own labels")
    func containerInspection() {
        let f = Fixture()
        let project = f.dir(f.projects + "/orders-api")
        let index = ProjectIndex([Project(id: project, name: "orders-api", kinds: [.git])])
        let inspector = ContainerInspector { arguments, _ in
            switch arguments.first {
            case "info": return "33859940352\t18\t3\t40\tDocker Desktop\n"
            case "ps":
                return "gr-api-1\torders-api\t\(project)/deploy\ngr-db-1\torders-api\t\(project)/deploy\nscratch\t\t\n"
            case "stats": return "gr-api-1\t1.5GiB / 31.53GiB\t2.50%\ngr-db-1\t512MiB / 31.53GiB\t0.10%\nscratch\t150.2MiB / 1GiB\t0.00%\n"
            default: return nil
            }
        }
        let report = inspector.inspect(attributor: index)
        #expect(report?.product == "Docker Desktop" && report?.vmLimitBytes == 33_859_940_352 && report?.running == 3 && report?.total == 40)
        #expect(report?.groups.map(\.id) == ["orders-api", "standalone"])
        let group = report?.groups.first
        #expect(group?.projectID == project && group?.projectConfidence == .verified && group?.containers.map(\.name) == ["gr-api-1", "gr-db-1"])
        #expect(group?.memoryBytes == 1_610_612_736 + 536_870_912 && group?.cpuPercent == 2.6)
        #expect(report?.groups.last?.projectID == nil)
        #expect(report?.usedByContainersBytes == 1_610_612_736 + 536_870_912 + ContainerInspector.parseMemory("150.2MiB")!)

        // No runtime, or a daemon that does not answer: no report, no guess.
        #expect(ContainerInspector { _, _ in nil }.inspect() == nil)
        #expect(ContainerInspector { _, _ in "garbage" }.inspect() == nil)

        #expect(ContainerInspector.parseMemory("1.786GiB") == 1_917_702_897)
        #expect(ContainerInspector.parseMemory("4.664MiB ") == 4_890_558)
        #expect(ContainerInspector.parseMemory("512B") == 512 && ContainerInspector.parseMemory("lots") == nil)
    }

    @Test("A lower limit is suggested only when current use leaves real room, and the explanation states what was measured")
    func containerAdvice() {
        let gib: Int64 = 1 << 30
        func report(used: Int64, limit: Int64, host: Int64) -> ContainerReport {
            ContainerReport(
                product: "Docker Desktop", vmLimitBytes: limit, cpus: 8, running: 2, total: 5,
                groups: [ContainerGroup(id: "p", name: "p", containers: [ContainerMemory(name: "c", memoryBytes: used, cpuPercent: 0)])],
                hostFootprintBytes: host, hostResidentBytes: host / 4)
        }
        // 8 GiB used of 32: 1.5× + 2 GiB = 14 → 14 GiB, well under the limit.
        let roomy = report(used: 8 * gib, limit: 32 * gib, host: 33 * gib)
        #expect(roomy.suggestedLimitBytes == 14 * gib)
        #expect(roomy.explanation.contains("2 running containers use 8.59 GB of a virtual machine limited to 34.4 GB"))
        #expect(roomy.explanation.contains("charged 35.4 GB") && roomy.explanation.contains("A limit around 15.0 GB"))
        // 14 GiB used of 24: the same formula gives 24 GiB, which is no saving. No suggestion.
        #expect(report(used: 14 * gib, limit: 24 * gib, host: 20 * gib).suggestedLimitBytes == nil)
        // Almost nothing running still gets a sane floor.
        #expect(report(used: gib / 10, limit: 16 * gib, host: 2 * gib).suggestedLimitBytes == 4 * gib)
        // The host is not charged much more than the containers use: nothing alarming to say.
        #expect(!report(used: 8 * gib, limit: 12 * gib, host: 9 * gib).explanation.contains("charged"))
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

    @Test("The same tool server started by several sessions is reported once, with what the extra copies hold")
    func duplicatedAgentHelpers() {
        var processes: [ProcessSnapshot] = []
        for session in 0..<3 {
            let root = Int32(100 * (session + 1))
            processes.append(process(root, name: "claude", path: "/Users/x/.local/bin/claude"))
            processes.append(process(root + 1, parent: root, name: "python3", path: "/Users/x/.local/share/uv/tools/serena-agent/bin/python", args: ["/Users/x/.local/share/uv/tools/serena-agent/bin/python", "/Users/x/.local/bin/serena", "start-mcp-server", "--context=claude-code"], start: 1_000_100, footprint: 100_000_000))
            processes.append(process(root + 2, parent: root, name: "node", args: ["node", "/srv/tools/tg/index.js"], start: 1_000_100, footprint: 50_000_000))
        }
        // Only one session runs this one: not a duplicate.
        processes.append(process(103, parent: 100, name: "node", args: ["node", "/srv/tools/unique/index.js"], start: 1_000_100, footprint: 70_000_000))
        // A server process of an application is not a session and contributes nothing.
        processes.append(process(900, name: "codex", path: "/Applications/ChatGPT.app/Contents/Resources/codex", args: ["codex", "app-server"]))
        processes.append(process(901, parent: 900, name: "node", args: ["node", "/srv/tools/tg/index.js"], start: 1_000_100, footprint: 50_000_000))

        let sessions = AgentDetector.sessions(processes: processes, attributor: nil)
        let groups = AgentDetector.helperGroups(processes: processes, sessions: sessions)
        #expect(groups.map(\.id) == ["python bin/serena start-mcp-server", "node tg/index.js"])
        #expect(groups[0].copies == 3 && groups[0].sessions == 3 && groups[0].footprintBytes == 300_000_000 && groups[0].duplicatedBytes == 200_000_000)
        #expect(groups[1].copies == 3 && groups[1].duplicatedBytes == 100_000_000)
    }

    // MARK: Leftovers of quit applications

    private func appProcess(_ pid: Int32, _ parent: Int32, _ path: String, start: UInt64 = 1_000_000, footprint: Int64 = 100_000_000, args: [String]? = nil) -> ProcessSnapshot {
        process(pid, parent: parent, name: (path as NSString).lastPathComponent, path: path, args: args, start: start, footprint: footprint)
    }

    @Test("When an application quits, what it started and what runs from its bundle is reported; system components and agents are not")
    func appLeftovers() {
        let now = Date()
        let app = "/Applications/Editor.app"
        let main = appProcess(100, 1, app + "/Contents/MacOS/Editor")
        let helper = appProcess(101, 100, app + "/Contents/Frameworks/Editor Helper.app/Contents/MacOS/Editor Helper", start: 1_000_100, footprint: 400_000_000)
        let tool = appProcess(102, 100, "/usr/local/bin/lang-server", start: 1_000_200, footprint: 300_000_000)
        let toolChild = appProcess(103, 102, "/usr/local/bin/lang-worker", start: 1_000_300, footprint: 50_000_000)
        let xpc = appProcess(104, 1, app + "/Contents/XPCServices/Thumbs.xpc/Contents/MacOS/Thumbs", start: 1_000_100)
        let agent = appProcess(105, 100, "/Users/x/.local/bin/claude", start: 1_000_400)
        let agentTool = appProcess(106, 105, "/usr/bin/python3", start: 1_000_500, args: ["python3", "mcp"])
        let unrelated = appProcess(200, 1, "/Applications/Other.app/Contents/MacOS/Other")
        let running = [main, helper, tool, toolChild, xpc, agent, agentTool, unrelated]

        var tracker = AppExitTracker()
        tracker.update(processes: running, now: now.addingTimeInterval(-600))
        func leftovers(_ processes: [ProcessSnapshot], at date: Date, automaticAfter: TimeInterval = 600) -> [AppLeftovers] {
            tracker.leftovers(processes: processes, assessments: [], protectedRoots: [agent.identity], attributor: nil, now: date, automaticAfter: automaticAfter, ownPID: 1)
        }
        #expect(leftovers(running, at: now).isEmpty, "nothing is a leftover while the application runs")

        // The application quits; its helper, the tool it launched, an XPC service and an agent survive.
        let survivors = [helper, tool, toolChild, xpc, agent, agentTool, unrelated].map { p -> ProcessSnapshot in
            var orphan = p
            if p.parentPID == 100 { orphan.parentPID = 1 }
            return orphan
        }
        let quitAt = now.addingTimeInterval(-300)
        tracker.update(processes: survivors, now: quitAt)
        #expect(leftovers(survivors, at: quitAt.addingTimeInterval(20)).isEmpty, "applications get a minute to shut their helpers down")

        let groups = leftovers(survivors, at: now)
        #expect(groups.map(\.appName) == ["Editor"])
        let found = groups[0].processes
        #expect(found.map(\.process.pid) == [101, 102], "largest first; the tool's child is listed with its parent")
        #expect(found.allSatisfy { $0.leftoverOf == "Editor" && $0.lifecycle == .abandonedSubprocess && $0.confidence == .verified })
        #expect(found[1].descendantCount == 1 && found[1].subtreeFootprintBytes == 350_000_000)
        #expect(found[0].evidence.contains { $0.contains("inside Editor.app") } && found[1].evidence.contains { $0.contains("child of Editor") })
        #expect(groups[0].footprintBytes == 750_000_000)
        // Five minutes after the quit, with a ten-minute grace period: approval only.
        #expect(found.allSatisfy { if case .approvalRequired = $0.eligibility { return true } else { return false } })
        // Past the grace period they become eligible for the automatic rule.
        #expect(leftovers(survivors, at: now.addingTimeInterval(600)).first?.processes.allSatisfy { $0.eligibility == .automaticEligible } == true)

        // The application is started again: the old note no longer applies.
        let relaunched = appProcess(300, 1, app + "/Contents/MacOS/Editor", start: 9_000_000)
        tracker.update(processes: survivors + [relaunched], now: now)
        #expect(leftovers(survivors + [relaunched], at: now.addingTimeInterval(3600)).isEmpty)
    }

    @Test("A PID reused by another program after the application quit is not mistaken for its leftover")
    func leftoverPIDReuse() {
        let now = Date()
        let main = appProcess(100, 1, "/Applications/Editor.app/Contents/MacOS/Editor")
        let tool = appProcess(102, 100, "/usr/local/bin/lang-server", start: 1_000_200)
        var tracker = AppExitTracker()
        tracker.update(processes: [main, tool], now: now.addingTimeInterval(-900))
        // Both exit; later an unrelated program gets PID 102.
        let stranger = appProcess(102, 1, "/usr/bin/vim", start: 5_000_000)
        tracker.update(processes: [stranger], now: now.addingTimeInterval(-600))
        let groups = tracker.leftovers(processes: [stranger], assessments: [], protectedRoots: [], attributor: nil, now: now, automaticAfter: 60, ownPID: 1)
        #expect(groups.isEmpty)
    }

    @Test("Leftovers are terminated automatically only when enabled and past the grace period; containers never")
    func leftoverPolicy() {
        let engine = CleanupPolicyEngine()
        var settings = PepelSettings()
        func leftover(_ eligibility: TerminationEligibility, role: ProcessRole = .userApp) -> ProcessAssessment {
            var a = ProcessAssessment(process: process(700, name: "Editor Helper"), role: role, lifecycle: .abandonedSubprocess, confidence: .verified, eligibility: eligibility)
            a.leftoverOf = "Editor"
            return a
        }
        func verdict(_ a: ProcessAssessment, _ initiator: Initiator) -> CleanupVerdict {
            engine.evaluateTermination(a, descendants: [], descendantAssessments: [], initiator: initiator, settings: settings, ownPID: 1).verdict
        }
        // A helper is not a developer workload, but as a leftover the user may terminate it.
        #expect(verdict(leftover(.automaticEligible), .user) == .needsConfirmation)
        #expect(verdict(leftover(.automaticEligible), .automatic) == .denied, "off by default")
        settings.terminateAppLeftovers = true
        #expect(verdict(leftover(.automaticEligible), .automatic) == .allowed)
        #expect(verdict(leftover(.approvalRequired(warning: "grace")), .automatic) == .denied, "still inside the grace period")
        #expect(verdict(leftover(.never(reason: "container"), role: .container), .automatic) == .denied)
        #expect(verdict(leftover(.never(reason: "container"), role: .container), .user) == .denied)
        #expect(verdict(leftover(.automaticEligible), .agent) == .denied)
        // The same helper without the leftover evidence stays off limits.
        var plain = leftover(.automaticEligible)
        plain.leftoverOf = nil
        #expect(verdict(plain, .user) == .denied)
    }

    // MARK: Sleeping agent sessions

    /// A history with one point every five minutes; `writes` and `cpu` give cumulative values per point.
    private func series(minutes: [Double], written: [UInt64], cpuSeconds: [Double]? = nil, now: Date) -> [ProcessObservation] {
        zip(minutes.indices, minutes).map { index, ago in
            ProcessObservation(
                timestamp: now.addingTimeInterval(-ago * 60), cpuTimeNs: UInt64((cpuSeconds?[index] ?? 0) * 1e9), footprintBytes: 1,
                diskBytesWritten: written[index])
        }
    }

    @Test("A session that keeps writing is working; one silent for the whole window is asleep; in between it is idle")
    func agentSleepStates() {
        let now = Date()
        let window: TimeInterval = 2 * 3600
        var root = process(10, name: "claude", path: "/Users/x/.local/bin/claude")
        let helper = process(11, parent: 10, name: "python3", args: ["python3", "mcp-server"], start: 1_000_100)
        func state(_ history: [ProcessIdentity: [ProcessObservation]], builds: Int = 0, lease: Bool = false, members: [ProcessSnapshot]? = nil) -> AgentActivity.Verdict {
            AgentActivity.verdict(root: root, members: members ?? [helper], history: history, activeBuildCount: builds, hasActiveLease: lease, now: now, sleepWindow: window)
        }

        // Wrote 300 KB two minutes ago while using 2 % of a core: work.
        root.diskBytesWritten = 1_300_000
        root.cpuTimeNs = UInt64(73.2 * 1e9)
        let writing = [root.identity: series(minutes: [180, 60, 2], written: [1_000_000, 1_000_000, 1_300_000], cpuSeconds: [0, 28.8, 73.0], now: now)]
        #expect(state(writing).state == .working)

        // Housekeeping, as measured on real idle sessions: about 20 KB once an hour (once 130 KB)
        // at idle CPU. Five hours of that is still asleep.
        root.diskBytesWritten = 1_210_000
        root.cpuTimeNs = UInt64(72 * 1e9)
        let housekeeping = [
            root.identity: series(
                minutes: [300, 241, 240, 181, 180, 121, 120, 61, 60, 1],
                written: [1_000_000, 1_000_000, 1_020_000, 1_020_000, 1_150_000, 1_150_000, 1_170_000, 1_170_000, 1_190_000, 1_190_000],
                cpuSeconds: [0, 14.2, 14.4, 28.6, 28.8, 43.0, 43.2, 57.4, 57.6, 71.8], now: now)
        ]
        #expect(state(housekeeping).state == .sleeping, "hourly housekeeping writes must not keep a session awake")

        // The same housekeeping tick seen through 20-second samples, where its own CPU blip looks
        // large: still housekeeping, because the write is small.
        root.diskBytesWritten = 1_020_000
        root.cpuTimeNs = UInt64(44 * 1e9)
        let fineGrained = [
            root.identity: series(
                minutes: [180, 61, 60.67, 60.33, 60, 1], written: [1_000_000, 1_000_000, 1_012_000, 1_020_000, 1_020_000, 1_020_000],
                cpuSeconds: [0, 28.6, 29.0, 29.4, 29.5, 43.8], now: now)
        ]
        #expect(state(fineGrained).state == .sleeping)

        // Writes in neighbouring minutes that add up: that is someone working.
        root.diskBytesWritten = 1_090_000
        root.cpuTimeNs = UInt64(43.2 * 1e9)
        let cluster = [root.identity: series(minutes: [180, 33, 32, 30.5, 1], written: [1_000_000, 1_000_000, 1_045_000, 1_090_000, 1_090_000], cpuSeconds: [0, 35.5, 35.8, 36.0, 43.0], now: now)]
        #expect(state(cluster).state == .idle && state(cluster).evidence.first?.contains("while working") == true)

        // Silent for three hours of observation: idle polling CPU only (0.4 % of a core), no writes.
        root.diskBytesWritten = 1_000_000
        root.cpuTimeNs = UInt64(43.2 * 1e9)
        let silent = [
            root.identity: series(minutes: [180, 120, 60, 1], written: [1_000_000, 1_000_000, 1_000_000, 1_000_000], cpuSeconds: [0, 14.4, 28.8, 43.0], now: now),
            helper.identity: series(minutes: [180, 1], written: [5, 5], now: now),
        ]
        let asleep = state(silent)
        #expect(asleep.state == .sleeping)
        #expect(asleep.evidence.contains { $0.contains("No sign of work") })

        // The same silence, but a build is running, or a lease is held: not asleep.
        #expect(state(silent, builds: 1).state == .working)
        #expect(state(silent, lease: true).state == .idle)

        // Last real work 90 minutes ago (100 KB at 3 % CPU): idle, with the time left stated.
        root.cpuTimeNs = UInt64(40 * 1e9)
        root.diskBytesWritten = 1_000_000
        let recent = [root.identity: series(minutes: [180, 95, 90, 1], written: [900_000, 900_000, 1_000_000, 1_000_000], cpuSeconds: [0, 10, 19, 39.8], now: now)]
        let idle = state(recent)
        #expect(idle.state == .idle)
        #expect(idle.evidence.contains { $0.contains("to go") })

        // Silent, but PEPEL has only watched for 40 minutes: it cannot claim two hours of quiet.
        root.cpuTimeNs = 0
        let short = [root.identity: series(minutes: [40, 1], written: [1_000_000, 1_000_000], now: now)]
        #expect(state(short).state == .idle)

        // A tool server started ten minutes ago is activity, even with no writes.
        let fresh = process(12, parent: 10, name: "node", start: UInt64((now.timeIntervalSince1970 - 600) * 1_000_000))
        #expect(state(silent, members: [helper, fresh]).state == .idle)

        // A real CPU burst (30 % of a core for five minutes) one hour ago resets the clock.
        root.cpuTimeNs = UInt64(120 * 1e9)
        let burst = [root.identity: series(minutes: [180, 65, 60, 1], written: [1, 1, 1, 1], cpuSeconds: [0, 10, 100, 119], now: now)]
        root.diskBytesWritten = 1
        #expect(state(burst).state == .idle)
    }

    @Test("An agent binary running as a server for an application is never asleep, however quiet")
    func agentServersAreNotSessions() {
        let now = Date()
        let cli = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        let server = process(40, parent: 30, name: "codex", path: cli, args: [cli, "-c", "forced_login_method=\"chatgpt\"", "exec-server", "--concurrent-requests", "32"])
        let session = process(41, name: "codex", path: "/opt/homebrew/bin/codex", args: ["codex", "resume"])
        #expect(AgentActivity.isService(server) && !AgentActivity.isService(session))
        #expect(AgentActivity.isService(process(42, name: "claude", args: ["claude", "mcp", "serve"])))

        let quiet = stride(from: 300.0, through: 1, by: -30).map { ProcessObservation(timestamp: now.addingTimeInterval(-$0 * 60), cpuTimeNs: 0, footprintBytes: 1) }
        let history = [server.identity: quiet, session.identity: quiet]
        func verdict(_ p: ProcessSnapshot) -> AgentActivity.Verdict {
            AgentActivity.verdict(root: p, members: [], history: history, activeBuildCount: 0, hasActiveLease: false, now: now, sleepWindow: 2 * 3600)
        }
        #expect(verdict(server).state == .idle && verdict(server).evidence.first?.contains("server") == true)
        #expect(verdict(session).state == .sleeping, "the same silence on a real session does count")

        let sessions = AgentDetector.sessions(processes: [server, session], attributor: nil, history: history, now: now)
        #expect(sessions.first { $0.root.pid == 40 }?.isService == true && sessions.first { $0.root.pid == 41 }?.isService == false)
    }

    @Test("A sleeping session is terminated automatically only when enabled; a working one never; its tool servers go with it")
    func sleepingAgentPolicy() {
        let f = Fixture()
        let project = f.dir(f.projects + "/app")
        let now = Date()
        let agent = process(500, name: "claude", path: "/Users/x/.local/bin/claude", cwd: project)
        let server = process(501, parent: 500, name: "python3", args: ["python3", "mcp-server"], cwd: project, start: 1_000_100)
        var context = AssessmentContext(processes: [agent, server], attributor: ProjectIndex([Project(id: project, name: "app", kinds: [.git])]), now: now)

        // Awake: protected, whatever the settings say.
        var awake = ProcessGuardian.assess(context).first { $0.process.pid == 500 }!
        var settings = PepelSettings()
        settings.terminateSleepingAgents = true
        let engine = CleanupPolicyEngine()
        func verdict(_ a: ProcessAssessment, _ initiator: Initiator, descendants: [ProcessAssessment] = []) -> CleanupVerdict {
            engine.evaluateTermination(a, descendants: [server], descendantAssessments: descendants, initiator: initiator, settings: settings, ownPID: 1).verdict
        }
        #expect(awake.eligibility.isNever && verdict(awake, .automatic) == .denied && verdict(awake, .user) == .denied)

        // Asleep: eligible, and the helper it owns does not block it.
        context.sleepingAgents = [agent.identity: ["Quiet for 3h."]]
        let assessed = ProcessGuardian.assess(context)
        awake = assessed.first { $0.process.pid == 500 }!
        let helper = assessed.filter { $0.process.pid == 501 }
        #expect(awake.eligibility == .automaticEligible && awake.lifecycle == .agentSession)
        #expect(helper.first?.eligibility.isNever == true)
        #expect(verdict(awake, .automatic, descendants: helper) == .allowed)
        #expect(verdict(awake, .user, descendants: helper) == .needsConfirmation)
        #expect(verdict(awake, .agent, descendants: helper) == .denied, "one agent cannot have another terminated")

        settings.terminateSleepingAgents = false
        #expect(verdict(awake, .automatic, descendants: helper) == .denied)
        // The abandoned-process switch does not unlock agent sessions.
        settings.autoTerminateAbandoned = true
        #expect(verdict(awake, .automatic, descendants: helper) == .denied)
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
