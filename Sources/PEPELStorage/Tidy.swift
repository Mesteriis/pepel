import Darwin
import Foundation
import PEPELCore

/// Tidies the Downloads folder and screenshots on the Desktop.
///
/// A screenshot or screen recording is recognised only by the marks macOS puts on it when it
/// makes one, never by its name: a recording someone edited and saved under a similar name is
/// their work. On the Desktop nothing but those is ever touched. In Downloads anything not used
/// for the configured time goes, except files with a Finder tag, kept kinds (installers,
/// archives, disk images by default) and marked folders.
public struct Tidy: Sendable {
    public let home: String
    public let downloads: String
    /// Folders screenshots are saved to: the Desktop, Downloads, and macOS's own setting.
    public let screenshotFolders: [String]

    public init(home: String, screenshotLocation: String? = nil) {
        self.home = home
        downloads = home + "/Downloads"
        var folders = [home + "/Desktop", home + "/Downloads"]
        if let location = screenshotLocation.map({ PathUtil.expand($0) }), !folders.contains(location) { folders.append(location) }
        screenshotFolders = folders
    }

    /// Where macOS saves screenshots, when the user changed it.
    public static func systemScreenshotLocation() -> String? {
        UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
    }

    static let screenCaptureMarks = ["com.apple.metadata:kMDItemIsScreenCapture", "com.apple.metadata:kMDItemIsScreenRecording", "com.apple.metadata:kMDItemScreenCaptureType"]
    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload", "tmp"]

    static func hasAttribute(_ path: String, _ name: String) -> Bool { getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0 }

    public static func isScreenCapture(_ path: String) -> Bool { screenCaptureMarks.contains { hasAttribute(path, $0) } }

    /// Finder tags are stored as a property list in this attribute; any tag at all means "this matters".
    public static func hasFinderTag(_ path: String) -> Bool {
        let size = getxattr(path, "com.apple.metadata:_kMDItemUserTags", nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return false }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read > 0, let tags = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] else { return false }
        return !tags.isEmpty
    }

    /// When the person last opened the file, as macOS records it (Finder and apps set it; a
    /// backup or indexer reading the file does not, unlike the file system's access time).
    static func lastOpened(_ path: String) -> Int? {
        var stamp = timespec()
        let read = withUnsafeMutableBytes(of: &stamp) { getxattr(path, "com.apple.lastuseddate#PS", $0.baseAddress, MemoryLayout<timespec>.size, 0, XATTR_NOFOLLOW) }
        return read == MemoryLayout<timespec>.size && stamp.tv_sec > 0 ? stamp.tv_sec : nil
    }

    /// Size and the moment that counts for its age.
    /// - Screenshots: when they were taken.
    /// - Downloads: the newest of when it arrived, was changed and was last opened by the person;
    ///   for a folder, the newest of those for anything in it.
    static func inspect(_ path: String, _ info: stat, screenshot: Bool = false) -> (bytes: Int64, lastUse: Int) {
        if (info.st_mode & S_IFMT) == S_IFREG {
            let bytes = Int64(info.st_blocks) * 512
            if screenshot { return (bytes, info.st_birthtimespec.tv_sec) }
            return (bytes, max(info.st_birthtimespec.tv_sec, info.st_mtimespec.tv_sec, lastOpened(path) ?? 0))
        }
        var bytes: Int64 = 0
        var newest = max(info.st_birthtimespec.tv_sec, lastOpened(path) ?? 0)
        guard let cPath = strdup(path) else { return (0, newest) }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        if let stream = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) {
            defer { fts_close(stream) }
            while let entry = fts_read(stream) {
                guard Int32(entry.pointee.fts_info) == FTS_F, let file = entry.pointee.fts_statp?.pointee else { continue }
                bytes += Int64(file.st_blocks) * 512
                newest = max(newest, file.st_birthtimespec.tv_sec, file.st_mtimespec.tv_sec, lastOpened(String(cString: entry.pointee.fts_path)) ?? 0)
            }
        }
        return (bytes, newest)
    }

    /// Everything tidying looks at, each with whether it would go.
    public func items(screenshotDays: Int, downloadDays: Int, keepExtensions: Set<String>, includeScreenshots: Bool = true, includeDownloads: Bool = true, now: Date = Date()) -> [TidyItem] {
        let keep = Set(keepExtensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) })
        var result: [TidyItem] = []
        var seen = Set<String>()
        func entries(_ folder: String) -> [(name: String, path: String, info: stat)] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).compactMap { name in
                guard !name.hasPrefix(".") else { return nil }
                let path = folder + "/" + name
                var info = stat()
                guard lstat(path, &info) == 0 else { return nil }
                let kind = info.st_mode & S_IFMT
                guard kind == S_IFREG || kind == S_IFDIR else { return nil }
                return (name, path, info)
            }
        }
        if includeScreenshots {
            for folder in screenshotFolders {
                for entry in entries(folder) where (entry.info.st_mode & S_IFMT) == S_IFREG && Self.isScreenCapture(entry.path) && seen.insert(entry.path).inserted {
                    let measured = Self.inspect(entry.path, entry.info, screenshot: true)
                    var item = TidyItem(path: entry.path, name: entry.name, kind: .screenshot, bytes: measured.bytes, lastUse: Date(timeIntervalSince1970: TimeInterval(measured.lastUse)), keptBecause: nil)
                    item.keptBecause = reason(item, days: screenshotDays, keep: [], now: now)
                    result.append(item)
                }
            }
        }
        if includeDownloads {
            for entry in entries(downloads) where seen.insert(entry.path).inserted {
                let ext = (entry.name as NSString).pathExtension.lowercased()
                let partial = Self.partialExtensions.contains(ext)
                let measured = Self.inspect(entry.path, entry.info)
                var item = TidyItem(
                    path: entry.path, name: entry.name, kind: partial ? .partial : .download, bytes: measured.bytes,
                    lastUse: Date(timeIntervalSince1970: TimeInterval(measured.lastUse)), keptBecause: nil)
                // An unfinished download is litter after a day, whatever the age setting.
                item.keptBecause = reason(item, days: partial ? 1 : downloadDays, keep: partial ? [] : keep, now: now)
                result.append(item)
            }
        }
        return result.sorted { ($0.keptBecause == nil ? 1 : 0, $0.bytes) > ($1.keptBecause == nil ? 1 : 0, $1.bytes) }
    }

    func reason(_ item: TidyItem, days: Int, keep: Set<String>, now: Date) -> String? {
        let ext = (item.name as NSString).pathExtension.lowercased()
        // "archive.tar.gz" is kept by "tar.gz" as well as by "gz".
        let double = ((item.name as NSString).deletingPathExtension as NSString).pathExtension.lowercased()
        if !keep.isEmpty, keep.contains(ext) || (!double.isEmpty && keep.contains(double + "." + ext)) { return L("Kept kind: .\(ext)") }
        if Self.hasFinderTag(item.path) { return L("It has a Finder tag.") }
        if PathUtil.keepMarker(at: item.path, stopAt: home) != nil { return L("It is marked as not to be cleaned.") }
        let age = now.timeIntervalSince(item.lastUse)
        if age < Double(days) * 86_400 {
            let waited = TimeFormat.age(max(0, age))
            return item.kind == .screenshot
                ? L("Taken \(waited) ago; tidying waits \(days) days.")
                : L("Arrived, changed or opened \(waited) ago; tidying waits \(days) days.")
        }
        return nil
    }

    /// Takes what is not kept. Each item is looked at again right before it goes.
    /// - Parameter trashDirectory: for a redirected PEPEL, a stand-in for the real Trash.
    public func clean(
        screenshotDays: Int, downloadDays: Int, keepExtensions: Set<String>, includeScreenshots: Bool, includeDownloads: Bool, action: TidyAction,
        trashDirectory: String? = nil, skip: Set<String> = [], now: Date = Date()
    ) -> (bytes: Int64, removed: Int, trashed: [TrashRecord]) {
        var bytes: Int64 = 0
        var removed = 0
        var trashed: [TrashRecord] = []
        for item in items(screenshotDays: screenshotDays, downloadDays: downloadDays, keepExtensions: keepExtensions, includeScreenshots: includeScreenshots, includeDownloads: includeDownloads, now: now)
        where item.keptBecause == nil && !skip.contains(RuleAction.pathKey(item.path)) {
            var info = stat()
            guard lstat(item.path, &info) == 0, [S_IFREG, S_IFDIR].contains(info.st_mode & S_IFMT) else { continue }
            let again = Self.inspect(item.path, info, screenshot: item.kind == .screenshot)
            let days = item.kind == .screenshot ? screenshotDays : item.kind == .partial ? 1 : downloadDays
            guard now.timeIntervalSince1970 - Double(again.lastUse) >= Double(days) * 86_400 else { continue }
            var done = false
            switch action {
            case .delete:
                done = (try? FileManager.default.removeItem(atPath: item.path)) != nil
            case .trash:
                var destination: String?
                if let trashDirectory {
                    try? FileManager.default.createDirectory(atPath: trashDirectory, withIntermediateDirectories: true)
                    let target = trashDirectory + "/" + UUID().uuidString.prefix(6) + "-" + item.name
                    if (try? FileManager.default.moveItem(atPath: item.path, toPath: target)) != nil { destination = target }
                } else {
                    var resulting: NSURL?
                    if (try? FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: &resulting)) != nil { destination = resulting?.path ?? "" }
                }
                done = destination != nil
                if let destination, !destination.isEmpty {
                    trashed.append(TrashRecord(source: item.kind == .screenshot ? "Screenshots" : "Downloads", originalPath: item.path, trashedPath: destination, bytes: again.bytes))
                }
            }
            if done {
                bytes += again.bytes
                removed += 1
            }
        }
        return (bytes, removed, trashed)
    }
}
