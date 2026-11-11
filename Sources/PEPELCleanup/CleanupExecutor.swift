import Darwin
import Foundation
import PEPELCore
import PEPELPersistence

public enum CleanupStatus: Codable, Sendable, Hashable {
    case removed
    case trashed(to: String)
    case toolRan
    /// Dry run: this is what would have happened.
    case wouldApply
    case skipped(reason: String)
    case failed(reason: String)

    public var succeeded: Bool {
        switch self {
        case .removed, .trashed, .toolRan: true
        default: false
        }
    }
}

public struct CleanupOutcome: Codable, Sendable, Identifiable, Hashable {
    public var itemID: String
    public var title: String
    public var path: String
    public var action: PlannedAction
    public var status: CleanupStatus
    /// Upper bound from the scan, not a measurement.
    public var estimatedBytes: Int64

    public var id: String { itemID }
}

public struct CleanupReport: Codable, Sendable {
    public var startedAt: Date
    public var finishedAt: Date
    public var dryRun: Bool
    public var outcomes: [CleanupOutcome]
    public var diskAvailableBefore: Int64
    public var diskAvailableAfter: Int64

    public var estimatedBytes: Int64 { outcomes.filter { $0.status.succeeded || $0.status == .wouldApply }.reduce(0) { $0 + $1.estimatedBytes } }
    /// Observed change in available space. Other activity on the machine moves this number too,
    /// and trashed items free nothing until the Trash is emptied.
    public var observedFreedBytes: Int64 { diskAvailableAfter - diskAvailableBefore }
    public var succeededCount: Int { outcomes.filter(\.status.succeeded).count }
}

/// Performs approved cleanup actions. This is the only code in PEPEL that removes files.
public struct CleanupExecutor: Sendable {
    public let engine: CleanupPolicyEngine
    public let store: PepelStore?
    public let tools: ToolRunner

    public init(engine: CleanupPolicyEngine = CleanupPolicyEngine(), store: PepelStore?, tools: ToolRunner = ToolRunner()) {
        self.engine = engine
        self.store = store
        self.tools = tools
    }

    /// - Parameters:
    ///   - freshContext: called for each item right before acting, so process and lease state is current.
    ///   - validate: the owning analyzer's shape check; returns a reason when the item no longer qualifies.
    public func execute(
        _ approved: [ApprovedAction], dryRun: Bool, freshContext: @Sendable (StorageItem) async -> PolicyContext,
        validate: @Sendable (StorageItem) -> String?, diskAvailable: @Sendable () -> Int64
    ) async -> CleanupReport {
        var report = CleanupReport(
            startedAt: Date(), finishedAt: Date(), dryRun: dryRun, outcomes: [], diskAvailableBefore: diskAvailable(),
            diskAvailableAfter: 0)
        for action in approved {
            var outcome = CleanupOutcome(
                itemID: action.item.id, title: action.item.title, path: action.item.path, action: action.action,
                status: .skipped(reason: "Cancelled."), estimatedBytes: action.item.reclaimableBytes)
            if !Task.isCancelled {
                let context = await freshContext(action.item)
                outcome.status = perform(action, context: context, dryRun: dryRun, validate: validate)
            }
            report.outcomes.append(outcome)
            record(outcome, initiator: action.initiator, dryRun: dryRun)
        }
        report.finishedAt = Date()
        report.diskAvailableAfter = diskAvailable()
        return report
    }

    private func perform(
        _ approved: ApprovedAction, context: PolicyContext, dryRun: Bool, validate: (StorageItem) -> String?
    ) -> CleanupStatus {
        let item = approved.item
        // Time-of-check/time-of-use: everything is decided again against the state of this instant.
        if let denial = engine.stillPermitted(approved, context: context) {
            return .skipped(reason: denial.reasons.first ?? "No longer permitted.")
        }
        if let problem = validate(item) { return .skipped(reason: problem) }

        switch approved.action {
        case .none:
            return .skipped(reason: "No cleanup method.")
        case .tool(let tool):
            if dryRun { return .wouldApply }
            return runTool(tool)
        case .trash, .removePermanently:
            guard let expected = item.identity else { return .skipped(reason: "The item was scanned without a file identity.") }
            guard let current = PathUtil.identity(item.path) else { return .skipped(reason: "The path no longer exists.") }
            guard current.sameObject(as: expected), !current.isSymlink else {
                return .skipped(reason: "The path was replaced after it was scanned.")
            }
            let window = TimeInterval(context.settings.recentWriteProtectionMinutes) * 60
            if Self.hasRecentWrites(item.path, within: window, now: Date()) {
                return .skipped(reason: "Files in it were modified in the last \(context.settings.recentWriteProtectionMinutes) minutes.")
            }
            if dryRun { return .wouldApply }
            return approved.action == .trash ? trash(item.path) : remove(item.path, expected: expected)
        }
    }

    /// Bounded look for writes newer than `within`. Checks the top of the tree, where build tools
    /// touch files first; the full-tree timestamp from the scan was already checked by the policy.
    public static func hasRecentWrites(_ path: String, within: TimeInterval, now: Date, limit: Int = 20_000) -> Bool {
        guard within > 0, let cPath = strdup(path) else { return false }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return false }
        defer { fts_close(stream) }
        let cutoff = Int(now.timeIntervalSince1970 - within)
        var visited = 0
        while let entry = fts_read(stream), visited < limit {
            visited += 1
            guard Int32(entry.pointee.fts_info) != FTS_DP, let st = entry.pointee.fts_statp?.pointee else { continue }
            if st.st_mtimespec.tv_sec > cutoff { return true }
        }
        return false
    }

    private func trash(_ path: String) -> CleanupStatus {
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
            return .trashed(to: resulting?.path ?? "")
        } catch {
            return .failed(reason: "Could not move to Trash: \(error.localizedDescription)")
        }
    }

    /// Renames the directory aside first. The rename is atomic, so what gets deleted afterwards is
    /// exactly the object that was validated, even if something recreates the original path.
    private func remove(_ path: String, expected: FileIdentity) -> CleanupStatus {
        let parent = (path as NSString).deletingLastPathComponent
        let aside = parent + "/.pepel-removing-" + UUID().uuidString
        guard rename(path, aside) == 0 else {
            return .failed(reason: "Could not take the directory aside: \(String(cString: strerror(errno)))")
        }
        guard let moved = PathUtil.identity(aside), moved.sameObject(as: expected), !moved.isSymlink else {
            // Not what was validated: put it back untouched.
            _ = rename(aside, path)
            return .skipped(reason: "The path was replaced while cleanup was starting.")
        }
        do {
            try FileManager.default.removeItem(atPath: aside)
            return .removed
        } catch {
            return .failed(reason: "Removal stopped part-way (\(error.localizedDescription)). The remainder is at \(aside).")
        }
    }

    private func runTool(_ tool: ToolCleanup) -> CleanupStatus {
        let (name, arguments): (String, [String]) =
            switch tool {
            case .dockerBuildCache: ("docker", ["builder", "prune", "--force"])
            case .dockerStoppedContainers: ("docker", ["container", "prune", "--force"])
            case .dockerDanglingImages: ("docker", ["image", "prune", "--force"])
            case .goBuildCache: ("go", ["clean", "-cache"])
            case .goModuleCache: ("go", ["clean", "-modcache"])
            case .simulatorUnavailable: ("xcrun", ["simctl", "delete", "unavailable"])
            case .uvCacheClean: ("uv", ["cache", "clean"])
            case .pnpmStorePrune: ("pnpm", ["store", "prune"])
            }
        guard let result = tools.run(name, arguments, timeout: 600) else {
            return .failed(reason: "`\(tool.commandDescription)` could not be run or timed out.")
        }
        return result.status == 0 ? .toolRan : .failed(reason: "`\(tool.commandDescription)` exited with status \(result.status).")
    }

    private func record(_ outcome: CleanupOutcome, initiator: Initiator, dryRun: Bool) {
        var detail = ["action": outcome.action.summary, "path": outcome.path]
        let text: String
        switch outcome.status {
        case .removed: text = "removed"
        case .trashed(let to):
            text = "trashed"
            detail["trashedTo"] = to
        case .toolRan: text = "tool ran"
        case .wouldApply: text = "would apply"
        case .skipped(let reason): text = "skipped: \(reason)"
        case .failed(let reason): text = "failed: \(reason)"
        }
        let kind: AuditKind = dryRun ? .cleanupPreview : outcome.status.succeeded ? .cleanup : .cleanupDenied
        store?.appendAudit(
            AuditEntry(
                kind: kind, initiator: initiator.rawValue, subject: outcome.title, outcome: text,
                bytes: outcome.status.succeeded || outcome.status == .wouldApply ? outcome.estimatedBytes : 0, detail: detail))
    }

    /// Puts a trashed item back. Only possible while it is still in the Trash and its original
    /// location is free; permanent removals and tool cleanups cannot be undone.
    public func restore(trashedPath: String, originalPath: String) -> String? {
        guard PathUtil.exists(trashedPath) else { return "The item is no longer in the Trash." }
        guard !PathUtil.exists(originalPath) else { return "Something else now exists at the original location." }
        do {
            try FileManager.default.moveItem(atPath: trashedPath, toPath: originalPath)
            store?.appendAudit(AuditEntry(kind: .cleanup, initiator: Initiator.user.rawValue, subject: (originalPath as NSString).lastPathComponent, outcome: "restored", detail: ["path": originalPath]))
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
