import Darwin
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
/// `purge` needs administrator rights. The first flush goes through the standard macOS
/// administrator prompt and, with the same approval, installs one sudo rule that lets this user
/// run exactly `/usr/sbin/purge` with no arguments without a password. Later flushes use that
/// rule. PEPEL keeps no password and no privileged helper, and the rule can be removed again.
///
/// What a flush does is limited and said plainly in the interface: cached file pages become
/// free pages. Memory used by applications, compressed memory and swap are not touched, and
/// macOS fills the cache again as files are read.
public struct FileCacheFlusher: Sendable {
    public var isAvailable: Bool
    /// Whether the standing permission is installed, so a flush will not prompt.
    public var hasPermission: @Sendable () -> Bool
    public var flush: @Sendable () -> FileCacheFlushOutcome
    /// Removes the standing permission; asks for an administrator once more.
    public var revoke: @Sendable () -> FileCacheFlushOutcome

    public init(
        isAvailable: Bool, hasPermission: @escaping @Sendable () -> Bool = { false }, flush: @escaping @Sendable () -> FileCacheFlushOutcome,
        revoke: @escaping @Sendable () -> FileCacheFlushOutcome = { .unavailable }
    ) {
        self.isAvailable = isAvailable
        self.hasPermission = hasPermission
        self.flush = flush
        self.revoke = revoke
    }

    public static let unavailable = FileCacheFlusher(isAvailable: false) { .unavailable }

    static let purgePath = "/usr/sbin/purge"
    public static let rulePath = "/private/etc/sudoers.d/pepel-purge"

    /// The one line PEPEL adds to sudo's configuration. The user is given by number so no name
    /// is interpolated; `""` means "with no arguments"; `purge` lives on the sealed system volume
    /// and cannot be replaced.
    public static func rule(uid: UInt32) -> String { "#\(uid) ALL=(root) NOPASSWD: \(purgePath) \"\"" }

    /// Shell run once as administrator: check the rule with `visudo`, install it root-owned and
    /// read-only, then flush. A rule that fails the check is not installed; the flush still runs.
    public static func grantScript(uid: UInt32) -> String {
        "f=$(/usr/bin/mktemp /tmp/pepel-sudoers.XXXXXX) && /usr/bin/printf '%s\\n' '\(rule(uid: uid))' > \"$f\" && /usr/sbin/visudo -cf \"$f\" >/dev/null"
            + " && /usr/bin/install -m 0440 -o root -g wheel \"$f\" \(rulePath); /bin/rm -f \"$f\"; \(purgePath)"
    }

    public static func appleScript(shell: String, prompt: String) -> String {
        func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        return "do shell script \(quoted(shell)) with prompt \(quoted(prompt)) with administrator privileges"
    }

    public static func system(tools: ToolRunner, uid: UInt32 = getuid()) -> FileCacheFlusher {
        guard FileManager.default.isExecutableFile(atPath: purgePath), tools.locate("osascript") != nil else { return .unavailable }
        let installed: @Sendable () -> Bool = { FileManager.default.fileExists(atPath: rulePath) }
        @Sendable func asAdministrator(_ shell: String, prompt: String) -> FileCacheFlushOutcome {
            guard let result = tools.run("osascript", ["-e", appleScript(shell: shell, prompt: prompt)], timeout: 180) else {
                return .failed("The administrator prompt was not answered in time.")
            }
            // osascript reports a dismissed prompt as error -128; its text goes to stderr, which is not read.
            return result.status == 0 ? .flushed : .cancelled
        }
        return FileCacheFlusher(
            isAvailable: true, hasPermission: installed,
            flush: {
                // -n: never ask on a terminal. Without the rule this fails at once and falls through.
                if installed(), let result = tools.run("sudo", ["-n", purgePath], timeout: 60), result.status == 0 { return .flushed }
                return asAdministrator(
                    grantScript(uid: uid), prompt: "PEPEL wants to flush the file cache, and to be allowed to do so without asking again.")
            },
            revoke: {
                guard installed() else { return .flushed }
                return asAdministrator("/bin/rm -f \(rulePath)", prompt: "PEPEL wants to remove its permission to flush the file cache without asking.")
            })
    }
}
