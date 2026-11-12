import CoreServices
import Darwin
import Foundation
import PEPELCore

/// Lists installed applications with what Spotlight knows about their use, their size, and the
/// places in your Library where each keeps data. Only reads. Sandboxed apps' containers are
/// not looked into: macOS guards them and would ask for permission.
public struct InstalledAppsScanner: Sendable {
    public var home: String
    public var folders: [String]

    public init(home: String, folders: [String]? = nil) {
        self.home = home
        self.folders = folders ?? ["/Applications", home + "/Applications"]
    }

    /// Application bundles in the folders and one level of sub-folders (where people group them).
    public func bundlePaths() -> [String] {
        var paths: [String] = []
        // A link to an app elsewhere (people keep them to group apps) is the same app: listed once, where it is.
        func isLink(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
        }
        for folder in folders {
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted() {
                let path = folder + "/" + name
                if isLink(path) { continue }
                if name.hasSuffix(".app") {
                    paths.append(path)
                } else if !name.hasPrefix("."), (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeDirectory {
                    for inner in ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted() where inner.hasSuffix(".app") && !isLink(path + "/" + inner) { paths.append(path + "/" + inner) }
                }
            }
        }
        return paths
    }

    /// Where an app keeps data in your Library, by its bundle identifier and its name.
    static let places: [(folder: String, kind: String, byID: Bool, byName: Bool, suffix: String)] = [
        ("Library/Application Support", "Application Support", true, true, ""),
        ("Library/Caches", "Caches", true, false, ""),
        ("Library/Preferences", "Preferences", true, false, ".plist"),
        ("Library/Saved Application State", "Saved state", true, false, ".savedState"),
        ("Library/HTTPStorages", "Web data", true, false, ""),
        ("Library/WebKit", "Web data", true, false, ""),
        ("Library/Logs", "Logs", true, true, ""),
    ]

    public func dataPlaces(bundleID: String, name: String) -> [AppDataPlace] {
        var found: [AppDataPlace] = []
        var seen = Set<String>()
        for place in Self.places {
            var candidates: [String] = []
            if place.byID { candidates.append(bundleID + place.suffix) }
            // A name is only trusted when it is specific enough not to be shared ("Google" is not).
            if place.byName, name.count >= 4, !["Google", "Microsoft", "Apple", "Adobe"].contains(name) { candidates.append(name) }
            for candidate in candidates {
                let path = home + "/" + place.folder + "/" + candidate
                var info = stat()
                guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK, seen.insert(path).inserted else { continue }
                let bytes = (info.st_mode & S_IFMT) == S_IFDIR ? DirectorySizer().measure(path).allocatedBytes : Int64(info.st_blocks) * 512
                found.append(AppDataPlace(path: path, kind: place.kind, bytes: bytes))
            }
        }
        return found
    }

    /// When macOS last opened the app, how often, and when it arrived, from Spotlight.
    public static func spotlight(_ path: String) -> (lastUsed: Date?, useCount: Int?, added: Date?) {
        guard let item = MDItemCreate(nil, path as CFString) else { return (nil, nil, nil) }
        let last = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        let count = (MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? NSNumber)?.intValue
        let added = (MDItemCopyAttribute(item, kMDItemDateAdded) as? Date) ?? (try? FileManager.default.attributesOfItem(atPath: path)[.creationDate] as? Date)
        return (last, count, added)
    }

    public func app(at path: String) -> InstalledApp? {
        guard let data = FileManager.default.contents(atPath: path + "/Contents/Info.plist"),
            let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
            let bundleID = plist["CFBundleIdentifier"] as? String
        else { return nil }
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = [plist["CFBundleDisplayName"] as? String, plist["CFBundleName"] as? String, fileName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200E}\u{200F}"))) }.first { !$0.isEmpty } ?? fileName
        let meta = Self.spotlight(path)
        return InstalledApp(
            bundleID: bundleID, name: name, path: path, version: plist["CFBundleShortVersionString"] as? String, lastUsed: meta.lastUsed, useCount: meta.useCount,
            added: meta.added, bundleBytes: DirectorySizer().measure(path).allocatedBytes, data: dataPlaces(bundleID: bundleID, name: name),
            isApple: bundleID.hasPrefix("com.apple.") || path.hasPrefix("/System/"))
    }

    public func apps() -> [InstalledApp] {
        let paths = bundlePaths()
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var items: [InstalledApp?]
            init(_ count: Int) { items = Array(repeating: nil, count: count) }
            func set(_ index: Int, _ app: InstalledApp?) { lock.lock(); items[index] = app; lock.unlock() }
        }
        let results = Results(paths.count)
        // Several at once: measuring bundles is mostly waiting on the disk.
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in results.set(index, app(at: paths[index])) }
        return results.items.compactMap { $0 }
    }
}
