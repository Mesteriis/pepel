import CryptoKit
import Darwin
import Foundation
import PEPELCore

/// Finds large files in the home folder that have not been opened for a long time, and files
/// whose contents are identical. It only reports; PEPEL removes none of them.
public struct LargeFiles: Sendable {
    public let home: String

    public init(home: String) { self.home = home }

    static let dependencyFolders: Set<String> = ["node_modules", ".venv", "venv", "site-packages", ".git", "worktrees", ".build", "target", "DerivedData"]

    /// Left out of the walk: application state, agents' folders, caches with rules of their own,
    /// the Trash, and the folders macOS guards unless asked.
    func skipped(includeGuarded: Bool) -> Set<String> {
        var paths = Set(["Library", ".Trash", ".cache", ".claude", ".codex", ".hermes", ".local/share/opencode", ".npm", ".cargo", ".rustup", ".gradle", ".android", "go/pkg"].map { home + "/" + $0 })
        if !includeGuarded { paths.formUnion(DiskMapScanner(home: home).restricted) }
        return paths
    }

    /// - Parameters:
    ///   - oldBytes: smallest file reported as old.
    ///   - days: how long it must have gone unopened.
    ///   - duplicateBytes: smallest file compared for duplicates.
    public func report(
        oldBytes: Int64 = 500 * Bytes.mb, days: Int = 90, duplicateBytes: Int64 = 100 * Bytes.mb, includeGuarded: Bool = false,
        now: Date = Date(), isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) -> LargeFilesReport {
        let skip = skipped(includeGuarded: includeGuarded)
        let cutoff = Int(now.timeIntervalSince1970) - days * 86_400
        let smallest = min(oldBytes, duplicateBytes)
        var large: [(file: LargeFile, device: Int32, inode: UInt64)] = []
        var seen = 0
        if let cPath = strdup(home) {
            defer { free(cPath) }
            var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
            if let stream = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) {
                defer { fts_close(stream) }
                while let entry = fts_read(stream) {
                    seen += 1
                    if seen % 8192 == 0, isCancelled() { break }
                    let kind = Int32(entry.pointee.fts_info)
                    if kind == FTS_D {
                        let name = (String(cString: entry.pointee.fts_path) as NSString).lastPathComponent
                        // Installed dependencies and repositories hold expected copies and have rules of their own.
                        if entry.pointee.fts_level > 0, skip.contains(String(cString: entry.pointee.fts_path)) || Self.dependencyFolders.contains(name) {
                            fts_set(stream, entry, FTS_SKIP)
                        }
                        continue
                    }
                    guard kind == FTS_F, let info = entry.pointee.fts_statp?.pointee else { continue }
                    let bytes = Int64(info.st_blocks) * 512
                    guard bytes >= smallest else { continue }
                    let file = LargeFile(path: String(cString: entry.pointee.fts_path), bytes: bytes, lastUse: Date(timeIntervalSince1970: TimeInterval(CacheTrimmer.lastUse(info))))
                    large.append((file, info.st_dev, UInt64(info.st_ino)))
                }
            }
        }
        // A file someone marked, or that lies in a marked folder, is not reported.
        large.removeAll { PathUtil.keepMarker(at: ($0.file.path as NSString).deletingLastPathComponent, stopAt: home) != nil }

        let old = large.map(\.file).filter { $0.bytes >= oldBytes && Int($0.lastUse.timeIntervalSince1970) < cutoff }.sorted { $0.bytes > $1.bytes }

        // Duplicates: same size first, then the same contents. Two names of one file are not copies.
        var bySize: [Int64: [(file: LargeFile, device: Int32, inode: UInt64)]] = [:]
        for item in large where item.file.bytes >= duplicateBytes {
            let size = Self.logicalSize(item.file.path) ?? item.file.bytes
            bySize[size, default: []].append(item)
        }
        var groups: [[LargeFile]] = []
        for (_, items) in bySize where items.count > 1 {
            var unique: [String: (file: LargeFile, device: Int32, inode: UInt64)] = [:]
            for item in items { unique["\(item.device):\(item.inode)"] = unique["\(item.device):\(item.inode)"] ?? item }
            guard unique.count > 1 else { continue }
            // A cheap look at the beginning and end, then the whole contents for those that still match.
            let byQuick = Dictionary(grouping: unique.values.map(\.file)) { Self.quickHash($0.path) ?? UUID().uuidString }
            for (_, candidates) in byQuick where candidates.count > 1 {
                let byFull = Dictionary(grouping: candidates) { Self.fullHash($0.path) ?? UUID().uuidString }
                for (_, same) in byFull where same.count > 1 { groups.append(same.sorted { $0.lastUse > $1.lastUse }) }
            }
            if isCancelled() { break }
        }
        groups.sort { $0.dropFirst().reduce(0) { $0 + $1.bytes } > $1.dropFirst().reduce(0) { $0 + $1.bytes } }
        return LargeFilesReport(old: old, duplicates: groups, filesSeen: seen)
    }

    static func logicalSize(_ path: String) -> Int64? {
        var info = stat()
        return lstat(path, &info) == 0 ? Int64(info.st_size) : nil
    }

    /// The first and last megabyte and the length.
    static func quickHash(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        guard let head = try? handle.read(upToCount: 1 << 20) else { return nil }
        hasher.update(data: head)
        if let length = try? handle.seekToEnd(), length > 2 << 20 {
            try? handle.seek(toOffset: length - (1 << 20))
            if let tail = try? handle.read(upToCount: 1 << 20) { hasher.update(data: tail) }
            hasher.update(data: Data(String(length).utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fullHash(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
