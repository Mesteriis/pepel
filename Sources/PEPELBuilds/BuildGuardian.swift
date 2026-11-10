import Foundation
import PEPELCore

public struct BuildGeneration: Codable, Sendable, Identifiable, Hashable {
    /// Identifier of the storage item holding the artifacts.
    public var id: String
    public var title: String
    public var path: String
    public var system: BuildSystem
    public var configuration: String?
    public var branch: String?
    public var commit: String?
    public var status: BuildStatus
    /// Newest modification inside the artifact directory.
    public var timestamp: Date?
    public var sizeBytes: Int64
    public var sizeIsApproximate: Bool
    public var activeReason: String?
    public var isPinned: Bool
    public var reproducible: Bool
    public var verdict: RetentionVerdict

    public var isActive: Bool { activeReason != nil }
    public var isProtected: Bool { isPinned || (!isActive && !verdict.isCandidate) }
}

public struct ProjectBuildSummary: Codable, Sendable, Identifiable, Hashable {
    /// Repository group, so worktrees of one repository are reported together.
    public var id: String
    public var name: String
    /// False when the artifacts could not be tied to a known project.
    public var attributed: Bool
    public var generations: [BuildGeneration]
    public var totalBytes: Int64
    public var budgetBytes: Int64?
    public var policy: RetentionPolicy

    public var activeCount: Int { generations.filter(\.isActive).count }
    public var candidateCount: Int { generations.filter { !$0.isActive && $0.verdict.isCandidate }.count }
    public var protectedCount: Int { generations.count - activeCount - candidateCount }
    public var candidateBytes: Int64 { generations.filter { !$0.isActive && $0.verdict.isCandidate }.reduce(0) { $0 + $1.sizeBytes } }
    public var budgetFraction: Double? { budgetBytes.flatMap { $0 > 0 ? Double(totalBytes) / Double($0) : nil } }
    public var overBudget: Bool { (budgetFraction ?? 0) > 1 }
    /// Approaching the budget: worth a warning before it is exceeded.
    public var nearBudget: Bool { (budgetFraction ?? 0) >= 0.8 }

    /// "Makosh has 11 detected build generations consuming 142 GB. Three are protected, …"
    public var narrative: String {
        let count = generations.count
        var text = "\(name) has \(count) detected build generation\(count == 1 ? "" : "s") consuming \(Bytes.format(totalBytes))."
        func clause(_ n: Int, _ singular: String, _ plural: String) -> String? {
            n == 0 ? nil : "\(NumberWords.spell(n)) \(n == 1 ? singular : plural)"
        }
        let parts = [
            clause(protectedCount, "is protected", "are protected"),
            clause(activeCount, "appears active", "appear active"),
            clause(candidateCount, "is a candidate for cleanup", "are candidates for cleanup"),
        ].compactMap { $0 }
        if !parts.isEmpty {
            let joined = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + ", and " + parts[parts.count - 1] : parts[0]
            text += " " + joined.prefix(1).uppercased() + joined.dropFirst() + "."
        }
        if let budgetBytes, overBudget {
            text += " This is over the \(Bytes.format(budgetBytes)) budget."
        } else if let budgetBytes, nearBudget {
            text += " This is close to the \(Bytes.format(budgetBytes)) budget."
        }
        return text
    }
}

public struct BuildReport: Sendable {
    public var summaries: [ProjectBuildSummary]
    /// The scanned items with retention verdicts applied to their safety classification.
    public var items: [StorageItem]
    public var totalBytes: Int64
    public var globalBudgetBytes: Int64

    public var overGlobalBudget: Bool { totalBytes > globalBudgetBytes }
}

/// Groups build artifacts into generations per repository and applies retention policies.
public enum BuildGuardian {
    public static let unattributedGroup = "unattributed"

    static func system(forCommand command: String) -> BuildSystem? {
        let first = (command.split(separator: " ").first.map(String.init) ?? "") as NSString
        switch first.lastPathComponent {
        case "swift": return .swiftpm
        case "xcodebuild": return .xcode
        case "cargo": return .cargo
        case "go": return .go
        case "npm", "pnpm", "yarn", "bun", "vite", "next", "npx": return .node
        case "python", "python3", "pip", "uv", "poetry": return .python
        case "cmake": return .cmake
        case "ninja": return .ninja
        case "make", "gmake": return .make
        default: return nil
        }
    }

    /// Outcome of the wrapper-recorded build that produced this generation, if one matches.
    static func observedStatus(for item: StorageItem, records: [BuildRecord], isAlive: (Int32) -> Bool) -> BuildStatus? {
        guard let projectID = item.projectID, let build = item.build else { return nil }
        let matching = records.filter { $0.projectID == projectID && system(forCommand: $0.command) == build.system }
        if matching.contains(where: { $0.exitCode == nil && isAlive($0.wrapperPID) }) { return .running }
        guard let modified = item.lastModified else { return nil }
        // The record whose run window contains the artifact's last write.
        let hit = matching.first { record in
            guard let finished = record.finishedAt else { return false }
            return modified >= record.startedAt.addingTimeInterval(-60) && modified <= finished.addingTimeInterval(60)
        }
        return hit?.status
    }

    public static func report(
        items: [StorageItem], projects: any ProjectAttributing, groupName: (String) -> String?, records: [BuildRecord] = [],
        pinned: Set<String> = [], activity: [String: String] = [:], settings: PepelSettings, now: Date = Date(),
        isAlive: (Int32) -> Bool = { kill($0, 0) == 0 }
    ) -> BuildReport {
        var grouped: [String: [StorageItem]] = [:]
        var mainProject: [String: String] = [:]
        for item in items where item.build != nil {
            let group = item.projectID.flatMap { projects.attribute(path: $0)?.groupID } ?? unattributedGroup
            grouped[group, default: []].append(item)
            if let projectID = item.projectID { mainProject[group] = mainProject[group] ?? projectID }
        }

        var verdictByItem: [String: RetentionVerdict] = [:]
        var summaries: [ProjectBuildSummary] = []
        for (group, members) in grouped {
            let policy = group == unattributedGroup ? settings.defaultRetention : settings.retention(for: mainProject[group])
            var statuses: [String: BuildStatus] = [:]
            let inputs = members.map { item -> GenerationInput in
                let status = observedStatus(for: item, records: records, isAlive: isAlive) ?? item.build?.status ?? .unknown
                statuses[item.id] = status
                return GenerationInput(
                    id: item.id, timestamp: item.lastModified, status: status, sizeBytes: item.occupiedBytes,
                    isActive: activity[item.id] != nil || status == .running, isPinned: pinned.contains(item.path),
                    sourceMissing: item.build?.sourceMissing ?? false)
            }
            // Artifacts PEPEL cannot tie to a project are never ranked against each other.
            let verdicts =
                group == unattributedGroup
                ? Dictionary(uniqueKeysWithValues: inputs.map { input -> (String, RetentionVerdict) in
                    if input.isActive { return (input.id, .keep(reason: "Build is active.")) }
                    if input.isPinned { return (input.id, .keep(reason: "Pinned by you.")) }
                    return (input.id, input.sourceMissing
                        ? .candidate(reason: "The source it was built from no longer exists.")
                        : .keep(reason: "Not associated with a known project; retention rules are not applied."))
                })
                : RetentionEngine.evaluate(inputs, policy: policy, now: now)

            let generations = members.map { item in
                BuildGeneration(
                    id: item.id, title: item.title, path: item.path, system: item.build?.system ?? .other,
                    configuration: item.build?.configuration, branch: item.build?.branch, commit: item.build?.commit,
                    status: statuses[item.id] ?? .unknown, timestamp: item.lastModified, sizeBytes: item.occupiedBytes,
                    sizeIsApproximate: item.size?.isApproximate ?? true,
                    activeReason: activity[item.id] ?? (statuses[item.id] == .running ? "A wrapped build is running." : nil),
                    isPinned: pinned.contains(item.path), reproducible: item.reproducible,
                    verdict: verdicts[item.id] ?? .keep(reason: "Not evaluated."))
            }.sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
            for g in generations { verdictByItem[g.id] = g.verdict }

            summaries.append(
                ProjectBuildSummary(
                    id: group, name: group == unattributedGroup ? "Unattributed builds" : (groupName(group) ?? (group as NSString).lastPathComponent),
                    attributed: group != unattributedGroup, generations: generations,
                    totalBytes: generations.reduce(0) { $0 + $1.sizeBytes },
                    budgetBytes: group == unattributedGroup ? nil : policy.budgetBytes, policy: policy))
        }

        let adjusted = items.map { item -> StorageItem in
            guard item.build != nil, let verdict = verdictByItem[item.id], item.safety != .protected else { return item }
            var copy = item
            switch verdict {
            case .keep(let reason):
                // Kept generations stay reviewable, never automatic.
                copy.safety = .review
                copy.safetyReason = "Retention keeps it: \(reason)"
            case .candidate(let reason):
                let sourceGone = item.build?.sourceMissing ?? false
                copy.safety = sourceGone || settings.retentionCandidatesAreSafe ? .safe : .review
                copy.safetyReason = "Retention candidate: \(reason)"
            }
            return copy
        }

        summaries.sort { $0.totalBytes > $1.totalBytes }
        return BuildReport(
            summaries: summaries, items: adjusted, totalBytes: summaries.reduce(0) { $0 + $1.totalBytes },
            globalBudgetBytes: settings.globalBuildBudgetBytes)
    }
}
