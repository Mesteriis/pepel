import Foundation
import PEPELCore

public struct ScanProgress: Sendable, Equatable {
    public var phase: String
    public var completed: Int
    public var total: Int

    public init(phase: String, completed: Int = 0, total: Int = 0) {
        self.phase = phase
        self.completed = completed
        self.total = total
    }
}

/// Directories reported as changed since the previous scan.
public struct ChangeSet: Sendable {
    public var paths: Set<String>
    /// Too much changed to track; every cached measurement is stale.
    public var everything: Bool

    public init(paths: Set<String> = [], everything: Bool = false) {
        self.paths = paths
        self.everything = everything
    }
}

/// Runs analyzers, removes overlapping results and measures sizes with bounded concurrency.
/// Measurements of items nothing changed under are reused from the previous scan.
public actor ScanCoordinator {
    public nonisolated let analyzers: [any StorageAnalyzer]
    private let sizer = DirectorySizer()
    private let maxConcurrentMeasurements: Int
    private var cache: [String: (identity: FileIdentity?, size: SizeInfo)] = [:]

    public init(analyzers: [any StorageAnalyzer] = AnalyzerRegistry.all(), maxConcurrentMeasurements: Int = 4) {
        self.analyzers = analyzers
        self.maxConcurrentMeasurements = max(1, maxConcurrentMeasurements)
    }

    public nonisolated func analyzer(id: String) -> (any StorageAnalyzer)? { analyzers.first { $0.id == id } }

    /// - Parameter changes: nil measures everything afresh; otherwise unchanged items reuse their cached size.
    public func scan(
        context: ScanContext, changes: ChangeSet? = nil, progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async -> ScanResult {
        var result = ScanResult(startedAt: Date())
        progress?(ScanProgress(phase: "Looking for artifacts"))

        let outputs = await withTaskGroup(of: (String, AnalyzerOutput).self) { group in
            for analyzer in analyzers {
                group.addTask { (analyzer.id, await analyzer.discover(context)) }
            }
            var collected: [(String, AnalyzerOutput)] = []
            for await output in group { collected.append(output) }
            return collected
        }
        var discovered: [StorageItem] = []
        // Stable order regardless of which analyzer finished first.
        for (id, output) in outputs.sorted(by: { $0.0 < $1.0 }) {
            discovered += output.items
            result.issues += output.issues.map { AnalyzerIssue(analyzerID: id, message: $0) }
        }
        let excluded = context.settings.excludedPaths.map { PathUtil.canonical($0, home: context.home) }
        discovered.removeAll { item in excluded.contains { PathUtil.isInside(item.path, root: $0) } }
        var items = Self.resolveOverlaps(discovered)

        // Every ancestor of a changed directory is stale too.
        var stale = Set<String>()
        if let changes, !changes.everything {
            for path in changes.paths {
                var current = path
                while current.count > 1, stale.insert(current).inserted {
                    current = (current as NSString).deletingLastPathComponent
                }
            }
        }

        let ledger = HardLinkLedger()
        var pending: [Int] = []
        for index in items.indices {
            let item = items[index]
            guard !item.hasPseudoPath || item.measuredPaths != nil else { continue }
            if let changes, !changes.everything, let cached = cache[item.path], cached.identity == item.identity,
                cached.size.complete, !stale.contains(item.path)
            {
                items[index].size = cached.size
                result.reusedMeasurements += 1
            } else {
                pending.append(index)
            }
        }

        let sizer = self.sizer
        progress?(ScanProgress(phase: "Measuring", completed: 0, total: pending.count))
        let limit = maxConcurrentMeasurements
        let jobs = pending.map { (index: $0, paths: items[$0].measuredPaths ?? [items[$0].path]) }
        let total = jobs.count
        let measured = await withTaskGroup(of: (Int, SizeInfo).self) { group in
            var running = 0
            var sizes: [(Int, SizeInfo)] = []
            for job in jobs {
                if Task.isCancelled { break }
                if running >= limit, let finished = await group.next() {
                    running -= 1
                    sizes.append(finished)
                    progress?(ScanProgress(phase: "Measuring", completed: sizes.count, total: total))
                }
                running += 1
                group.addTask(priority: .utility) {
                    var sum = SizeInfo(measuredAt: Date())
                    for path in job.paths {
                        let part = sizer.measure(path, ledger: ledger)
                        sum.logicalBytes += part.logicalBytes
                        sum.allocatedBytes += part.allocatedBytes
                        sum.fileCount += part.fileCount
                        sum.inaccessibleCount += part.inaccessibleCount
                        sum.hardLinkedBytes += part.hardLinkedBytes
                        sum.complete = sum.complete && part.complete
                        if let newest = part.newestModification {
                            sum.newestModification = max(sum.newestModification ?? newest, newest)
                        }
                    }
                    return (job.index, sum)
                }
            }
            for await finished in group {
                sizes.append(finished)
                progress?(ScanProgress(phase: "Measuring", completed: sizes.count, total: total))
            }
            return sizes
        }
        for (index, size) in measured { items[index].size = size }

        result.cancelled = Task.isCancelled
        for item in items {
            if let size = item.size, size.complete { cache[item.path] = (item.identity, size) }
        }
        let known = Set(items.map(\.path))
        cache = cache.filter { known.contains($0.key) }

        result.items = items.sorted { $0.occupiedBytes > $1.occupiedBytes }
        result.finishedAt = Date()
        return result
    }

    /// Guarantees that no two items cover the same data: exact duplicates collapse, and an item
    /// nested inside another is folded into the outer one. The outer item inherits the stricter
    /// classification, so a protected directory can never be removed as part of a larger one.
    public static func resolveOverlaps(_ items: [StorageItem]) -> [StorageItem] {
        func rank(_ s: SafetyClass) -> Int { s == .safe ? 0 : s == .review ? 1 : 2 }
        var kept: [StorageItem] = []
        for item in items.sorted(by: { ($0.path.count, $0.path) < ($1.path.count, $1.path) }) {
            if item.hasPseudoPath {
                if !kept.contains(where: { $0.path == item.path }) { kept.append(item) }
                continue
            }
            if let outer = kept.firstIndex(where: { !$0.hasPseudoPath && PathUtil.isInside(item.path, root: $0.path) }) {
                if rank(item.safety) > rank(kept[outer].safety) {
                    kept[outer].safety = item.safety
                    kept[outer].safetyReason = "Contains “\(item.title)”: \(item.safetyReason)"
                    if item.safety == .protected { kept[outer].method = .none }
                }
                continue
            }
            kept.append(item)
        }
        return kept
    }
}
