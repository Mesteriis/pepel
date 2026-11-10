import Foundation
import PEPELCore

/// Reads repository metadata straight from `.git` files. No `git` subprocess, no network.
public enum GitInspector {
    static func read(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path), data.count < 4_000_000 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Resolves the git directory for a working tree: `.git` is a directory in the main checkout
    /// and a `gitdir:` pointer file in linked worktrees and submodules.
    static func gitDirectory(forWorkTree root: String) -> (gitDir: String, linked: Bool)? {
        let dotGit = root + "/.git"
        guard let identity = PathUtil.identity(dotGit) else { return nil }
        if identity.isDirectory { return (dotGit, false) }
        guard let text = read(dotGit), let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
        var target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !target.hasPrefix("/") { target = root + "/" + target }
        return (PathUtil.canonical(target), true)
    }

    public static func inspect(workTree root: String) -> GitInfo? {
        guard let (gitDir, linked) = gitDirectory(forWorkTree: root) else { return nil }
        var common = gitDir
        if let pointer = read(gitDir + "/commondir")?.trimmingCharacters(in: .whitespacesAndNewlines), !pointer.isEmpty {
            common = PathUtil.canonical(pointer.hasPrefix("/") ? pointer : gitDir + "/" + pointer)
        } else {
            common = PathUtil.canonical(gitDir)
        }
        var info = GitInfo(commonDirectory: common, isLinkedWorktree: linked && common != PathUtil.canonical(gitDir))
        if let head = read(gitDir + "/HEAD")?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if head.hasPrefix("ref:") {
                let ref = head.dropFirst(4).trimmingCharacters(in: .whitespaces)
                info.branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
                info.headCommit = resolve(ref: ref, gitDir: gitDir, common: common)
            } else {
                info.headCommit = head
            }
        }
        info.remoteURL = originURL(common: common)
        return info
    }

    private static func resolve(ref: String, gitDir: String, common: String) -> String? {
        for base in [gitDir, common] {
            if let value = read(base + "/" + ref)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        }
        guard let packed = read(common + "/packed-refs") else { return nil }
        for line in packed.split(separator: "\n") where line.hasSuffix(" " + ref) {
            return line.split(separator: " ").first.map(String.init)
        }
        return nil
    }

    private static func originURL(common: String) -> String? {
        guard let config = read(common + "/config") else { return nil }
        var inOrigin = false
        for raw in config.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.replacingOccurrences(of: " ", with: "") == "[remote\"origin\"]"
            } else if inOrigin, line.hasPrefix("url"), let eq = line.firstIndex(of: "=") {
                return stripCredentials(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// `https://user:token@host/repo` → `https://host/repo`. Tokens in remotes must never be stored or shown.
    public static func stripCredentials(_ url: String) -> String {
        guard let scheme = url.range(of: "://"), let at = url[scheme.upperBound...].firstIndex(of: "@") else { return url }
        let authority = url[scheme.upperBound..<at]
        guard !authority.contains("/") else { return url }
        return String(url[..<scheme.upperBound]) + String(url[url.index(after: at)...])
    }

    /// Working trees linked to the repository whose shared git directory is `common`.
    public static func linkedWorktrees(common: String) -> [String] {
        let base = common + "/worktrees"
        guard let names = PathUtil.list(base) else { return [] }
        return names.compactMap { name in
            guard let pointer = read(base + "/" + name + "/gitdir")?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            // The pointer names the worktree's `.git` file.
            let root = (pointer as NSString).deletingLastPathComponent
            return PathUtil.isDirectory(root) ? PathUtil.canonical(root) : nil
        }
    }

    /// Paths among `candidates` that git ignores in `repository`. Ignored paths are not source code.
    /// Returns nil when git cannot be consulted, in which case callers must not assume anything.
    public static func ignoredPaths(in repository: String, candidates: [String]) -> Set<String>? {
        guard !candidates.isEmpty else { return [] }
        let git = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: git) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", repository, "check-ignore", "--stdin", "-z"]
        process.environment = ["GIT_OPTIONAL_LOCKS": "0", "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let payload = candidates.joined(separator: "\0") + "\0"
        DispatchQueue.global(qos: .utility).async {
            input.fileHandleForWriting.write(Data(payload.utf8))
            try? input.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // 0: some ignored, 1: none ignored, anything else: git failed.
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else { return nil }
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init))
    }
}
