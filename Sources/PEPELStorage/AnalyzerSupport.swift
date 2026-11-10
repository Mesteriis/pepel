import Foundation
import PEPELCore
import PEPELProjects

/// A directory inside a project whose name suggests generated content. Analyzers decide what,
/// if anything, it is; the name alone proves nothing.
public struct ArtifactHit: Sendable, Hashable {
    public var path: String
    public var name: String
    public var parent: String
    /// Names next to the directory, used to check for the manifest that would explain it.
    public var siblings: Set<String>
    public var projectID: String
    /// What git says: true = ignored (not source), false = not ignored, nil = could not be determined.
    public var gitIgnored: Bool?
}

public struct ScanContext: Sendable {
    public var home: String
    public var temporaryDirectory: String
    /// The machine-wide temporary folder (`/private/tmp`), where some tools keep per-user scratch space.
    public var sharedTemporaryDirectory: String
    public var projects: ProjectIndex
    public var settings: PepelSettings
    public var now: Date
    public var tools: ToolRunner
    public var hits: [ArtifactHit]

    public init(
        home: String = NSHomeDirectory(), temporaryDirectory: String = NSTemporaryDirectory(),
        sharedTemporaryDirectory: String = "/private/tmp", projects: ProjectIndex,
        settings: PepelSettings = PepelSettings(), now: Date = Date(), tools: ToolRunner = ToolRunner(), hits: [ArtifactHit] = []
    ) {
        self.home = home
        self.temporaryDirectory = PathUtil.canonical(temporaryDirectory)
        self.sharedTemporaryDirectory = sharedTemporaryDirectory
        self.projects = projects
        self.settings = settings
        self.now = now
        self.tools = tools
        self.hits = hits
    }

    public func hits(named names: Set<String>) -> [ArtifactHit] { hits.filter { names.contains($0.name) } }

    /// An existing, non-symlink directory at `home + relative`, canonicalised.
    public func homeDirectory(_ relative: String) -> String? {
        let path = home + "/" + relative
        guard let identity = PathUtil.identity(path), identity.isDirectory else { return nil }
        return PathUtil.canonical(path)
    }
}

public struct AnalyzerOutput: Sendable {
    public var items: [StorageItem] = []
    public var issues: [String] = []

    public init(items: [StorageItem] = [], issues: [String] = []) {
        self.items = items
        self.issues = issues
    }
}

/// One source of cleanup candidates. Analyzers describe what they found and how it may be
/// cleaned; they hold no deletion code. Removal is performed only by the cleanup executor after
/// the policy engine approved the item.
public protocol StorageAnalyzer: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// How artifacts are recognised, in one sentence.
    var detection: String { get }
    /// Fixed locations this analyzer looks at (project-relative artifacts are found via `ScanContext.hits`).
    func supportedPaths(_ context: ScanContext) -> [String]
    /// Cheap enumeration. Sizes are measured afterwards by the scan coordinator.
    func discover(_ context: ScanContext) async -> AnalyzerOutput
    /// Re-checks, immediately before cleanup, that the item still has the shape that justified
    /// its classification. Returns a reason when it does not.
    func validate(_ item: StorageItem) -> String?
}

extension StorageAnalyzer {
    public func supportedPaths(_ context: ScanContext) -> [String] { [] }

    public func validate(_ item: StorageItem) -> String? {
        if item.hasPseudoPath { return nil }
        guard let identity = PathUtil.identity(item.path) else { return "The path no longer exists." }
        if identity.isSymlink { return "The path is now a symbolic link." }
        return nil
    }

    public func item(
        _ context: ScanContext, category: ArtifactCategory, path: String, title: String, explanation: String,
        safety: SafetyClass, reason: String, reproducible: Bool = true, method: CleanupMethod = .filesystem,
        build: BuildMetadata? = nil
    ) -> StorageItem {
        let attribution = context.projects.attribute(path: path)
        return StorageItem(
            analyzerID: id, category: category, path: path, title: title, explanation: explanation, safety: safety,
            safetyReason: reason, reproducible: reproducible, method: method, projectID: attribution?.projectID,
            projectConfidence: attribution?.confidence ?? .unknown, identity: PathUtil.identity(path), build: build)
    }

    func branchInfo(_ context: ScanContext, projectID: String?) -> (branch: String?, commit: String?) {
        guard let projectID, let git = context.projects.project(id: projectID)?.git else { return (nil, nil) }
        return (git.branch, git.headCommit.map { String($0.prefix(12)) })
    }
}

/// Walks project trees once per scan and records directories that look like generated content.
public struct ProjectArtifactWalker: Sendable {
    public static let exactNames: Set<String> = [
        ".build", "node_modules", "target", ".venv", "venv", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".nox",
        ".next", ".nuxt", ".turbo", ".parcel-cache", ".svelte-kit", ".angular", "dist", "build", "out", "DerivedData",
    ]

    public var maxDepth: Int

    public init(maxDepth: Int = 6) { self.maxDepth = maxDepth }

    static func isCandidate(_ name: String) -> Bool {
        exactNames.contains(name) || name.hasPrefix("cmake-build-") || name.hasSuffix(".xcresult")
    }

    /// Walks every project, a few at a time, and asks git which hits are ignored.
    public func walk(_ index: ProjectIndex, consultGit: Bool = true) async -> [ArtifactHit] {
        let roots = Set(index.projects.map(\.id))
        return await withTaskGroup(of: [ArtifactHit].self) { group in
            var hits: [ArtifactHit] = []
            var running = 0
            for project in index.projects {
                if Task.isCancelled { break }
                if running >= 8, let finished = await group.next() {
                    running -= 1
                    hits += finished
                }
                running += 1
                group.addTask(priority: .utility) { walk(project: project, otherRoots: roots, consultGit: consultGit) }
            }
            for await finished in group { hits += finished }
            return hits.sorted { $0.path < $1.path }
        }
    }

    func walk(project: Project, otherRoots: Set<String>, consultGit: Bool) -> [ArtifactHit] {
        var hits: [ArtifactHit] = []
        walk(project.id, depth: 0, projectID: project.id, otherRoots: otherRoots, into: &hits)
        if consultGit, project.git != nil, !hits.isEmpty,
            let ignored = GitInspector.ignoredPaths(in: project.id, candidates: hits.map(\.path))
        {
            for i in hits.indices { hits[i].gitIgnored = ignored.contains(hits[i].path) }
        }
        return hits
    }

    private func walk(_ directory: String, depth: Int, projectID: String, otherRoots: Set<String>, into hits: inout [ArtifactHit]) {
        guard let listing = PathUtil.entries(directory) else { return }
        var siblings: Set<String>?
        for entry in listing where entry.isDirectory && !entry.isSymlink {
            let name = entry.name
            let path = directory + "/" + name
            if Self.isCandidate(name) {
                let names = siblings ?? Set(listing.map(\.name))
                siblings = names
                hits.append(ArtifactHit(path: path, name: name, parent: directory, siblings: names, projectID: projectID, gitIgnored: nil))
                continue
            }
            // Other projects (nested repositories, worktrees) are walked on their own.
            if otherRoots.contains(path) || name.hasPrefix(".") || depth >= maxDepth { continue }
            if name == "Pods" || name == "vendor" || name == "__pycache__" || name == "site-packages" || name.hasSuffix(".app") { continue }
            walk(path, depth: depth + 1, projectID: projectID, otherRoots: otherRoots, into: &hits)
        }
    }
}
