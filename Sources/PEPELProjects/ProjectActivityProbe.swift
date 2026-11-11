import Darwin
import Foundation
import PEPELCore

/// Establishes when a project was last worked on, without reading any file's contents.
///
/// No single timestamp says it, so several cheap ones are combined and the newest wins:
/// git's own bookkeeping (the index is rewritten whenever an editor, an agent or a person runs
/// `git status`; `HEAD` and its log change on every commit and checkout), and the newest
/// modification among the project's own files, found by a bounded walk that stays out of
/// generated directories. Erring towards "recent" is the safe direction: a project wrongly
/// seen as active only keeps its artifacts a while longer.
public enum ProjectActivityProbe {
    /// Directories that hold generated or downloaded files; a build touching them is not someone working.
    static let generated: Set<String> = [
        "node_modules", ".venv", "venv", "target", "build", "dist", "out", ".next", ".nuxt", ".build", ".gradle", "__pycache__", ".pytest_cache",
        ".mypy_cache", ".ruff_cache", ".tox", ".nox", "DerivedData", ".turbo", ".cache", "coverage", ".parcel-cache", ".svelte-kit", "vendor", "Pods",
        ".git", ".idea", ".vscode", ".DS_Store",
    ]

    static func modified(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }

    /// - Parameters:
    ///   - gitDirectory: the repository's git directory, when the project is a git working tree.
    ///   - skip: paths of recognised artifacts inside the project.
    public static func lastActivity(root: String, gitDirectory: String?, skip: Set<String> = [], maxEntries: Int = 4000, maxDepth: Int = 5) -> Date? {
        var newest = modified(root)
        func consider(_ date: Date?) { if let date, date > (newest ?? .distantPast) { newest = date } }
        for name in ["index", "HEAD", "logs/HEAD"] {
            if let gitDirectory { consider(modified(gitDirectory + "/" + name)) }
            consider(modified(root + "/.git/" + name))
        }
        var visited = 0
        var queue: [(path: String, depth: Int)] = [(root, 0)]
        while let (directory, depth) = queue.first, visited < maxEntries {
            queue.removeFirst()
            guard let handle = opendir(directory) else { continue }
            defer { closedir(handle) }
            while let entry = readdir(handle), visited < maxEntries {
                let name = withUnsafePointer(to: entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
                guard name != ".", name != "..", !generated.contains(name) else { continue }
                let path = directory + "/" + name
                guard !skip.contains(path) else { continue }
                visited += 1
                var info = stat()
                guard lstat(path, &info) == 0 else { continue }
                consider(Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)))
                // Links are looked at, never followed.
                if (info.st_mode & S_IFMT) == S_IFDIR, depth + 1 < maxDepth { queue.append((path, depth + 1)) }
            }
        }
        return newest
    }
}
