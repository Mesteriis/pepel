import Foundation
import PEPELCore

/// Finds developer projects under the configured roots by their own metadata.
public struct ProjectDiscovery: Sendable {
    /// Directories that are never descended into: artifact trees, dependency trees, VCS internals.
    public static let prunedNames: Set<String> = [
        "node_modules", ".build", "target", ".venv", "venv", "env", "Pods", "DerivedData", ".git", "build", "dist",
        "vendor", "__pycache__", ".tox", ".nox", ".next", ".nuxt", "Carthage", ".gradle", ".idea", "site-packages",
        ".terraform", ".cache", "Library", ".Trash",
    ]

    public var maxDepth: Int
    public var home: String

    public init(maxDepth: Int = 5, home: String = NSHomeDirectory()) {
        self.maxDepth = maxDepth
        self.home = home
    }

    static func kinds(of entries: Set<String>, names: [String]) -> Set<ProjectKind> {
        var kinds: Set<ProjectKind> = []
        if names.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) { kinds.insert(.xcode) }
        if entries.contains("Package.swift") { kinds.insert(.swiftpm) }
        if !entries.isDisjoint(with: ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "Pipfile"]) { kinds.insert(.python) }
        if entries.contains("package.json") { kinds.insert(.node) }
        if entries.contains("Cargo.toml") { kinds.insert(.cargo) }
        if entries.contains("go.mod") { kinds.insert(.go) }
        if entries.contains("CMakeLists.txt") { kinds.insert(.cmake) }
        if !entries.isDisjoint(with: ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"]) {
            kinds.insert(.dockerCompose)
        }
        return kinds
    }

    public func discover(roots: [String], registered: [String] = [], excluded: [String] = []) -> [Project] {
        var found: [String: Project] = [:]
        let excludedPaths = excluded.map { PathUtil.canonical($0, home: home) }
        var visited = Set<FileIdentity>()

        func isExcluded(_ path: String) -> Bool { excludedPaths.contains { PathUtil.isInside(path, root: $0) } }

        func walk(_ directory: String, depth: Int, enclosing: String?) {
            guard !Task.isCancelled, !isExcluded(directory) else { return }
            guard let identity = PathUtil.identity(directory), identity.isDirectory, visited.insert(identity).inserted else { return }
            guard let listing = PathUtil.entries(directory) else { return }
            let names = listing.map(\.name)
            let entries = Set(names)
            var kinds = Self.kinds(of: entries, names: names)
            var owner = enclosing

            if entries.contains(".git"), let git = GitInspector.inspect(workTree: directory) {
                kinds.insert(.git)
                found[directory] = Project(
                    id: directory, name: (directory as NSString).lastPathComponent, kinds: kinds, git: git, confidence: .verified)
                owner = directory
            } else if !kinds.isEmpty {
                if let enclosing {
                    // A manifest inside an already known project (monorepo package): same project.
                    found[enclosing]?.kinds.formUnion(kinds)
                } else {
                    // Manifest without version control: very likely a project, but not proven.
                    found[directory] = Project(
                        id: directory, name: (directory as NSString).lastPathComponent, kinds: kinds, confidence: .probable)
                    owner = directory
                }
            }

            guard depth < maxDepth else { return }
            // Symlinked directories are not followed: they may point anywhere.
            for entry in listing where entry.isDirectory && !entry.isSymlink {
                let name = entry.name
                if name.hasPrefix(".") || Self.prunedNames.contains(name) { continue }
                if name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") || name.hasSuffix(".app") { continue }
                walk(directory + "/" + name, depth: depth + 1, enclosing: owner)
            }
        }

        for root in roots {
            let canonical = PathUtil.canonical(root, home: home)
            guard PathUtil.isDirectory(canonical) else { continue }
            walk(canonical, depth: 0, enclosing: nil)
        }

        for path in registered {
            let canonical = PathUtil.canonical(path, home: home)
            guard PathUtil.isDirectory(canonical) else { continue }
            if var existing = found[canonical] {
                existing.kinds.insert(.registered)
                existing.confidence = .verified
                found[canonical] = existing
            } else {
                let names = PathUtil.list(canonical) ?? []
                var kinds = Self.kinds(of: Set(names), names: names)
                kinds.insert(.registered)
                let git = GitInspector.inspect(workTree: canonical)
                if git != nil { kinds.insert(.git) }
                found[canonical] = Project(
                    id: canonical, name: (canonical as NSString).lastPathComponent, kinds: kinds, git: git, confidence: .verified)
            }
        }

        // Linked worktrees often live outside the project roots; git's own metadata names them.
        for project in Array(found.values) {
            guard let git = project.git, !git.isLinkedWorktree else { continue }
            for worktree in GitInspector.linkedWorktrees(common: git.commonDirectory)
            where found[worktree] == nil && !isExcluded(worktree) {
                guard let info = GitInspector.inspect(workTree: worktree) else { continue }
                let names = PathUtil.list(worktree) ?? []
                var kinds = Self.kinds(of: Set(names), names: names)
                kinds.insert(.git)
                found[worktree] = Project(
                    id: worktree, name: (worktree as NSString).lastPathComponent, kinds: kinds, git: info, confidence: .verified)
            }
        }

        return Self.grouped(Array(found.values))
    }

    /// Worktrees of one repository share a group named after the main checkout.
    static func grouped(_ projects: [Project]) -> [Project] {
        var mainName: [String: String] = [:]
        for p in projects {
            guard let git = p.git, !git.isLinkedWorktree else { continue }
            mainName[git.commonDirectory] = p.name
        }
        return projects.map { project in
            var p = project
            if let git = p.git {
                p.groupID = git.commonDirectory
                // A bare or out-of-root main checkout: fall back to the directory holding `.git`.
                p.groupName = mainName[git.commonDirectory]
                    ?? ((git.commonDirectory as NSString).deletingLastPathComponent as NSString).lastPathComponent
            }
            return p
        }.sorted { $0.id < $1.id }
    }
}

/// Longest-prefix lookup from a path to the project that contains it.
public struct ProjectIndex: ProjectAttributing {
    public let projects: [Project]
    private let byRoot: [String: Project]
    private let rootsByLength: [String]

    public init(_ projects: [Project]) {
        self.projects = projects
        var map: [String: Project] = [:]
        for p in projects { map[p.id] = p }
        byRoot = map
        rootsByLength = map.keys.sorted { $0.count > $1.count }
    }

    public func project(id: String) -> Project? { byRoot[id] }

    public func project(containing path: String) -> Project? {
        guard path.hasPrefix("/") else { return nil }
        // Fast path for canonical input, then a resolved retry for symlinks and aliases.
        for candidate in [path, PathUtil.canonical(path)] {
            if let root = rootsByLength.first(where: { PathUtil.isInside(candidate, root: $0) }) { return byRoot[root] }
        }
        return nil
    }

    public func attribute(path: String) -> ProjectAttribution? {
        guard let p = project(containing: path) else { return nil }
        return ProjectAttribution(projectID: p.id, groupID: p.groupID, confidence: .verified)
    }

    public func groupName(_ groupID: String) -> String? {
        projects.first { $0.groupID == groupID }?.groupName
    }
}
