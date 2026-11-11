import Foundation
import PEPELCore

public enum FileCacheFlushOutcome: Sendable, Equatable {
    case flushed
    /// The administrator prompt was dismissed.
    case cancelled
    case failed(String)
    case unavailable
}

/// Flushes the file cache with the system's own `purge`.
///
/// `purge` needs administrator rights. PEPEL does not keep a privileged helper or a password:
/// each flush goes through the standard macOS administrator prompt, which the user can dismiss.
/// What it does is limited and said plainly in the interface: cached file pages become free
/// pages. Memory used by applications, compressed memory and swap are not touched, and macOS
/// fills the cache again as files are read.
public struct FileCacheFlusher: Sendable {
    public var isAvailable: Bool
    public var flush: @Sendable () -> FileCacheFlushOutcome

    public init(isAvailable: Bool, flush: @escaping @Sendable () -> FileCacheFlushOutcome) {
        self.isAvailable = isAvailable
        self.flush = flush
    }

    public static let unavailable = FileCacheFlusher(isAvailable: false) { .unavailable }

    static let purgePath = "/usr/sbin/purge"

    public static func system(tools: ToolRunner) -> FileCacheFlusher {
        guard FileManager.default.isExecutableFile(atPath: purgePath), tools.locate("osascript") != nil else { return .unavailable }
        return FileCacheFlusher(isAvailable: true) {
            // A fixed command line: nothing from outside is interpolated into the script.
            let script = "do shell script \"\(purgePath)\" with prompt \"PEPEL wants to flush the file cache.\" with administrator privileges"
            guard let result = tools.run("osascript", ["-e", script], timeout: 180) else { return .failed("The administrator prompt was not answered in time.") }
            if result.status == 0 { return .flushed }
            // osascript reports a dismissed prompt as error -128; its text goes to stderr, which is not read.
            return .cancelled
        }
    }
}
