import Darwin
import Foundation
import PEPELCore

/// Backups Clausona makes before it switches profiles or migrates history. Each is a folder;
/// the live history they copy stays where the agents keep it. Retention keeps the newest few of
/// each set and lets the older ones go after a while.
public struct ToolBackups: Sendable {
    public let home: String

    public init(home: String) { self.home = home }

    struct BackupSet {
        var name: String
        /// Folders whose subfolders are the backups.
        var parents: [String]
        /// Only subfolders whose name starts with this, when set.
        var prefix: String?
        /// A lock file the tool holds while it works.
        var lock: String?
    }

    var sets: [BackupSet] {
        let setupRoot = home + "/.local/share/clausona-setup"
        let dated = ((try? FileManager.default.contentsOfDirectory(atPath: setupRoot)) ?? []).map { setupRoot + "/" + $0 }
        return [
            BackupSet(name: "Clausona · Codex profile switches", parents: [home + "/.local/state/clausona-codex/backups"], lock: home + "/.local/state/clausona-codex/switch.lock"),
            BackupSet(name: "Clausona · Desktop profile switches", parents: [home + "/.local/state/clausona-desktop/backups"], lock: home + "/.local/state/clausona-desktop/switch.lock"),
            BackupSet(name: "Clausona · setup snapshots", parents: dated, prefix: "before-"),
        ]
    }

    /// The backup's date: Clausona puts a nanosecond timestamp in the name; otherwise the folder's own date.
    static func date(of path: String) -> Date? {
        let name = (path as NSString).lastPathComponent
        if let digits = name.split(separator: "-").last.map(String.init), digits.count >= 16, digits.allSatisfy(\.isNumber), let ns = Double(digits) {
            let seconds = ns / 1e9
            if seconds > 1_500_000_000, seconds < 4_000_000_000 { return Date(timeIntervalSince1970: seconds) }
        }
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }

    /// Every backup with whether retention keeps it: the `keep` newest of each set are kept,
    /// and so is anything younger than `days`.
    public func list(keep: Int, days: Int, now: Date = Date()) -> [ToolBackup] {
        var result: [ToolBackup] = []
        for set in sets {
            var found: [(path: String, date: Date)] = []
            for parent in set.parents {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? [] where set.prefix.map(name.hasPrefix) ?? true {
                    let path = parent + "/" + name
                    var info = stat()
                    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, let date = Self.date(of: path) else { continue }
                    found.append((path, date))
                }
            }
            found.sort { $0.date > $1.date }
            for (index, item) in found.enumerated() {
                let old = now.timeIntervalSince(item.date) >= Double(days) * 86_400
                result.append(ToolBackup(path: item.path, set: set.name, createdAt: item.date, bytes: DirectorySizer().measure(item.path).allocatedBytes, kept: index < keep || !old))
            }
        }
        return result
    }

    /// The set a path belongs to, when it is one of the backups this knows.
    func owningSet(of path: String) -> BackupSet? {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        return sets.first { $0.parents.contains(parent) && ($0.prefix.map(name.hasPrefix) ?? true) }
    }

    /// Removes the backups retention does not keep. A set whose tool is working is left alone.
    public func clean(keep: Int, days: Int, skip: Set<String> = [], now: Date = Date()) -> (bytes: Int64, removed: Int, skipped: [String]) {
        var bytes: Int64 = 0
        var removed = 0
        var skipped: [String] = []
        for backup in list(keep: keep, days: days, now: now) where !backup.kept && !skip.contains(RuleAction.pathKey(backup.path)) {
            guard let set = owningSet(of: backup.path) else { continue }
            if let lock = set.lock, AndroidEmulators.isLockHeld(lock) {
                skipped.append("\(set.name): Clausona is switching profiles right now.")
                continue
            }
            if PathUtil.keepMarker(at: backup.path, stopAt: home) != nil {
                skipped.append("\((backup.path as NSString).lastPathComponent) is marked as not to be cleaned.")
                continue
            }
            var info = stat()
            guard lstat(backup.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            if (try? FileManager.default.removeItem(atPath: backup.path)) != nil {
                bytes += backup.bytes
                removed += 1
            }
        }
        return (bytes, removed, Array(Set(skipped)).sorted())
    }
}
