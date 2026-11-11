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
    }

    public static let caches: [Definition] = [
        .init(id: "go-build", title: "Go build cache", path: "Library/Caches/go-build", style: .files, note: "Compiled packages; Go rebuilds what is missing."),
        .init(id: "sccache", title: "sccache", path: "Library/Caches/Mozilla.sccache", style: .files, note: "Compiler outputs; recompiled when missing."),
        // Unpacked packages are folders whose files belong together, so they go whole or not at all.
        .init(id: "uv", title: "uv unpacked packages", path: ".cache/uv/archive-v0", style: .entries, note: "One folder per unpacked package; uv downloads and unpacks a missing one again."),
        .init(id: "pip", title: "pip cache", path: "Library/Caches/pip", style: .files, note: "Downloaded wheels and HTTP cache."),
        .init(id: "npm", title: "npm cache", path: ".npm/_cacache", style: .files, note: "Downloaded packages; npm fetches a missing one again."),
        .init(id: "yarn", title: "Yarn cache", path: "Library/Caches/Yarn", style: .files, note: "Downloaded packages."),
        .init(id: "bun", title: "Bun install cache", path: ".bun/install/cache", style: .entries, note: "Unpacked packages, one folder each."),
        .init(id: "cargo-registry", title: "Cargo registry cache", path: ".cargo/registry/cache", style: .files, note: "Downloaded crates; fetched again when needed."),
        .init(id: "homebrew", title: "Homebrew downloads", path: "Library/Caches/Homebrew", style: .files, note: "Downloaded bottles and source archives."),
        .init(id: "playwright", title: "Playwright browsers", path: "Library/Caches/ms-playwright", style: .entries, note: "One folder per browser build; `playwright install` brings one back."),
        .init(id: "puppeteer", title: "Puppeteer browsers", path: ".cache/puppeteer", style: .entries, note: "Downloaded browser builds."),
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
    public func trim(_ id: String, days: Int, maxBytes: Int64? = nil, now: Date = Date()) -> (bytes: Int64, removed: Int) {
        guard let definition = Self.caches.first(where: { $0.id == id }), let root = root(definition) else { return (0, 0) }
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
                guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
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
