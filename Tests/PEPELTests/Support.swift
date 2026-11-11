import Foundation
@testable import PEPELCleanup
@testable import PEPELEngine

/// A throwaway directory tree standing in for a home directory. Everything a test creates or
/// deletes lives under the system temporary folder; no real developer directory is ever touched.
final class Fixture {
    let root: String
    let home: String
    let projects: String

    init() {
        root = PathUtil.canonical(NSTemporaryDirectory()) + "/pepel-" + String(UUID().uuidString.prefix(8))
        home = root + "/home"
        projects = home + "/projects"
        try! FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
    }

    deinit {
        // Directories made unreadable by permission tests must be readable again to be removed.
        if let enumerator = FileManager.default.enumerator(atPath: root) {
            for case let relative as String in enumerator { chmod(root + "/" + relative, 0o755) }
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    @discardableResult
    func dir(_ path: String) -> String {
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @discardableResult
    func file(_ path: String, bytes: Int = 64, text: String? = nil) -> String {
        dir((path as NSString).deletingLastPathComponent)
        let data = text.map { Data($0.utf8) } ?? Data(repeating: 0x41, count: bytes)
        FileManager.default.createFile(atPath: path, contents: data)
        return path
    }

    /// Back-dates a whole tree so it does not look like it is being written right now.
    func age(_ path: String, hours: Double) {
        let date = Date().addingTimeInterval(-hours * 3600)
        var targets = [path]
        if let enumerator = FileManager.default.enumerator(atPath: path) {
            for case let relative as String in enumerator { targets.append(path + "/" + relative) }
        }
        // lutimes sets the time of a symlink itself instead of following it.
        let stamp = timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0)
        for target in targets.reversed() {
            var times = [stamp, stamp]
            lutimes(target, &times)
        }
    }

    /// A directory with just enough `.git` content to be recognised as a repository.
    @discardableResult
    func gitRepo(_ path: String, branch: String = "main", remote: String? = nil) -> String {
        dir(path + "/.git/refs/heads")
        file(path + "/.git/HEAD", text: "ref: refs/heads/\(branch)\n")
        file(path + "/.git/refs/heads/\(branch)", text: "0123456789abcdef0123456789abcdef01234567\n")
        if let remote { file(path + "/.git/config", text: "[remote \"origin\"]\n\turl = \(remote)\n") }
        return path
    }

    /// A linked worktree of `main`, wired the way `git worktree add` does it.
    @discardableResult
    func worktree(of main: String, at path: String, branch: String) -> String {
        let name = (path as NSString).lastPathComponent
        let gitDir = main + "/.git/worktrees/" + name
        dir(path)
        file(gitDir + "/HEAD", text: "ref: refs/heads/\(branch)\n")
        file(gitDir + "/commondir", text: "../..\n")
        file(gitDir + "/gitdir", text: path + "/.git\n")
        file(path + "/.git", text: "gitdir: \(gitDir)\n")
        return path
    }

    func discover() -> ProjectIndex {
        ProjectIndex(ProjectDiscovery(maxDepth: 5, home: home).discover(roots: [projects]))
    }

    func scanContext(_ index: ProjectIndex? = nil, settings: PepelSettings = PepelSettings()) async -> ScanContext {
        let index = index ?? discover()
        return await ScanContext(
            home: home, temporaryDirectory: root + "/tmp", sharedTemporaryDirectory: root + "/shared-tmp", projects: index, settings: settings, now: Date(),
            tools: .disabled, hits: await ProjectArtifactWalker().walk(index, consultGit: false))
    }

    func policyContext(
        settings: PepelSettings = PepelSettings(), protections: [ProtectionRule] = [], leases: [ResourceLease] = [],
        usage: [String: String] = [:], sessions: [AgentSession] = [], projectRoots: [String] = []
    ) -> PolicyContext {
        PolicyContext(
            settings: settings, home: home, temporaryRoots: [root + "/tmp"], protections: protections, leases: leases,
            usage: usage, agentSessions: sessions, projectRoots: projectRoots, now: Date())
    }

    /// A measured, aged directory wrapped as a storage item, as an analyzer would produce it.
    func item(
        _ path: String, safety: SafetyClass = .safe, category: ArtifactCategory = .toolCache, projectID: String? = nil,
        ageHours: Double = 72
    ) -> StorageItem {
        if !PathUtil.exists(path) { file(path + "/data.bin", bytes: 4096) }
        age(path, hours: ageHours)
        return StorageItem(
            analyzerID: "test", category: category, path: path, title: (path as NSString).lastPathComponent,
            explanation: "fixture", safety: safety, safetyReason: "fixture", reproducible: true, projectID: projectID,
            projectConfidence: projectID == nil ? .unknown : .verified, size: DirectorySizer().measure(path),
            identity: PathUtil.identity(path))
    }
}

func process(
    _ pid: Int32, parent: Int32 = 1, name: String, path: String? = nil, args: [String]? = nil, cwd: String? = nil,
    start: UInt64 = 1_000_000, cpu: UInt64 = 0, tty: Bool = false, footprint: Int64 = 80_000_000, ports: [UInt16] = [],
    uid: UInt32 = getuid()
) -> ProcessSnapshot {
    ProcessSnapshot(
        identity: ProcessIdentity(pid: pid, startTime: start), parentPID: parent, uid: uid, name: name,
        executablePath: path ?? "/usr/local/bin/" + name, arguments: args ?? [name], workingDirectory: cwd,
        footprintBytes: footprint, cpuTimeNs: cpu, hasControllingTerminal: tty, listeningPorts: ports)
}

/// Observations showing a process did nothing for `minutes`.
func idleHistory(_ processes: [ProcessSnapshot], minutes: Double = 45, now: Date) -> [ProcessIdentity: [ProcessObservation]] {
    var history: [ProcessIdentity: [ProcessObservation]] = [:]
    for p in processes {
        history[p.identity] = stride(from: minutes, to: 0, by: -5).map {
            ProcessObservation(timestamp: now.addingTimeInterval(-$0 * 60), cpuTimeNs: p.cpuTimeNs, footprintBytes: p.footprintBytes)
        }
    }
    return history
}

/// A process table the tests control: nothing here signals a real process.
final class FakeProcessControl: ProcessControl, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [Int32: ProcessIdentity]
    private var stubborn: Set<Int32>
    private(set) var signals: [(pid: Int32, signal: Int32)] = []

    init(_ processes: [ProcessIdentity], ignoringSIGTERM: Set<Int32> = []) {
        table = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        stubborn = ignoringSIGTERM
    }

    func identity(of pid: Int32) -> ProcessIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return table[pid]
    }

    func send(_ signal: Int32, to pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        signals.append((pid, signal))
        guard table[pid] != nil else { return false }
        if signal == SIGKILL || !stubborn.contains(pid) { table[pid] = nil }
        return true
    }

    var sent: [(pid: Int32, signal: Int32)] {
        lock.lock()
        defer { lock.unlock() }
        return signals
    }
}

/// A process table held in memory. Signals only ever change this table.
final class FakeProcessSource: ProcessSource, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [ProcessSnapshot]
    private var delivered: [(pid: Int32, signal: Int32)] = []

    init(processes: [ProcessSnapshot]) { table = processes }

    func snapshot() -> [ProcessSnapshot] { lock.lock(); defer { lock.unlock() }; return table }
    func listeningPorts(of pid: Int32) -> [UInt16] { snapshot().first { $0.pid == pid }?.listeningPorts ?? [] }
    func identity(of pid: Int32) -> ProcessIdentity? { snapshot().first { $0.pid == pid }?.identity }

    func send(_ signal: Int32, to pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        delivered.append((pid, signal))
        guard table.contains(where: { $0.pid == pid }) else { return false }
        if signal == SIGSTOP || signal == SIGCONT { return true }
        table.removeAll { $0.pid == pid }
        return true
    }

    var signals: [(pid: Int32, signal: Int32)] { lock.lock(); defer { lock.unlock() }; return delivered }

    func clearSignals() { lock.lock(); delivered = []; lock.unlock() }

    /// Changes one process in the table, as if it had run for a while.
    func mutate(_ pid: Int32, _ change: (inout ProcessSnapshot) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if let index = table.firstIndex(where: { $0.pid == pid }) { change(&table[index]) }
    }
}

extension CleanupExecutor {
    /// Runs approvals with a fixed context, as the engine would with a live one.
    func run(_ approved: [ApprovedAction], dryRun: Bool, context: PolicyContext) async -> CleanupReport {
        await execute(approved, dryRun: dryRun, freshContext: { _ in context }, validate: { _ in nil }, diskAvailable: { 0 })
    }
}
