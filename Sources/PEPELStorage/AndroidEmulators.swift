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
        guard !running.contains(name) else { return L("It is running.") }
        guard let path = folder(of: name) else { return L("No such emulator.") }
        guard PathUtil.keepMarker(at: path, stopAt: home) == nil else { return L("It is marked as not to be cleaned.") }
        // In case it was started some other way: the emulator holds a lock while it runs. The lock
        // files themselves stay behind after it exits, so what counts is whether one is held.
        if Self.isLockHeld(path + "/multiinstance.lock") || Self.isLockHeld(path + "/hardware-qemu.ini.lock") {
            return L("It is running (its lock is held).")
        }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            return L("It could not be removed: \(error.localizedDescription)")
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

/// System images in the Android SDK. An emulator names the one it starts from in its
/// `config.ini` (`image.sysdir.1=system-images/android-36/google_apis/arm64-v8a/`); an image no
/// emulator names can be downloaded again by Android Studio or `sdkmanager` when it is needed.
public struct AndroidSystemImages: Sendable {
    public let home: String
    public let sdkRoots: [String]

    public init(home: String, sdkRoots: [String]? = nil) {
        self.home = home
        self.sdkRoots = sdkRoots ?? [home + "/Library/Android/sdk", "/opt/homebrew/share/android-commandlinetools", "/usr/local/share/android-commandlinetools"]
    }

    /// `system-images/<api>/<tag>/<abi>` relative to the SDK, as each emulator names it.
    func referenced() -> [String: [String]] {
        let avd = home + "/.android/avd"
        var result: [String: [String]] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: avd)) ?? [] where name.hasSuffix(".avd") {
            guard let config = try? String(contentsOfFile: avd + "/" + name + "/config.ini", encoding: .utf8) else { continue }
            for line in config.split(separator: "\n") where line.hasPrefix("image.sysdir.") {
                guard let value = line.split(separator: "=", maxSplits: 1).last else { continue }
                var relative = value.trimmingCharacters(in: .whitespaces)
                while relative.hasSuffix("/") { relative.removeLast() }
                if relative.hasPrefix("system-images/") { result[relative, default: []].append(String(name.dropLast(4))) }
            }
        }
        return result
    }

    public func list() -> [AndroidSystemImage] {
        let uses = referenced()
        var result: [AndroidSystemImage] = []
        for root in sdkRoots {
            let base = root + "/system-images"
            for api in (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [] {
                for tag in (try? FileManager.default.contentsOfDirectory(atPath: base + "/" + api)) ?? [] {
                    for abi in (try? FileManager.default.contentsOfDirectory(atPath: base + "/" + api + "/" + tag)) ?? [] {
                        let path = [base, api, tag, abi].joined(separator: "/")
                        var info = stat()
                        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
                        let id = [api, tag, abi].joined(separator: "/")
                        result.append(AndroidSystemImage(id: id, path: path, bytes: DirectorySizer().measure(path).allocatedBytes, usedBy: uses["system-images/" + id] ?? []))
                    }
                }
            }
        }
        return result.sorted { ($0.usedBy.isEmpty ? 1 : 0, $0.bytes) > ($1.usedBy.isEmpty ? 1 : 0, $1.bytes) }
    }

    /// Removes one image no emulator uses: exactly `<sdk>/system-images/<api>/<tag>/<abi>`, then
    /// the folders above it that are left empty.
    public func delete(_ id: String) -> String? {
        let parts = id.split(separator: "/").map(String.init)
        guard parts.count == 3, !parts.contains(where: { $0.isEmpty || $0.hasPrefix(".") || $0 == ".." }) else { return L("Not a system image.") }
        guard let image = list().first(where: { $0.id == id }) else { return L("No such system image.") }
        guard image.usedBy.isEmpty else { return L("Emulators start from it: \(image.usedBy.joined(separator: ", ")).") }
        guard PathUtil.keepMarker(at: image.path, stopAt: (image.path as NSString).deletingLastPathComponent) == nil else { return L("It is marked as not to be cleaned.") }
        do { try FileManager.default.removeItem(atPath: image.path) } catch { return L("It could not be removed: \(error.localizedDescription)") }
        var parent = (image.path as NSString).deletingLastPathComponent
        for _ in 0..<2 {
            guard ((try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? ["x"]).isEmpty else { break }
            rmdir(parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
        return nil
    }
}
