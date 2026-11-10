import Foundation
import PEPELCore

public enum RetentionVerdict: Codable, Sendable, Hashable {
    case keep(reason: String)
    case candidate(reason: String)

    public var isCandidate: Bool {
        if case .candidate = self { return true }
        return false
    }

    public var reason: String {
        switch self {
        case .keep(let reason), .candidate(let reason): reason
        }
    }
}

/// One build generation as the retention rules see it.
public struct GenerationInput: Sendable, Hashable {
    public var id: String
    public var timestamp: Date?
    public var status: BuildStatus
    public var sizeBytes: Int64
    public var isActive: Bool
    public var isPinned: Bool
    public var sourceMissing: Bool

    public init(
        id: String, timestamp: Date?, status: BuildStatus = .unknown, sizeBytes: Int64 = 0, isActive: Bool = false,
        isPinned: Bool = false, sourceMissing: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.status = status
        self.sizeBytes = sizeBytes
        self.isActive = isActive
        self.isPinned = isPinned
        self.sourceMissing = sourceMissing
    }
}

/// Applies a retention policy to the build generations of one project. Pure and deterministic.
///
/// Builds whose outcome PEPEL did not observe (`unknown`) count as potentially good: they are
/// kept under the "successful" quota rather than assumed disposable.
public enum RetentionEngine {
    public static func evaluate(_ generations: [GenerationInput], policy: RetentionPolicy, now: Date) -> [String: RetentionVerdict] {
        var verdicts: [String: RetentionVerdict] = [:]
        // Newest first; generations without a timestamp sort last and are kept (age unknown).
        let ordered = generations.sorted { ($0.timestamp ?? .distantPast, $0.id) > ($1.timestamp ?? .distantPast, $1.id) }
        let reviewAfter = TimeInterval(policy.reviewAfterHours) * 3600
        var goodKept = 0
        var failedKept = 0
        var lastKnownGoodSeen = false
        var hardKeeps = Set<String>()

        for (position, g) in ordered.enumerated() {
            let age = g.timestamp.map { now.timeIntervalSince($0) }
            if g.isActive {
                verdicts[g.id] = .keep(reason: "Build is active.")
                hardKeeps.insert(g.id)
                continue
            }
            if g.isPinned {
                verdicts[g.id] = .keep(reason: "Pinned by you.")
                hardKeeps.insert(g.id)
                continue
            }
            if g.sourceMissing {
                verdicts[g.id] = .candidate(reason: "The source it was built from no longer exists.")
                continue
            }
            guard let age else {
                verdicts[g.id] = .keep(reason: "Its age could not be determined.")
                hardKeeps.insert(g.id)
                continue
            }

            var keep: String?
            if position == 0 {
                keep = "Most recent build."
                hardKeeps.insert(g.id)
            }
            switch g.status {
            case .failed:
                if failedKept < policy.keepFailed {
                    failedKept += 1
                    keep = keep ?? "One of the last \(policy.keepFailed) failed build\(policy.keepFailed == 1 ? "" : "s")."
                }
            case .running:
                keep = "Build is running."
                hardKeeps.insert(g.id)
            case .succeeded, .unknown:
                if g.status == .succeeded, policy.protectLastKnownGood, !lastKnownGoodSeen {
                    lastKnownGoodSeen = true
                    keep = keep ?? "Last known good build."
                    hardKeeps.insert(g.id)
                }
                if goodKept < policy.keepSuccessful {
                    goodKept += 1
                    keep = keep ?? "One of the last \(policy.keepSuccessful) builds."
                }
            }
            if keep == nil, age < reviewAfter {
                keep = "Newer than \(policy.reviewAfterHours) hours."
            }
            if let maxAge = policy.maxAgeDays, age > TimeInterval(maxAge) * 86_400, !hardKeeps.contains(g.id) {
                verdicts[g.id] = .candidate(reason: "Older than \(maxAge) days.")
                continue
            }
            verdicts[g.id] = keep.map { .keep(reason: $0) } ?? .candidate(reason: "Superseded by newer builds and older than \(policy.reviewAfterHours) hours.")
        }

        // Budget: propose the oldest generations that are not hard-protected until the project fits.
        if let budget = policy.budgetBytes {
            var kept = ordered.filter { !(verdicts[$0.id]?.isCandidate ?? false) }.reduce(Int64(0)) { $0 + $1.sizeBytes }
            for g in ordered.reversed() where kept > budget {
                guard !(verdicts[g.id]?.isCandidate ?? true), !hardKeeps.contains(g.id), let timestamp = g.timestamp,
                    now.timeIntervalSince(timestamp) >= reviewAfter
                else { continue }
                verdicts[g.id] = .candidate(reason: "The project exceeds its build budget of \(Bytes.format(budget)).")
                kept -= g.sizeBytes
            }
        }
        return verdicts
    }
}
