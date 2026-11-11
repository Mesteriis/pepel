import Darwin
import Foundation
import PEPELCore

/// Android virtual devices in `~/.android/avd`. Each is a `<name>.ini` that points at a
/// `<name>.avd` folder; deleting a device removes both, which is what `avdmanager delete avd`
/// and Android Studio's Device Manager do.
public struct AndroidEmulators: Sendable {
    public let home: String

    public init(home: String) { self.home = home }

    var directory: String { home + "/.android/avd" }

    /// An emulator runs as `qemu-system-…` (started by `emulator`) with `-avd <name>` or `@<name>`.
    public static func runningNames(_ processes: [ProcessSnapshot]) -> Set<String> {
        var names = Set<String>()
        for p in processes where p.name.hasPrefix("qemu-system") || p.name == "emulator" || p.name.hasPrefix("emulator") {
            for (index, argument) in p.arguments.enumerated() {
                if argument == "-avd", index + 1 < p.arguments.count { names.insert(p.arguments[index + 1]) }
                if argument.hasPrefix("@"), argument.count > 1 { names.insert(String(argument.dropFirst())) }
            }
        }
        return names
    }

    static func value(_ key: String, in ini: String) -> String? {
        ini.split(separator: "\n").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces) }
    }

    /// The device's folder, only when it is the real folder inside `~/.android/avd`.
    public func folder(of name: String) -> String? {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return nil }
        let path = directory + "/" + name + ".avd"
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return path
    }

    public func list(running: Set<String>) -> [AndroidEmulator] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter { $0.hasSuffix(".ini") }.map { String($0.dropLast(4)) }
        return names.compactMap { name -> AndroidEmulator? in
            guard let path = folder(of: name) else { return nil }
            let ini = (try? String(contentsOfFile: directory + "/" + name + ".ini", encoding: .utf8)) ?? ""
            let measured = DirectorySizer().measure(path)
            return AndroidEmulator(
                name: name, path: path, bytes: measured.allocatedBytes, lastUse: measured.newestModification, target: Self.value("target", in: ini), running: running.contains(name))
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// Deletes one device: its folder, then its `.ini`. Returns why it was not deleted.
    public func delete(_ name: String, running: Set<String>) -> String? {
        guard !running.contains(name) else { return "It is running." }
        guard let path = folder(of: name) else { return "No such emulator." }
        guard PathUtil.keepMarker(at: path, stopAt: home) == nil else { return "It is marked as not to be cleaned." }
        // In case it was started some other way: the emulator holds a lock while it runs. The lock
        // files themselves stay behind after it exits, so what counts is whether one is held.
        if Self.isLockHeld(path + "/multiinstance.lock") || Self.isLockHeld(path + "/hardware-qemu.ini.lock") {
            return "It is running (its lock is held)."
        }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            return "It could not be removed: \(error.localizedDescription)"
        }
        try? FileManager.default.removeItem(atPath: directory + "/" + name + ".ini")
        return nil
    }

    /// Whether some process holds a lock on the file, or (older emulators) whether the process
    /// named in a lock folder is alive. A lock file nobody holds is what an exited emulator leaves.
    static func isLockHeld(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            guard let text = try? String(contentsOfFile: path + "/pid", encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            return kill(pid, 0) == 0 || errno == EPERM
        }
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        // A record lock held by another process.
        var probe = flock()
        probe.l_type = Int16(F_WRLCK)
        probe.l_whence = Int16(SEEK_SET)
        if fcntl(descriptor, F_GETLK, &probe) == 0, probe.l_type != Int16(F_UNLCK) { return true }
        // A whole-file lock, by anyone.
        if systemFlock(descriptor, LOCK_SH | LOCK_NB) != 0 { return errno == EWOULDBLOCK }
        _ = systemFlock(descriptor, LOCK_UN)
        return false
    }
}

/// `flock(2)`. In Swift the name also means the C struct used with `fcntl`, so it is reached by its symbol.
@_silgen_name("flock") public func systemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32
