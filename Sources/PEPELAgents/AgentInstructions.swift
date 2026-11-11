import Foundation
import PEPELCore

/// Adds a short, clearly delimited note about PEPEL to each agent's global instruction file, so
/// agents know that containers may be stopped or restarted and what to do about it.
///
/// This only ever happens when the user asks for it. The note sits between two markers, is
/// replaced in place on update, and can be removed again without touching anything else in the
/// file. The original file is copied to PEPEL's support directory before the first change.
public enum AgentInstructions {
    public static let begin = "<!-- PEPEL:BEGIN — managed by PEPEL, change it with `pepel agents instructions` -->"
    public static let end = "<!-- PEPEL:END -->"

    public struct Target: Sendable, Equatable {
        public var agent: AgentKind
        public var path: String
        /// Create the file when the agent's directory exists but the file does not.
        public var createIfMissing: Bool
    }

    public enum Outcome: Sendable, Equatable {
        case installed, updated, unchanged, removed, absent
        case skipped(String)
    }

    /// Where each agent reads its global instructions.
    public static func targets(home: String) -> [Target] {
        [
            Target(agent: .claudeCode, path: home + "/.claude/CLAUDE.md", createIfMissing: true),
            Target(agent: .codex, path: home + "/.codex/AGENTS.md", createIfMissing: true),
            Target(agent: .openCode, path: home + "/.config/opencode/AGENTS.md", createIfMissing: true),
            // Hermes keeps its standing instructions in SOUL.md; it is only extended, never created.
            Target(agent: .hermes, path: home + "/.hermes/SOUL.md", createIfMissing: false),
        ]
    }

    public static func block(settings: PepelSettings, cli: String = "pepel") -> String {
        """
        \(begin)
        ## PEPEL resource guardian

        This Mac runs PEPEL. It gives back memory and disk that development is no longer using. What that means for you:

        - **Containers can stop.** The containers of a compose project are stopped (never removed) once no agent session has been running in that project for \(settings.projectIdleGraceMinutes) minutes. The Docker VM may also be restarted to return memory, after which the same containers are started again.
        - **If a container you need is not running, start it and carry on** (`docker compose start`, or `docker compose up -d`). Data in volumes is kept. This is expected behaviour, not a failure, and not something to investigate.
        - **For unattended work that must outlive your session**, take a lease on the project directory: `\(cli) agent lease.acquire owner=<your name> path=<project dir> seconds=<up to 86400>`. Release it when done: `\(cli) agent task.complete owner=<your name>`.
        - **Do not protect containers yourself.** Do not add the `pepel.keep` label and do not change PEPEL's settings. Which services stay up permanently is the user's decision.
        - **Sessions can end.** A session with no activity for \(settings.agentSleepMinutes) minutes is terminated and can be resumed later. Do not rely on a background process surviving your session.
        - `\(cli) status`, `\(cli) containers` and `\(cli) agents` show the current state.
        \(end)
        """
    }

    /// The file's text with the block installed or replaced.
    public static func applying(_ block: String, to text: String) -> String {
        let stripped = removing(from: text)
        let body = stripped.trimmingCharacters(in: .newlines)
        return body.isEmpty ? block + "\n" : body + "\n\n" + block + "\n"
    }

    /// The file's text without the block; everything else is left as it was.
    public static func removing(from text: String) -> String {
        guard let start = text.range(of: begin), let finish = text.range(of: end, range: start.upperBound..<text.endIndex) else { return text }
        var before = String(text[..<start.lowerBound])
        var after = String(text[finish.upperBound...])
        while before.hasSuffix("\n\n") { before.removeLast() }
        while after.hasPrefix("\n") { after.removeFirst() }
        if before.isEmpty { return after }
        return after.isEmpty ? before : before + "\n" + after
    }

    public static func isInstalled(in text: String) -> Bool { text.contains(begin) && text.contains(end) }

    static func backup(_ path: String, into directory: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = path.replacingOccurrences(of: "/", with: "_")
        let copy = directory + "/" + name
        // Only the first, untouched version is worth keeping.
        if !FileManager.default.fileExists(atPath: copy) { try? FileManager.default.copyItem(atPath: path, toPath: copy) }
    }

    public static func install(home: String, settings: PepelSettings, backupDirectory: String, cli: String = "pepel") -> [(Target, Outcome)] {
        let text = block(settings: settings, cli: cli)
        return targets(home: home).map { target in
            let directory = (target.path as NSString).deletingLastPathComponent
            guard PathUtil.isDirectory(PathUtil.canonical(directory)) else { return (target, .skipped("\(target.agent.displayName) is not installed.")) }
            let existing = try? String(contentsOfFile: target.path, encoding: .utf8)
            if existing == nil, !target.createIfMissing { return (target, .skipped("No instruction file to extend.")) }
            let updated = applying(text, to: existing ?? "")
            if updated == existing { return (target, .unchanged) }
            backup(target.path, into: backupDirectory)
            do {
                try updated.write(toFile: PathUtil.canonical(target.path), atomically: true, encoding: .utf8)
                return (target, existing.map(isInstalled) == true ? .updated : .installed)
            } catch {
                return (target, .skipped("Could not write: \(error.localizedDescription)"))
            }
        }
    }

    public static func remove(home: String) -> [(Target, Outcome)] {
        targets(home: home).map { target in
            guard let existing = try? String(contentsOfFile: target.path, encoding: .utf8), isInstalled(in: existing) else { return (target, .absent) }
            do {
                try removing(from: existing).write(toFile: PathUtil.canonical(target.path), atomically: true, encoding: .utf8)
                return (target, .removed)
            } catch {
                return (target, .skipped("Could not write: \(error.localizedDescription)"))
            }
        }
    }

    public static func status(home: String) -> [(Target, Bool)] {
        targets(home: home).map { ($0, (try? String(contentsOfFile: $0.path, encoding: .utf8)).map(isInstalled) ?? false) }
    }
}
