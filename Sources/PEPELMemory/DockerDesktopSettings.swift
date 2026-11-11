import Foundation
import PEPELCore

/// Reads and changes the one Docker Desktop setting PEPEL cares about: the memory limit of its
/// virtual machine. Docker Desktop reads the file when it starts, so a change is written while it
/// is stopped; every other key is kept as it was.
public struct DockerDesktopSettings: Sendable {
    public let path: String

    public init(home: String) { path = home + "/Library/Group Containers/group.com.docker/settings-store.json" }
    public init(path: String) { self.path = path }

    static let key = "MemoryMiB"

    private func load() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public func memoryLimitBytes() -> Int64? {
        (load()?[Self.key] as? NSNumber).map { $0.int64Value << 20 }
    }

    public enum Failure: Error, Equatable {
        case unreadable, notWritten
    }

    /// Writes the limit, rounded down to whole MiB. The file as it was before PEPEL's first
    /// change is copied to `backupDirectory` once.
    public func setMemoryLimit(_ bytes: Int64, backupDirectory: String?) throws {
        guard var settings = load() else { throw Failure.unreadable }
        if let backupDirectory {
            let backup = backupDirectory + "/docker-settings-store.json"
            if !FileManager.default.fileExists(atPath: backup) {
                try? FileManager.default.createDirectory(atPath: backupDirectory, withIntermediateDirectories: true)
                try? FileManager.default.copyItem(atPath: path, toPath: backup)
            }
        }
        settings[Self.key] = Int(bytes >> 20)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        do { try data.write(to: URL(fileURLWithPath: path), options: .atomic) } catch { throw Failure.notWritten }
    }
}
