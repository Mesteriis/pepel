import Foundation
import PEPELCore

/// Remembers which processes each running application started, so that when the application
/// quits PEPEL can say what it left behind.
///
/// macOS frees a process's memory the moment it exits; there is nothing to "clean" after a clean
/// quit. What does keep memory is whatever outlives the application: helpers, renderers, tools it
/// spawned. Those are found here from two kinds of direct evidence: PEPEL saw the process running
/// as a descendant of the application, or its executable sits inside the application's bundle.
public struct AppExitTracker: Codable, Sendable, Equatable {
    public struct TrackedApp: Codable, Sendable, Equatable {
        public var bundlePath: String
        public var name: String
        public var mains: [ProcessIdentity]
        /// Descendants seen while the application ran.
        public var members: [ProcessIdentity]
        public var lastSeen: Date
        public var quitAt: Date?
    }

    public private(set) var apps: [String: TrackedApp] = [:]

    /// Wait this long after a quit before calling anything a leftover: applications take a
    /// moment to shut their helpers down.
    public static let settleSeconds: TimeInterval = 60
    static let memberLimit = 400
    static let appLimit = 250

    public init() {}

    /// The bundle a process is the *main executable* of (`X.app/Contents/MacOS/x`), not a helper
    /// nested deeper inside it.
    static func mainBundle(of p: ProcessSnapshot) -> (path: String, name: String)? {
        guard let path = p.executablePath, let bundle = MemoryAttributor.applicationBundle(of: path) else { return nil }
        let rest = path.dropFirst(bundle.path.count + 1)
        guard rest.hasPrefix("Contents/MacOS/"), !rest.dropFirst("Contents/MacOS/".count).contains("/") else { return nil }
        return bundle
    }

    /// Parts of a bundle that macOS itself starts and stops; their lifetime is not the application's.
    static func isSystemManagedComponent(_ path: String) -> Bool {
        ["/XPCServices/", ".appex/", "/LoginItems/", "/Library/LaunchServices/", "/PlugIns/", ".xpc/"].contains { path.contains($0) }
    }

    /// Call with every process-table sample.
    public mutating func update(processes: [ProcessSnapshot], now: Date) {
        let tree = ProcessTree(processes)
        let alive = Set(processes.map(\.identity))
        var running: [String: (name: String, mains: [ProcessSnapshot])] = [:]
        for p in processes {
            guard let bundle = Self.mainBundle(of: p) else { continue }
            running[bundle.path, default: (bundle.name, [])].mains.append(p)
        }

        for (path, app) in running {
            var record = apps[path] ?? TrackedApp(bundlePath: path, name: app.name, mains: [], members: [], lastSeen: now, quitAt: nil)
            var members = Set(record.members).intersection(alive)
            for main in app.mains { members.formUnion(tree.descendants(of: main).map(\.identity)) }
            record.mains = app.mains.map(\.identity)
            record.members = Array(members.sorted { ($0.startTime, $0.pid) > ($1.startTime, $1.pid) }.prefix(Self.memberLimit))
            record.lastSeen = now
            record.quitAt = nil  // running (again): whatever was noted before no longer applies
            apps[path] = record
        }

        for (path, var record) in apps where running[path] == nil {
            if record.quitAt == nil { record.quitAt = now }
            record.members.removeAll { !alive.contains($0) }
            // Forget a quit application once nothing of it is left to track.
            if record.members.isEmpty, now.timeIntervalSince(record.quitAt ?? now) > 3600 {
                apps[path] = nil
            } else {
                apps[path] = record
            }
        }
        if apps.count > Self.appLimit {
            for (path, _) in apps.sorted(by: { $0.value.lastSeen < $1.value.lastSeen }).prefix(apps.count - Self.appLimit) { apps[path] = nil }
        }
    }

    /// What quit applications left running.
    /// - Parameters:
    ///   - assessments: the guardian's view of developer processes; where it has an opinion, it wins.
    ///   - protectedTrees: roots (agent sessions) whose whole process tree is governed by other rules.
    public func leftovers(
        processes: [ProcessSnapshot], assessments: [ProcessAssessment], protectedRoots: Set<ProcessIdentity>,
        attributor: (any ProjectAttributing)?, now: Date, automaticAfter: TimeInterval, ownPID: Int32 = getpid()
    ) -> [AppLeftovers] {
        let tree = ProcessTree(processes)
        let assessed = Dictionary(assessments.map { ($0.process.identity, $0) }, uniquingKeysWith: { a, _ in a })
        var groups: [AppLeftovers] = []

        for record in apps.values {
            guard let quitAt = record.quitAt, now.timeIntervalSince(quitAt) >= Self.settleSeconds else { continue }
            let members = Set(record.members)
            let prefix = record.bundlePath + "/"
            var candidates: [(ProcessSnapshot, observed: Bool, inside: Bool)] = []
            for p in processes where p.pid != ownPID {
                let path = p.executablePath ?? ""
                let observed = members.contains(p.identity)
                let inside = path.hasPrefix(prefix)
                guard observed || inside, !Self.isSystemManagedComponent(path) else { continue }
                // Agent sessions and everything under them follow the agent rules, not this one.
                if RoleClassifier.agentKind(of: p) != nil || protectedRoots.contains(p.identity) { continue }
                if tree.ancestors(of: p).contains(where: { protectedRoots.contains($0.identity) }) { continue }
                candidates.append((p, observed, inside))
            }
            // A leftover's own children go down with it; list only the top of each tree.
            let ids = Set(candidates.map { $0.0.identity })
            let tops = candidates.filter { candidate in !tree.ancestors(of: candidate.0).contains { ids.contains($0.identity) } }

            let found = tops.map { p, observed, inside -> ProcessAssessment in
                let descendants = tree.descendants(of: p)
                let role = RoleClassifier.role(of: p, attributor: attributor)
                var evidence = [L("\(record.name) quit \(TimeFormat.ago(quitAt, now: now)); this process is still running.")]
                if observed { evidence.append(L("PEPEL saw it running as a child of \(record.name).")) }
                if inside { evidence.append(L("Its executable is inside \(record.name).app.")) }
                if !p.listeningPorts.isEmpty { evidence.append(L("Listening on port \(p.listeningPorts.map(String.init).joined(separator: ", ")).")) }

                let eligibility: TerminationEligibility
                if role == .container {
                    eligibility = .never(reason: L("Container runtimes are managed through their own tools."))
                } else if role == .system {
                    eligibility = .never(reason: L("System process."))
                } else if let existing = assessed[p.identity] {
                    // The guardian already judged this developer process; a quit parent does not make it safer.
                    evidence += existing.evidence
                    eligibility = existing.eligibility == .automaticEligible
                        ? .approvalRequired(warning: L("It is a developer process; it is not terminated just because its application quit."))
                        : existing.eligibility
                } else if now.timeIntervalSince(quitAt) >= automaticAfter {
                    eligibility = .automaticEligible
                } else {
                    eligibility = .approvalRequired(warning: L("Some applications leave a helper running on purpose, for syncing or updates."))
                }
                var assessment = ProcessAssessment(
                    process: p, role: role, lifecycle: .abandonedSubprocess, confidence: .verified,
                    projectID: assessed[p.identity]?.projectID, projectConfidence: assessed[p.identity]?.projectConfidence ?? .unknown,
                    evidence: evidence, eligibility: eligibility, descendantCount: descendants.count,
                    subtreeFootprintBytes: descendants.reduce(p.footprintBytes) { $0 + $1.footprintBytes })
                assessment.leftoverOf = record.name
                return assessment
            }
            if !found.isEmpty {
                groups.append(
                    AppLeftovers(
                        id: record.bundlePath, appName: record.name, quitAt: quitAt,
                        processes: found.sorted { $0.subtreeFootprintBytes > $1.subtreeFootprintBytes }))
            }
        }
        return groups.sorted { ($0.footprintBytes, $0.id) > ($1.footprintBytes, $1.id) }
    }
}
