import Foundation
import PEPELCore

/// Parent/child structure of one process-table snapshot.
///
/// A parent link is only trusted when the parent started no later than the child: a "parent" that
/// is younger than its child is a different process that reused the PID.
public struct ProcessTree: Sendable {
    public let byPID: [Int32: ProcessSnapshot]
    private let childMap: [Int32: [Int32]]

    public init(_ processes: [ProcessSnapshot]) {
        var byPID: [Int32: ProcessSnapshot] = [:]
        for p in processes { byPID[p.pid] = p }
        var children: [Int32: [Int32]] = [:]
        for p in processes {
            guard let parent = byPID[p.parentPID], parent.identity.startTime <= p.identity.startTime, parent.pid != p.pid
            else { continue }
            children[parent.pid, default: []].append(p.pid)
        }
        self.byPID = byPID
        self.childMap = children
    }

    public func process(_ identity: ProcessIdentity) -> ProcessSnapshot? {
        guard let p = byPID[identity.pid], p.identity == identity else { return nil }
        return p
    }

    /// The live parent, or nil when the process was orphaned or the parent PID was reused.
    public func parent(of p: ProcessSnapshot) -> ProcessSnapshot? {
        guard p.parentPID > 1, let parent = byPID[p.parentPID], parent.identity.startTime <= p.identity.startTime,
            parent.pid != p.pid
        else { return nil }
        return parent
    }

    /// True when the process has been reparented to launchd or its parent is gone.
    public func isOrphan(_ p: ProcessSnapshot) -> Bool { parent(of: p) == nil }

    public func ancestors(of p: ProcessSnapshot) -> [ProcessSnapshot] {
        var result: [ProcessSnapshot] = []
        var current = p
        var seen: Set<Int32> = [p.pid]
        while let next = parent(of: current), seen.insert(next.pid).inserted {
            result.append(next)
            current = next
        }
        return result
    }

    public func children(of p: ProcessSnapshot) -> [ProcessSnapshot] {
        (childMap[p.pid] ?? []).compactMap { byPID[$0] }
    }

    /// All descendants, children before grandchildren.
    public func descendants(of p: ProcessSnapshot) -> [ProcessSnapshot] {
        var result: [ProcessSnapshot] = []
        var queue = [p.pid]
        var seen: Set<Int32> = [p.pid]
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            for child in childMap[pid] ?? [] where seen.insert(child).inserted {
                if let c = byPID[child] { result.append(c) }
                queue.append(child)
            }
        }
        return result
    }
}

public enum ActivityVerdict: Sendable, Equatable {
    /// Observed across at least the required window with negligible CPU use.
    case idle(observedFor: TimeInterval)
    case active(cpuPercent: Double)
    /// Not watched long enough to say.
    case insufficientHistory(observedFor: TimeInterval)
}

public enum ActivityAnalyzer {
    /// Below this average share of one core a process counts as idle.
    public static let idleThresholdPercent = 0.5

    public static func verdict(
        current: ProcessSnapshot, history: [ProcessObservation], now: Date, window: TimeInterval
    ) -> ActivityVerdict {
        guard let first = history.first(where: { $0.timestamp <= now }) else {
            return .insufficientHistory(observedFor: 0)
        }
        let observed = now.timeIntervalSince(first.timestamp)
        // Judge the most recent `window`; an early burst followed by a long silence is still idle.
        let cutoff = now.addingTimeInterval(-window)
        let baseline = history.last(where: { $0.timestamp <= cutoff }) ?? first
        let span = now.timeIntervalSince(baseline.timestamp)
        guard span > 0, current.cpuTimeNs >= baseline.cpuTimeNs else { return .insufficientHistory(observedFor: observed) }
        let percent = Double(current.cpuTimeNs - baseline.cpuTimeNs) / 1e9 / span * 100
        if percent >= idleThresholdPercent { return .active(cpuPercent: percent) }
        return observed >= window ? .idle(observedFor: observed) : .insufficientHistory(observedFor: observed)
    }

    /// CPU share since the previous observation.
    public static func recentPercent(current: ProcessSnapshot, history: [ProcessObservation], now: Date) -> Double? {
        guard let previous = history.last(where: { now.timeIntervalSince($0.timestamp) >= 1 }),
            current.cpuTimeNs >= previous.cpuTimeNs
        else { return nil }
        return Double(current.cpuTimeNs - previous.cpuTimeNs) / 1e9 / now.timeIntervalSince(previous.timestamp) * 100
    }
}
