import Darwin
import Foundation
import PEPELCore

/// Applications installed on this Mac, by bundle identifier and by name.
public struct InstalledApplications: Sendable {
    public var bundleIDs: Set<String>
    public var names: Set<String>

    public init(bundleIDs: Set<String>, names: Set<String>) {
        self.bundleIDs = Set(bundleIDs.map { $0.lowercased() })
        self.names = Set(names.map { $0.lowercased() })
    }

    /// Reads application bundles from Spotlight (which knows about every one, wherever it
    /// lives) and from the usual folders, in case Spotlight is switched off.
    public static func find(tools: ToolRunner, home: String) -> InstalledApplications {
        var paths = Set<String>()
        if let found = tools.run("mdfind", ["kMDItemContentType == 'com.apple.application-bundle'"], timeout: 20), found.status == 0 {
            paths.formUnion(found.output.split(separator: "\n").map(String.init))
        }
        for folder in ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities", home + "/Applications"] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
                let path = folder + "/" + name
                if name.hasSuffix(".app") { paths.insert(path) } else {
                    // One level of sub-folders, where people keep groups of applications.
                    for inner in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] where inner.hasSuffix(".app") { paths.insert(path + "/" + inner) }
                }
            }
        }
        var ids = Set<String>(), names = Set<String>()
        for path in paths {
            names.insert(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
            guard let data = FileManager.default.contents(atPath: path + "/Contents/Info.plist"),
                let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
            else { continue }
            if let id = plist["CFBundleIdentifier"] as? String { ids.insert(id) }
            if let name = plist["CFBundleName"] as? String { names.insert(name) }
        }
        return InstalledApplications(bundleIDs: ids, names: names)
    }

    static func looksLikeBundleID(_ name: String) -> Bool {
        // Reverse-DNS: three or more dot-separated words without spaces, starting with a short lowercase one.
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, !name.contains(" "), let first = parts.first, (2...10).contains(first.count) else { return false }
        return first.allSatisfy { $0.isLetter && $0.isLowercase } && parts.allSatisfy { !$0.isEmpty }
    }

    /// Who a folder in the Library belongs to, judged by its name.
    public func owner(of folder: String, running: Set<String>) -> ApplicationDataOwner {
        var name = folder.lowercased()
        for suffix in [".savedstate", ".binarycookies", ".plist"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
        func isRunning(_ candidate: String) -> Bool { running.contains { $0.lowercased() == candidate || candidate.hasPrefix($0.lowercased() + ".") } }
        if Self.looksLikeBundleID(name) {
            // An application's helpers and updaters use its identifier as a prefix.
            if let id = bundleIDs.first(where: { name == $0 || name.hasPrefix($0 + ".") || $0.hasPrefix(name + ".") }) {
                return isRunning(id) || isRunning(name) ? .running : .installed
            }
            return .removed
        }
        if names.contains(name) || bundleIDs.contains(where: { $0.split(separator: ".").contains(Substring(name)) }) {
            return running.contains { $0.lowercased().split(separator: ".").contains(Substring(name)) } ? .running : .installed
        }
        return .unknown
    }
}

/// Finds application caches and what removed applications left in the Library.
public struct ApplicationDataScanner: Sendable {
    public let home: String
    public let installed: InstalledApplications
    /// Bundle identifiers of applications that are running.
    public let running: Set<String>

    public init(home: String, installed: InstalledApplications, running: Set<String>) {
        self.home = home
        self.installed = installed
        self.running = running
    }

    /// Caches other parts of PEPEL manage with rules of their own, or that belong to the system.
    static func isManagedElsewhere(_ name: String) -> Bool {
        let managed = Set(CacheTrimmer.caches.compactMap { $0.path.hasPrefix("Library/Caches/") ? String($0.path.dropFirst("Library/Caches/".count)) : nil })
        return managed.contains(name) || name.lowercased().hasPrefix("com.apple.") || name.lowercased().contains("pepel") || name.hasPrefix(".")
    }

    static func measure(_ path: String) -> (bytes: Int64, lastUse: Date?) {
        var bytes: Int64 = 0
        var newest = 0
        CacheTrimmer.walk(path) { _, size, lastUse in
            bytes += size
            newest = max(newest, lastUse)
        }
        return (bytes, newest > 0 ? Date(timeIntervalSince1970: TimeInterval(newest)) : nil)
    }

    /// Real directories directly inside one Library folder.
    func folders(in relative: String) -> [(name: String, path: String)] {
        let root = home + "/" + relative
        return ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).compactMap { name in
            var info = stat()
            guard lstat(root + "/" + name, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
            return (name, root + "/" + name)
        }
    }

    /// Every folder in `~/Library/Caches` that is not managed elsewhere, largest first.
    public func caches(minimumBytes: Int64 = 20 * Bytes.mb) -> [ApplicationData] {
        folders(in: "Library/Caches").compactMap { folder -> ApplicationData? in
            guard !Self.isManagedElsewhere(folder.name) else { return nil }
            let measured = Self.measure(folder.path)
            guard measured.bytes >= minimumBytes else { return nil }
            return ApplicationData(name: folder.name, path: folder.path, kind: .cache, owner: installed.owner(of: folder.name, running: running), bytes: measured.bytes, lastUse: measured.lastUse)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// What applications that are no longer installed left behind. Only folders named by a
    /// bundle identifier are considered: a plain name says too little about whose it is.
    public func leftovers(minimumBytes: Int64 = Bytes.mb) -> [ApplicationData] {
        var result: [ApplicationData] = []
        for relative in ["Library/Application Support", "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit", "Library/Logs"] {
            for folder in folders(in: relative) where installed.owner(of: folder.name, running: running) == .removed {
                let measured = Self.measure(folder.path)
                guard measured.bytes >= minimumBytes else { continue }
                result.append(ApplicationData(name: folder.name, path: folder.path, kind: .leftover, owner: .removed, bytes: measured.bytes, lastUse: measured.lastUse))
            }
        }
        return result.sorted { $0.bytes > $1.bytes }
    }

    /// True when `path` is exactly one folder inside one of the Library folders PEPEL looks at,
    /// and is a real directory: the only shape that is ever removed or moved to the Trash.
    public func isManageable(_ item: ApplicationData) -> Bool {
        let parents = item.kind == .cache
            ? ["Library/Caches"] : ["Library/Application Support", "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit", "Library/Logs"]
        let name = (item.path as NSString).lastPathComponent
        guard !name.isEmpty, !name.hasPrefix("."), parents.contains(where: { item.path == home + "/" + $0 + "/" + name }) else { return false }
        if item.kind == .cache, Self.isManagedElsewhere(name) { return false }
        guard PathUtil.keepMarker(at: item.path, stopAt: home) == nil else { return false }
        var info = stat()
        return lstat(item.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }
}
