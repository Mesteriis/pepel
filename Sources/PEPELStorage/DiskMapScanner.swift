import Darwin
import Foundation
import PEPELCore

/// Measures a folder for the disk map: what each folder inside it holds, two levels deep, in one
/// walk. Links are never followed, other volumes are never entered, and folders macOS guards are
/// not read unless the walk starts inside one, which only happens when the user opens it.
public struct DiskMapScanner: Sendable {
    public let home: String

    public init(home: String) { self.home = home }

    /// Folders whose contents macOS protects. Reading them makes macOS ask the user for access,
    /// so the map shows them as closed tiles until one is opened on purpose.
    public var restricted: Set<String> {
        Set(
            [
                "Documents", "Desktop", "Downloads", "Pictures", ".Trash", "Library/Containers", "Library/Group Containers", "Library/Mobile Documents",
                "Library/CloudStorage", "Library/Mail", "Library/Messages", "Library/Safari", "Library/Calendars", "Library/Application Support/AddressBook",
            ].map { home + "/" + $0 })
    }

    public struct Progress: Sendable {
        public var bytes: Int64
        public var files: Int
        public var current: String
    }

    /// Files at least this large get a tile of their own; smaller ones are shown together.
    static let ownTile: Int64 = 8 * Bytes.mb

    /// - Parameter depth: how many levels below `root` get their own list of contents.
    public func scan(
        _ root: String, depth: Int = 2, isCancelled: @Sendable () -> Bool = { Task.isCancelled }, progress: (@Sendable (Progress) -> Void)? = nil
    ) -> [DiskLevel] {
        guard let cPath = strdup(root) else { return [] }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        // Links are never followed, except that the starting folder itself may be reached through one.
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_COMFOLLOW | FTS_XDEV | FTS_NOCHDIR, nil) else { return [] }
        defer { fts_close(stream) }

        struct Frame {
            var path: String
            var level: Int
            var bytes: Int64 = 0
            var files = 0
            var unreadable = 0
            var nodes: [DiskNode] = []
            var smallBytes: Int64 = 0
            var smallCount = 0
        }
        var stack: [Frame] = []
        var levels: [DiskLevel] = []
        let guarded = restricted
        let ledger = HardLinkLedger()
        var visited = 0
        var totalBytes: Int64 = 0
        var totalFiles = 0
        var complete = true

        while let entry = fts_read(stream) {
            visited += 1
            if visited % 8192 == 0 {
                if isCancelled() {
                    complete = false
                    break
                }
                progress?(Progress(bytes: totalBytes, files: totalFiles, current: stack.count > 1 ? stack[1].path : root))
            }
            let level = Int(entry.pointee.fts_level)
            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                let path = String(cString: entry.pointee.fts_path)
                // A guarded folder is shown closed, unless the walk was started on it.
                if level > 0, guarded.contains(path) {
                    fts_set(stream, entry, FTS_SKIP)
                    if !stack.isEmpty, stack[stack.count - 1].level < depth {
                        stack[stack.count - 1].nodes.append(DiskNode(path: path, name: (path as NSString).lastPathComponent, kind: .restricted, bytes: 0))
                    }
                    continue
                }
                stack.append(Frame(path: path, level: level))
            case FTS_DP:
                // A folder that was skipped is still reported on the way out; it has no frame of its own.
                guard let last = stack.last, last.path == String(cString: entry.pointee.fts_path), let frame = stack.popLast() else { continue }
                if frame.level < depth {
                    var nodes = frame.nodes
                    if frame.smallCount > 0 {
                        nodes.append(DiskNode(path: frame.path, name: "\(frame.smallCount) smaller files", kind: .smallFiles, bytes: frame.smallBytes, fileCount: frame.smallCount))
                    }
                    levels.append(DiskLevel(path: frame.path, nodes: nodes.sorted { $0.bytes > $1.bytes }))
                }
                guard !stack.isEmpty else { continue }
                let parent = stack.count - 1
                stack[parent].bytes += frame.bytes
                stack[parent].files += frame.files
                stack[parent].unreadable += frame.unreadable
                if stack[parent].level < depth {
                    stack[parent].nodes.append(
                        DiskNode(path: frame.path, name: (frame.path as NSString).lastPathComponent, kind: .folder, bytes: frame.bytes, fileCount: frame.files, unreadable: frame.unreadable))
                }
            case FTS_DNR, FTS_ERR, FTS_NS:
                // A folder that could not be read is reported this way instead of on the way out:
                // it leaves the stack here, as an empty folder that is known to be incomplete.
                if let last = stack.last, last.path == String(cString: entry.pointee.fts_path), let frame = stack.popLast(), !stack.isEmpty {
                    let parent = stack.count - 1
                    stack[parent].unreadable += frame.unreadable + 1
                    if stack[parent].level < depth {
                        stack[parent].nodes.append(DiskNode(path: frame.path, name: (frame.path as NSString).lastPathComponent, kind: .folder, bytes: frame.bytes, fileCount: frame.files, unreadable: frame.unreadable + 1))
                    }
                } else if !stack.isEmpty {
                    stack[stack.count - 1].unreadable += 1
                }
            default:
                guard !stack.isEmpty, let info = entry.pointee.fts_statp?.pointee else { continue }
                var size = Int64(info.st_blocks) * 512
                // A file with several names is counted where it is met first.
                if info.st_mode & S_IFMT == S_IFREG, info.st_nlink > 1, !ledger.claim(device: info.st_dev, inode: UInt64(info.st_ino)) { size = 0 }
                let top = stack.count - 1
                stack[top].bytes += size
                stack[top].files += 1
                totalBytes += size
                totalFiles += 1
                guard stack[top].level < depth else { continue }
                if size >= Self.ownTile {
                    let path = String(cString: entry.pointee.fts_path)
                    stack[top].nodes.append(DiskNode(path: path, name: (path as NSString).lastPathComponent, kind: .file, bytes: size, fileCount: 1))
                } else {
                    stack[top].smallBytes += size
                    stack[top].smallCount += 1
                }
            }
        }
        if !complete {
            // Whatever was open when the walk stopped is reported as far as it got.
            while let frame = stack.popLast() {
                guard frame.level < depth else { continue }
                levels.append(DiskLevel(path: frame.path, nodes: frame.nodes.sorted { $0.bytes > $1.bytes }, complete: false))
            }
        }
        return levels
    }
}
