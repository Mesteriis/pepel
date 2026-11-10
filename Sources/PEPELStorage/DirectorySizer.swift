import Darwin
import Foundation
import PEPELCore

/// Remembers hard-linked files already counted during one scan so that data shared between
/// items (a package store and the projects linking into it, for example) is counted once.
public final class HardLinkLedger: @unchecked Sendable {
    private struct Key: Hashable {
        var device: Int32
        var inode: UInt64
    }

    private let lock = NSLock()
    private var seen = Set<Key>()

    public init() {}

    /// True the first time a file is offered.
    func claim(device: Int32, inode: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seen.insert(Key(device: device, inode: inode)).inserted
    }
}

/// Measures a directory tree. Symlinks are never followed and other volumes are never entered.
public struct DirectorySizer: Sendable {
    public init() {}

    public func measure(
        _ path: String, ledger: HardLinkLedger? = nil, isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) -> SizeInfo {
        var info = SizeInfo(measuredAt: Date())
        guard let cPath = strdup(path) else {
            info.inaccessibleCount = 1
            return info
        }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else {
            info.inaccessibleCount = 1
            return info
        }
        defer { fts_close(stream) }

        let localLedger = ledger ?? HardLinkLedger()
        var newest: Int = 0
        var visited = 0
        while let entry = fts_read(stream) {
            visited += 1
            if visited % 4096 == 0, isCancelled() {
                info.complete = false
                break
            }
            switch Int32(entry.pointee.fts_info) {
            case FTS_DNR, FTS_ERR, FTS_NS:
                info.inaccessibleCount += 1
            case FTS_DP:
                continue
            default:
                guard let st = entry.pointee.fts_statp?.pointee else { continue }
                let allocated = Int64(st.st_blocks) * 512
                let isRegular = st.st_mode & S_IFMT == S_IFREG
                if isRegular {
                    info.fileCount += 1
                    info.logicalBytes += Int64(st.st_size)
                }
                newest = max(newest, st.st_mtimespec.tv_sec)
                if isRegular, st.st_nlink > 1 {
                    info.hardLinkedBytes += allocated
                    if localLedger.claim(device: st.st_dev, inode: UInt64(st.st_ino)) { info.allocatedBytes += allocated }
                } else {
                    info.allocatedBytes += allocated
                }
            }
        }
        if newest > 0 { info.newestModification = Date(timeIntervalSince1970: TimeInterval(newest)) }
        return info
    }
}
