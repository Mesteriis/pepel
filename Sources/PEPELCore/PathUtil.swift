import Foundation

/// Identity of a filesystem object, taken with `lstat` (symlinks are never followed).
/// Used to detect that a path was swapped between scan time and cleanup time.
public struct FileIdentity: Hashable, Codable, Sendable {
    public var device: UInt64
    public var inode: UInt64
    public var isSymlink: Bool
    public var isDirectory: Bool

    public init(device: UInt64, inode: UInt64, isSymlink: Bool, isDirectory: Bool) {
        self.device = device
        self.inode = inode
        self.isSymlink = isSymlink
        self.isDirectory = isDirectory
    }

    /// Same object on disk (type flags are derived, so only device + inode are compared).
    public func sameObject(as other: FileIdentity) -> Bool {
        device == other.device && inode == other.inode
    }
}

public enum PathUtil {
    public static func expand(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    /// Absolute path with symlinks resolved. For paths that do not exist yet, the deepest existing
    /// ancestor is resolved and the remaining components are appended unchanged.
    public static func canonical(_ path: String, home: String = NSHomeDirectory()) -> String {
        let standardized = URL(fileURLWithPath: expand(path, home: home)).standardizedFileURL.path
        var tail: [String] = []
        var current = standardized
        while true {
            if let resolved = realpath(current, nil) {
                let base = String(cString: resolved)
                free(resolved)
                if tail.isEmpty { return base }
                let rest = tail.reversed().joined(separator: "/")
                return base == "/" ? "/" + rest : base + "/" + rest
            }
            if current == "/" || current.isEmpty { return standardized }
            tail.append((current as NSString).lastPathComponent)
            current = (current as NSString).deletingLastPathComponent
        }
    }

    /// Component-wise containment: `/a/bc` is not inside `/a/b`.
    public static func isInside(_ path: String, root: String) -> Bool {
        if root.isEmpty { return false }
        if path == root { return true }
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Conservative variant for protection checks on case-insensitive volumes.
    public static func isInsideIgnoringCase(_ path: String, root: String) -> Bool {
        isInside(path.lowercased(), root: root.lowercased())
    }

    public static func identity(_ path: String) -> FileIdentity? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let type = st.st_mode & S_IFMT
        return FileIdentity(
            device: UInt64(truncatingIfNeeded: st.st_dev),
            inode: UInt64(st.st_ino),
            isSymlink: type == S_IFLNK,
            isDirectory: type == S_IFDIR
        )
    }

    public static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    public static func isDirectory(_ path: String) -> Bool {
        identity(path)?.isDirectory ?? false
    }

    public static func modificationDate(_ path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    public static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// Shortens the home prefix for display only.
    public static func display(_ path: String, home: String = NSHomeDirectory()) -> String {
        isInside(path, root: home) ? "~" + path.dropFirst(home.count) : path
    }

    public struct Entry: Sendable {
        public var name: String
        public var isDirectory: Bool
        public var isSymlink: Bool
    }

    /// Directory entries with their type taken from the directory itself, so walking a tree does
    /// not need one `lstat` per file. Returns nil when the directory cannot be read.
    public static func entries(_ path: String) -> [Entry]? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        var result: [Entry] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var type = Int32(entry.pointee.d_type)
            if type == DT_UNKNOWN {
                // Some filesystems do not report the type; ask once for this entry.
                let identity = identity(path + "/" + name)
                type = identity?.isSymlink == true ? DT_LNK : identity?.isDirectory == true ? DT_DIR : DT_REG
            }
            result.append(Entry(name: name, isDirectory: type == DT_DIR, isSymlink: type == DT_LNK))
        }
        return result
    }

    /// Names of the entries in a directory, or nil when it cannot be read (missing or permission denied).
    public static func list(_ path: String) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: path)
    }
}

/// Where PEPEL keeps its own state and which parts of the machine it may look at.
public struct AppPaths: Sendable, Equatable {
    public var home: String
    public var supportDirectory: String
    /// The per-user temporary folder.
    public var temporaryDirectory: String
    /// The machine-wide temporary folder.
    public var sharedTemporaryDirectory: String

    /// - Parameter home: when this is not the real home directory (fixtures, `PEPEL_HOME`), the
    ///   temporary folders are redirected into it as well, so a redirected PEPEL can never see or
    ///   clean anything on the real machine.
    public init(
        home: String = NSHomeDirectory(), supportDirectory: String? = nil, temporaryDirectory: String? = nil,
        sharedTemporaryDirectory: String? = nil
    ) {
        self.home = home
        self.supportDirectory = supportDirectory ?? home + "/Library/Application Support/PEPEL"
        let real = PathUtil.canonical(home) == PathUtil.canonical(NSHomeDirectory())
        self.temporaryDirectory = temporaryDirectory ?? (real ? PathUtil.canonical(NSTemporaryDirectory()) : home + "/.pepel-tmp")
        self.sharedTemporaryDirectory = sharedTemporaryDirectory ?? (real ? "/private/tmp" : home + "/.pepel-shared-tmp")
    }

    /// True when PEPEL is pointed at something other than the user's real home directory.
    public var isRedirected: Bool { PathUtil.canonical(home) != PathUtil.canonical(NSHomeDirectory()) }

    public var database: String { supportDirectory + "/pepel.sqlite" }
    public var socket: String { supportDirectory + "/pepel.sock" }
    public var token: String { supportDirectory + "/api-token" }

    public func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(
            atPath: supportDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
}
