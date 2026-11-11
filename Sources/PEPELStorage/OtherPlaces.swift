import Darwin
import Foundation
import PEPELCore

/// Places that often grow large without anyone noticing, shown for information: PEPEL sizes
/// them and says when they were last used, and leaves the decision to the user. The one thing
/// it removes from here, on request or by rule, is old log files.
public struct OtherPlaces: Sendable {
    public let home: String

    public init(home: String) { self.home = home }

    /// Location, what it is, and whether each folder inside is listed separately.
    static let places: [(path: String, title: String, note: String, perEntry: Bool)] = [
        (".android/avd", "Android emulators", "One folder per virtual device, with its disk image.", true),
        (".rustup/toolchains", "Rust toolchains", "`rustup toolchain uninstall <name>` removes one.", true),
        (".pyenv/versions", "Python versions (pyenv)", "`pyenv uninstall <version>` removes one.", true),
        (".local/share/mise/installs", "Language versions (mise)", "`mise uninstall <tool>@<version>` removes one.", true),
        (".nvm/versions/node", "Node versions (nvm)", "`nvm uninstall <version>` removes one.", true),
        (".gradle", "Gradle home", "Gradle removes cache entries unused for 30 days by itself.", false),
        (".m2/repository", "Maven repository", "Downloaded artifacts; fetched again when needed.", false),
        ("Library/Developer/Xcode/iOS DeviceSupport", "Xcode device support", "Symbols for devices that were connected; recreated when a device connects.", true),
        ("Library/Developer/CoreSimulator/Caches", "Simulator caches", "Recreated by the simulator.", false),
        ("Library/Application Support/MobileSync/Backup", "iPhone and iPad backups", "Managed in Finder › device › Manage Backups.", true),
        (".local/share", "Application data in ~/.local/share", "Data of command-line tools; not a cache.", true),
    ]

    public func measure(minimumBytes: Int64 = 200 * Bytes.mb) -> [OtherPlace] {
        var result: [OtherPlace] = []
        for place in Self.places {
            let root = home + "/" + place.path
            var info = stat()
            guard lstat(root, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            let targets = place.perEntry
                ? ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).map { (root + "/" + $0, place.title + " · " + $0) }
                : [(root, place.title)]
            for (path, title) in targets {
                var entry = stat()
                guard lstat(path, &entry) == 0, (entry.st_mode & S_IFMT) == S_IFDIR else { continue }
                let measured = ApplicationDataScanner.measure(path)
                guard measured.bytes >= minimumBytes else { continue }
                result.append(OtherPlace(path: path, title: title, note: place.note, bytes: measured.bytes, lastUse: measured.lastUse, kept: PathUtil.keepMarker(at: path, stopAt: home) != nil))
            }
        }
        return result.sorted { $0.bytes > $1.bytes }
    }

    /// Agents keep their history in log-like files; those are never logs to PEPEL.
    static func isAgentPath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return ["codex", "claude", "hermes", "opencode"].contains { lowered.contains($0) }
    }

    /// Log files older than `days` and larger than 1 MB under `~/Library/Logs`.
    public func oldLogs(days: Int, now: Date = Date()) -> (bytes: Int64, files: [String]) {
        let root = home + "/Library/Logs"
        let cutoff = Int(now.timeIntervalSince1970) - days * 86_400
        var bytes: Int64 = 0
        var files: [String] = []
        guard PathUtil.keepMarker(at: root, stopAt: home) == nil else { return (0, []) }
        CacheTrimmer.walk(root) { path, size, lastUse in
            guard lastUse < cutoff, size >= Bytes.mb, !Self.isAgentPath(path) else { return }
            bytes += size
            files.append(path)
        }
        return (bytes, files)
    }

    /// Removes those log files. Each is looked at again right before it goes.
    public func removeOldLogs(days: Int, skip: Set<String> = [], now: Date = Date()) -> (bytes: Int64, removed: Int) {
        let cutoff = Int(now.timeIntervalSince1970) - days * 86_400
        var bytes: Int64 = 0
        var removed = 0
        for path in oldLogs(days: days, now: now).files where !skip.contains(RuleAction.pathKey(path)) {
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, CacheTrimmer.lastUse(info) < cutoff else { continue }
            if unlink(path) == 0 {
                bytes += Int64(info.st_blocks) * 512
                removed += 1
            }
        }
        return (bytes, removed)
    }
}
