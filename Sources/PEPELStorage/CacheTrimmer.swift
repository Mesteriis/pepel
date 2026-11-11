import Darwin
import Foundation
import PEPELCore

/// Keeps tool caches in bounds by removing only what has not been used for a long time.
///
/// Wiping a cache (`go clean -cache`) throws away what tomorrow's build needs. These caches are
/// content-addressed stores where every file can be fetched or rebuilt, so the entries nobody
/// has read or written for N days can go and the rest stays warm. The list of caches is fixed
/// in code: nothing outside these home-relative locations is ever walked or removed.
public struct CacheTrimmer: Sendable {
    public struct Definition: Sendable {
        public var id: String
        public var title: String
        /// Relative to the home directory.
        public var path: String
        public var style: ManagedCache.Style
        public var note: String
        /// Programs that use the cache; while one of them runs, the cache is left alone.
        public var tools: [String] = []
    }

    public static let caches: [Definition] = [
        .init(id: "go-build", title: L("Go build cache"), path: "Library/Caches/go-build", style: .files, note: L("Compiled packages; Go rebuilds what is missing."), tools: ["go", "compile", "link", "gopls"]),
        .init(id: "sccache", title: "sccache", path: "Library/Caches/Mozilla.sccache", style: .files, note: L("Compiler outputs; recompiled when missing."), tools: ["sccache"]),
        // Unpacked packages are folders whose files belong together, so they go whole or not at all.
        .init(id: "uv", title: L("uv unpacked packages"), path: ".cache/uv/archive-v0", style: .entries, note: L("One folder per unpacked package; uv downloads and unpacks a missing one again."), tools: ["uv", "uvx"]),
        .init(id: "pip", title: L("pip cache"), path: "Library/Caches/pip", style: .files, note: L("Downloaded wheels and HTTP cache."), tools: ["pip", "pip3"]),
        .init(id: "npm", title: L("npm cache"), path: ".npm/_cacache", style: .files, note: L("Downloaded packages; npm fetches a missing one again."), tools: ["npm", "npx"]),
        .init(id: "yarn", title: L("Yarn cache"), path: "Library/Caches/Yarn", style: .files, note: L("Downloaded packages."), tools: ["yarn"]),
        .init(id: "bun", title: L("Bun install cache"), path: ".bun/install/cache", style: .entries, note: L("Unpacked packages, one folder each."), tools: ["bun", "bunx"]),
        .init(id: "cargo-registry", title: L("Cargo registry cache"), path: ".cargo/registry/cache", style: .files, note: L("Downloaded crates; fetched again when needed."), tools: ["cargo", "rustc"]),
        .init(id: "homebrew", title: L("Homebrew downloads"), path: "Library/Caches/Homebrew", style: .files, note: L("Downloaded bottles and source archives."), tools: ["brew"]),
        .init(id: "playwright", title: L("Playwright browsers"), path: "Library/Caches/ms-playwright", style: .entries, note: L("One folder per browser build; `playwright install` brings one back."), tools: ["playwright"]),
        .init(id: "puppeteer", title: L("Puppeteer browsers"), path: ".cache/puppeteer", style: .entries, note: L("Downloaded browser builds."), tools: []),
    ]

    public let home: String

    public init(home: String) { self.home = home }

    /// The cache directory, when it exists as a real directory inside the home folder.
    func root(_ definition: Definition) -> String? {
        let path = home + "/" + definition.path
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        // A cache directory that is a link, or reached through one, is somebody's own arrangement.
        guard PathUtil.canonical(path) == path || PathUtil.canonical(path) == PathUtil.canonical(home) + "/" + definition.path else { return nil }
        // Someone marked it, or a folder above it, as not to be cleaned.
        guard PathUtil.keepMarker(at: path, stopAt: home) == nil else { return nil }
        return path
    }

    /// The moment a file was last of use: the newest of its access, modification and creation times.
    static func lastUse(_ info: stat) -> Int {
        max(info.st_atimespec.tv_sec, info.st_mtimespec.tv_sec, info.st_birthtimespec.tv_sec)
    }

    /// Walks one tree. Calls `visit` for every regular file with its allocated size and last use.
    /// Never follows links and never leaves the volume.
    static func walk(_ root: String, removeEmptyDirectories: Bool = false, visit: (_ path: String, _ bytes: Int64, _ lastUse: Int) -> Void) {
        guard let cPath = strdup(root) else { return }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return }
        defer { fts_close(stream) }
        while let entry = fts_read(stream) {
            let kind = Int32(entry.pointee.fts_info)
            if kind == FTS_F, let info = entry.pointee.fts_statp?.pointee {
                visit(String(cString: entry.pointee.fts_path), Int64(info.st_blocks) * 512, lastUse(info))
            } else if kind == FTS_DP, removeEmptyDirectories, entry.pointee.fts_level > 0 {
                // Fails, harmlessly, for a directory that still has something in it.
                rmdir(entry.pointee.fts_path)
            }
        }
    }

    /// What each cache holds and how much of it has not been used for `days`.
    public func measure(days: Int, now: Date = Date()) -> [ManagedCache] {
        let cutoff = Int(now.timeIntervalSince1970) - days * 86_400
        return Self.caches.compactMap { definition -> ManagedCache? in
            guard let root = root(definition) else { return nil }
            var cache = ManagedCache(id: definition.id, title: definition.title, path: root, style: definition.style, note: definition.note)
            switch definition.style {
            case .files:
                Self.walk(root) { _, bytes, lastUse in
                    cache.totalBytes += bytes
                    cache.fileCount += 1
                    if lastUse < cutoff {
                        cache.staleBytes += bytes
                        cache.staleCount += 1
                    }
                }
            case .entries:
                for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
                    var bytes: Int64 = 0
                    var newest = 0
                    Self.walk(root + "/" + name) { _, size, lastUse in
                        bytes += size
                        newest = max(newest, lastUse)
                    }
                    cache.totalBytes += bytes
                    cache.fileCount += 1
                    if newest > 0, newest < cutoff {
                        cache.staleBytes += bytes
                        cache.staleCount += 1
                    }
                }
            }
            return cache
        }
        .sorted { $0.staleBytes > $1.staleBytes }
    }

    /// Removes from one cache what has not been used for `days`, and then, when `maxBytes` is
    /// set and the cache is still larger, the least recently used entries until it fits.
    /// Returns the bytes and entries removed.
    /// - Parameter running: names of running processes; a cache whose tool is among them is skipped.
    public func trim(_ id: String, days: Int, maxBytes: Int64? = nil, running: Set<String> = [], now: Date = Date()) -> (bytes: Int64, removed: Int) {
        guard let definition = Self.caches.first(where: { $0.id == id }), let root = root(definition) else { return (0, 0) }
        guard running.isDisjoint(with: definition.tools) else { return (0, 0) }
        let cutoff = Int(now.timeIntervalSince1970) - days * 86_400
        // Every entry with its size and last use, least recently used first.
        var entries: [(path: String, bytes: Int64, lastUse: Int)] = []
        switch definition.style {
        case .files:
            Self.walk(root) { path, size, lastUse in entries.append((path, size, lastUse)) }
        case .entries:
            for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
                let path = root + "/" + name
                var info = stat()
                // Only real directories directly inside the cache; a link is left where it is.
                guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, PathUtil.keepMarker(at: path, stopAt: root) == nil else { continue }
                var size: Int64 = 0
                var newest = 0
                Self.walk(path) { _, fileBytes, lastUse in
                    size += fileBytes
                    newest = max(newest, lastUse)
                }
                if newest > 0 { entries.append((path, size, newest)) }
            }
        }
        entries.sort { $0.lastUse < $1.lastUse }
        var remaining = entries.reduce(Int64(0)) { $0 + $1.bytes }
        var bytes: Int64 = 0
        var removed = 0
        // Whatever the size limit, an entry used within the last day is never removed: a build may be using it.
        let recent = Int(now.timeIntervalSince1970) - 86_400
        for entry in entries {
            let tooOld = entry.lastUse < cutoff
            let overLimit = maxBytes.map { remaining > $0 && entry.lastUse < recent } ?? false
            guard tooOld || overLimit else { break }
            var done = false
            switch definition.style {
            case .files:
                // Looked at again right before removal: a file used since the walk stays.
                var info = stat()
                if lstat(entry.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Self.lastUse(info) == entry.lastUse { done = unlink(entry.path) == 0 }
            case .entries:
                done = (try? FileManager.default.removeItem(atPath: entry.path)) != nil
            }
            if done {
                bytes += entry.bytes
                removed += 1
                remaining -= entry.bytes
            }
        }
        if definition.style == .files, removed > 0 { Self.walk(root, removeEmptyDirectories: true) { _, _, _ in } }
        return (bytes, removed)
    }
}
