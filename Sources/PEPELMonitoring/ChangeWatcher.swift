import CoreServices
import Foundation

/// Collects directory-level change notifications from FSEvents so a scan only re-measures what
/// changed. Coarse on purpose: directory granularity and a long latency keep the overhead negligible.
public final class ChangeWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var dirty = Set<String>()
    private var overflowed = false
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "pepel.change-watcher", qos: .utility)
    private static let limit = 20_000

    public init() {}

    deinit { stop() }

    public var isWatching: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stream != nil
    }

    public func watch(paths: [String]) {
        stop()
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<ChangeWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            var mustRescan = false
            for index in 0..<count where flags[index] & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                mustRescan = true
            }
            watcher.record(paths, overflow: mustRescan)
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard
            let created = FSEventStreamCreate(
                nil, callback, &context, existing as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 15, flags)
        else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        lock.lock()
        stream = created
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let current = stream
        stream = nil
        lock.unlock()
        guard let current else { return }
        FSEventStreamStop(current)
        FSEventStreamInvalidate(current)
        FSEventStreamRelease(current)
    }

    private func record(_ paths: [String], overflow: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if overflow || dirty.count + paths.count > Self.limit {
            overflowed = true
            dirty.removeAll()
            return
        }
        for path in paths {
            dirty.insert(path.hasSuffix("/") ? String(path.dropLast()) : path)
        }
    }

    public var hasChanges: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overflowed || !dirty.isEmpty
    }

    /// Returns and clears the changed directories. `everything` means too much changed to track
    /// individually and all cached measurements must be discarded.
    public func drain() -> (paths: Set<String>, everything: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let result = (dirty, overflowed)
        dirty.removeAll()
        overflowed = false
        return result
    }
}
