import Foundation
import PEPELCore
import PEPELProcesses

/// Decides whether an agent session is working, idle or asleep.
///
/// Measured on real sessions, CPU alone does not tell them apart: an idle session still spends
/// 0.3–0.7 % of a core on its tool servers' polling, the same as a working one that is waiting
/// on a command. Disk writes do: a working session writes its transcript, an idle one writes
/// nothing. So the signal is, per process of the session: bytes written, a real CPU burst, or
/// the process having been started recently.
public enum AgentActivity {
    /// Bytes written between two observations that count as activity. Above zero so a stray
    /// metadata update does not keep a session awake.
    public static let writeThresholdBytes: UInt64 = 16 * 1024
    /// Share of one core, between two observations, that counts as a burst rather than polling.
    public static let burstPercent = 5.0
    /// A session active this recently is "working".
    public static let workingWindow: TimeInterval = 5 * 60

    /// Sub-commands that make an agent binary a server instead of a session.
    static let serviceTokens: Set<String> = ["app-server", "exec-server", "mcp-server", "serve", "server", "daemon", "proxy"]

    /// Whether this agent process is infrastructure for an application rather than a session.
    public static func isService(_ p: ProcessSnapshot) -> Bool {
        !Set(p.arguments.dropFirst().prefix(12).map { $0.lowercased() }).isDisjoint(with: serviceTokens)
    }

    public struct Verdict: Sendable, Equatable {
        public var state: AgentActivityState
        public var quietSince: Date?
        public var observedFor: TimeInterval
        public var evidence: [String]
    }

    /// Latest moment a process showed activity in its observation history.
    static func lastActivity(of p: ProcessSnapshot, history: [ProcessObservation], now: Date) -> (date: Date, what: String)? {
        var points = history
        points.append(ProcessObservation(timestamp: now, cpuTimeNs: p.cpuTimeNs, footprintBytes: p.footprintBytes, diskBytesWritten: p.diskBytesWritten))
        var latest: (Date, String)?
        for (previous, current) in zip(points, points.dropFirst()) {
            let span = current.timestamp.timeIntervalSince(previous.timestamp)
            guard span > 0 else { continue }
            if previous.diskBytesWritten == 0, current.diskBytesWritten >= writeThresholdBytes {
                // No baseline: either the process had never written, or the earlier row predates
                // write accounting. Either way nothing is known about before, so the quiet clock
                // starts here. That errs towards "active", the safe direction.
                latest = (current.timestamp, "PEPEL began tracking disk writes of \(p.name) (PID \(p.pid)); the quiet clock starts here")
            } else if current.diskBytesWritten >= previous.diskBytesWritten &+ writeThresholdBytes {
                latest = (current.timestamp, "\(p.name) (PID \(p.pid)) wrote \(Bytes.format(Int64(current.diskBytesWritten - previous.diskBytesWritten))) to disk")
            } else if current.cpuTimeNs >= previous.cpuTimeNs,
                Double(current.cpuTimeNs - previous.cpuTimeNs) / 1e9 / span * 100 >= burstPercent
            {
                latest = (current.timestamp, "\(p.name) (PID \(p.pid)) used CPU")
            }
        }
        return latest
    }

    public static func verdict(
        root: ProcessSnapshot, members: [ProcessSnapshot], history: [ProcessIdentity: [ProcessObservation]],
        activeBuildCount: Int, hasActiveLease: Bool, now: Date, sleepWindow: TimeInterval
    ) -> Verdict {
        let rootHistory = history[root.identity] ?? []
        let observedSince = rootHistory.first?.timestamp ?? now
        let observedFor = now.timeIntervalSince(observedSince)

        var last: (date: Date, what: String)?
        func consider(_ candidate: (date: Date, what: String)?) {
            guard let candidate else { return }
            if last == nil || candidate.date > last!.date { last = candidate }
        }
        for p in [root] + members {
            consider(lastActivity(of: p, history: history[p.identity] ?? [], now: now))
            // A process the session started while PEPEL was watching is activity in itself.
            if p.identity != root.identity, p.identity.startDate > observedSince {
                consider((p.identity.startDate, "it started \(p.name) (PID \(p.pid))"))
            }
        }

        if isService(root) {
            return Verdict(
                state: .idle, quietSince: last?.date, observedFor: observedFor,
                evidence: ["Runs as a server (\(root.arguments.dropFirst().first { serviceTokens.contains($0.lowercased()) } ?? "service")) for another program; servers are never treated as asleep."])
        }
        if activeBuildCount > 0 {
            return Verdict(state: .working, quietSince: nil, observedFor: observedFor, evidence: ["A build or test is running under this session."])
        }
        if let last, now.timeIntervalSince(last.date) < workingWindow {
            return Verdict(state: .working, quietSince: nil, observedFor: observedFor, evidence: ["\(TimeFormat.ago(last.date, now: now)): \(last.what)."])
        }

        // Quiet since the last activity seen, or since PEPEL started watching if none was seen.
        let quietSince = last?.date ?? observedSince
        let quietFor = now.timeIntervalSince(quietSince)
        var evidence = [
            last.map { "Last activity \(TimeFormat.ago($0.date, now: now)): \($0.what)." }
                ?? "No disk writes, CPU bursts or new processes in \(TimeFormat.age(observedFor)) of observation."
        ]
        if hasActiveLease {
            evidence.append("It holds an active resource lease.")
            return Verdict(state: .idle, quietSince: quietSince, observedFor: observedFor, evidence: evidence)
        }
        guard quietFor >= sleepWindow, observedFor >= sleepWindow else {
            evidence.append("Counts as asleep after \(TimeFormat.age(sleepWindow)) of quiet; \(TimeFormat.age(max(0, sleepWindow - min(quietFor, observedFor)))) to go.")
            return Verdict(state: .idle, quietSince: quietSince, observedFor: observedFor, evidence: evidence)
        }
        evidence.append("Quiet for \(TimeFormat.age(quietFor)), longer than the \(TimeFormat.age(sleepWindow)) sleep threshold.")
        return Verdict(state: .sleeping, quietSince: quietSince, observedFor: observedFor, evidence: evidence)
    }
}
