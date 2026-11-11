import Foundation
import PEPELCore
import PEPELProcesses

/// Decides whether an agent session is working, idle or asleep.
///
/// Measured on real sessions over a night:
/// - CPU alone does not separate them. An idle session sits at 0.3–0.5 % of a core because of
///   its tool servers' polling, and so does a working one between replies.
/// - Any disk write does not either. An idle Claude Code session writes 8–24 KB about once an
///   hour (occasionally 130–250 KB) as housekeeping, with CPU still at its idle level.
/// - Real work looks different on both axes at once: hundreds of kilobytes written in
///   neighbouring intervals, with CPU at 1–5 %.
///
/// So an interval counts as activity when the process wrote to disk *and* either used clearly
/// more CPU than its own idle level or wrote again within a few minutes. A real CPU burst, a
/// newly started process and a running build count on their own.
public enum AgentActivity {
    /// Bytes written in an interval, or across a cluster of intervals, that count as work.
    /// Housekeeping writes of idle sessions were 8–24 KB; working intervals started at 76 KB.
    public static let writeThresholdBytes: UInt64 = 64 * 1024
    /// Observations are merged into intervals at least this long before anything is judged.
    /// The thresholds were measured on minute-long intervals; over a 20-second sample even a
    /// housekeeping tick looks like a CPU rise.
    public static let minimumIntervalSeconds: TimeInterval = 60
    /// A write counts as work when CPU in the same interval reaches this, or twice the process's
    /// own median, whichever is higher. Housekeeping writes were seen at up to 0.48 %.
    public static let workingCPUPercent = 0.8
    /// Two writes this close together count as work even at idle CPU.
    public static let writeClusterSeconds: TimeInterval = 180
    /// Share of one core, between two observations, that counts as a burst on its own.
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

        struct Interval {
            var end: Date
            var cpuPercent: Double
            var written: UInt64
            var noBaseline: Bool
        }
        // Resample so every interval spans at least a minute (the last one may be shorter).
        var resampled: [ProcessObservation] = []
        for point in points {
            if let last = resampled.last, point.timestamp.timeIntervalSince(last.timestamp) < minimumIntervalSeconds { continue }
            resampled.append(point)
        }
        if let final = points.last, resampled.last?.timestamp != final.timestamp {
            // Fold the trailing short stretch into the previous interval rather than judging it alone.
            if resampled.count > 1 { resampled.removeLast() }
            resampled.append(final)
        }

        var intervals: [Interval] = []
        for (previous, current) in zip(resampled, resampled.dropFirst()) {
            let span = current.timestamp.timeIntervalSince(previous.timestamp)
            guard span > 0 else { continue }
            let cpu = current.cpuTimeNs >= previous.cpuTimeNs ? Double(current.cpuTimeNs - previous.cpuTimeNs) / 1e9 / span * 100 : 0
            let written = current.diskBytesWritten >= previous.diskBytesWritten ? current.diskBytesWritten - previous.diskBytesWritten : 0
            // No baseline: the earlier row predates write accounting, or the process had never
            // written. Nothing is known about before, so the quiet clock starts here.
            intervals.append(Interval(end: current.timestamp, cpuPercent: cpu, written: written, noBaseline: previous.diskBytesWritten == 0 && current.diskBytesWritten >= writeThresholdBytes))
        }
        let sortedCPU = intervals.map(\.cpuPercent).sorted()
        let median = sortedCPU.isEmpty ? 0 : sortedCPU[sortedCPU.count / 2]
        let workingCPU = max(workingCPUPercent, 2 * median)

        var latest: (Date, String)?
        for (index, interval) in intervals.enumerated() {
            if interval.noBaseline {
                latest = (interval.end, "PEPEL began tracking disk writes of \(p.name) (PID \(p.pid)); the quiet clock starts here")
                continue
            }
            if interval.cpuPercent >= burstPercent {
                latest = (interval.end, String(format: "%@ (PID %d) used %.0f%% of a core", p.name, p.pid, interval.cpuPercent))
                continue
            }
            guard interval.written > 0 else { continue }
            /// Bytes written in a neighbouring interval that ended within the cluster window.
            func nearby(_ other: Int) -> UInt64 {
                guard intervals.indices.contains(other), !intervals[other].noBaseline,
                    abs(intervals[other].end.timeIntervalSince(interval.end)) <= writeClusterSeconds
                else { return 0 }
                return intervals[other].written
            }
            let before = nearby(index - 1), after = nearby(index + 1)
            let clustered = (before > 0 || after > 0) && interval.written + before + after >= writeThresholdBytes
            if (interval.written >= writeThresholdBytes && interval.cpuPercent >= workingCPU) || clustered {
                latest = (interval.end, "\(p.name) (PID \(p.pid)) wrote \(Bytes.format(Int64(interval.written))) to disk while working")
            }
            // Otherwise: a lone small write at idle CPU, the hourly housekeeping of an idle session.
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
                ?? "No sign of work in \(TimeFormat.age(observedFor)) of observation: no writes beyond housekeeping, no CPU bursts, no new processes."
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
