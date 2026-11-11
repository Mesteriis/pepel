import Darwin
import Foundation
import PEPELCore

/// Clears what has been forgotten in the user's temporary folder.
///
/// macOS empties that folder only on restart, and only of what has not been used for three
/// days, so on a Mac that stays on it grows without limit. An entry is removed when nothing in
/// it was read or written for N days. Left alone, whatever their age: sockets and pipes (they
/// are live connections, and their dates never change), folders that contain one, anything the
/// system manages (`com.apple.*`), anything a running program names or works in, entries of
/// another user, links, and anything marked as not to be cleaned.
public struct TempCleaner: Sendable {
    public let directory: String

    public init(directory: String) { self.directory = directory }

    /// What a walk of one entry found.
    struct Inspection {
        var bytes: Int64 = 0
        var lastUse = 0
        /// A socket, pipe or device inside: something is, or was, talking through it.
        var hasLiveEndpoint = false
    }

    static func inspect(_ path: String) -> Inspection {
        var result = Inspection()
        guard let cPath = strdup(path) else { return result }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return result }
        defer { fts_close(stream) }
        while let entry = fts_read(stream) {
            guard Int32(entry.pointee.fts_info) != FTS_DP, let info = entry.pointee.fts_statp?.pointee else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFSOCK, S_IFIFO, S_IFCHR, S_IFBLK:
                result.hasLiveEndpoint = true
            case S_IFREG:
                result.bytes += Int64(info.st_blocks) * 512
                result.lastUse = max(result.lastUse, CacheTrimmer.lastUse(info))
            default:
                // A folder's own dates change when something is added or removed inside it.
                result.lastUse = max(result.lastUse, info.st_mtimespec.tv_sec)
            }
        }
        return result
    }

    /// - Parameters:
    ///   - running: names and bundle identifiers of running programs.
    ///   - busyPaths: working directories and command-line arguments of running programs.
    public func entries(days: Int, running: Set<String> = [], busyPaths: [String] = [], uid: UInt32 = getuid(), now: Date = Date()) -> [TempEntry] {
        let cutoff = Int(now.timeIntervalSince1970) - days * 86_400
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let lowered = Set(running.map { $0.lowercased() })
        return names.compactMap { name -> TempEntry? in
            let path = directory + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG else { return nil }
            let inspection = Self.inspect(path)
            var entry = TempEntry(path: path, name: name, bytes: inspection.bytes, lastUse: Date(timeIntervalSince1970: TimeInterval(inspection.lastUse)), isDirectory: kind == S_IFDIR)
            let key = name.lowercased()
            if info.st_uid != uid {
                entry.keptBecause = "It belongs to another user."
            } else if key.hasPrefix("com.apple.") || key == "temporaryitems" || key.hasPrefix(".") {
                entry.keptBecause = "macOS manages it."
            } else if inspection.hasLiveEndpoint {
                entry.keptBecause = "It holds a socket or pipe: a program is, or was, connected through it."
            } else if lowered.contains(where: { key == $0 || key.hasPrefix($0 + ".") || key.hasPrefix($0 + "-") }) {
                entry.keptBecause = "A running program uses that name."
            } else if busyPaths.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) {
                entry.keptBecause = "A running program works in it."
            } else if PathUtil.keepMarker(at: path, stopAt: directory) != nil {
                entry.keptBecause = "It is marked as not to be cleaned."
            } else if inspection.lastUse >= cutoff {
                entry.keptBecause = "Used within the last \(days) days."
            }
            return entry
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// Removes the entries that are not kept. Each is inspected again right before it goes.
    public func clean(days: Int, running: Set<String> = [], busyPaths: [String] = [], now: Date = Date()) -> (bytes: Int64, removed: Int) {
        let cutoff = Int(now.timeIntervalSince1970) - days * 86_400
        var bytes: Int64 = 0
        var removed = 0
        for entry in entries(days: days, running: running, busyPaths: busyPaths, now: now) where entry.keptBecause == nil {
            var info = stat()
            guard lstat(entry.path, &info) == 0, [S_IFDIR, S_IFREG].contains(info.st_mode & S_IFMT) else { continue }
            let again = Self.inspect(entry.path)
            guard !again.hasLiveEndpoint, again.lastUse < cutoff else { continue }
            if (try? FileManager.default.removeItem(atPath: entry.path)) != nil {
                bytes += again.bytes
                removed += 1
            }
        }
        return (bytes, removed)
    }
}
