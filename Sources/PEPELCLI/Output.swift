import Foundation
import PEPELEngine

struct Arguments {
    var command: String
    var positional: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]
    /// Everything after `--`, untouched.
    var passthrough: [String] = []

    init(_ raw: [String]) {
        var rest = raw
        command = rest.isEmpty ? "help" : rest.removeFirst()
        if let separator = rest.firstIndex(of: "--") {
            passthrough = Array(rest[(separator + 1)...])
            rest = Array(rest[..<separator])
        }
        var index = 0
        while index < rest.count {
            let arg = rest[index]
            if arg.hasPrefix("--") {
                let name = String(arg.dropFirst(2))
                if let eq = name.firstIndex(of: "=") {
                    options[String(name[..<eq])] = String(name[name.index(after: eq)...])
                } else if ["limit", "note", "kind"].contains(name), index + 1 < rest.count {
                    options[name] = rest[index + 1]
                    index += 1
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(arg)
            }
            index += 1
        }
    }

    var json: Bool { flags.contains("json") }
}

enum Out {
    static func json<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(value) { print(String(decoding: data, as: UTF8.self)) }
    }

    static func error(_ message: String) {
        FileHandle.standardError.write(Data(("pepel: " + message + "\n").utf8))
    }

    /// Left-aligned text table; the last column is not padded.
    static func table(_ headers: [String], _ rows: [[String]]) {
        guard !rows.isEmpty else { return }
        var widths = headers.map(\.count)
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count { widths[index] = max(widths[index], cell.count) }
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { index, cell in
                index == cells.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
        print(line(headers))
        print(line(widths.map { String(repeating: "─", count: $0) }))
        for row in rows { print(line(row)) }
    }

    static func truncate(_ text: String, _ length: Int) -> String {
        text.count <= length ? text : String(text.prefix(length - 1)) + "…"
    }

    static func confirm(_ question: String) -> Bool {
        guard isatty(STDIN_FILENO) != 0 else { return false }
        print(question + " [y/N] ", terminator: "")
        return (readLine() ?? "").lowercased().hasPrefix("y")
    }

    static let help = """
        PEPEL — developer resource guardian

        USAGE
          pepel status                     Disk, memory, builds and reclaimable storage at a glance
          pepel scan                       Scan developer storage now (nothing is removed)
          pepel projects                   Discovered projects and their artifact usage
          pepel builds                     Build generations, retention verdicts and budgets
          pepel free [--all] [--no-cache]  Free memory: show what would be stopped and flushed, then do it (--yes) and measure
          pepel free permission [--revoke] Whether PEPEL may flush the file cache without asking; remove that permission
          pepel memory growth              Applications, sessions and tools whose memory keeps growing
          pepel apps [restart|quit <name>] Applications by memory; ask one to quit, or to quit and open again
          pepel memory                     Memory pressure, swap and the largest consumers
          pepel processes [--all]          Developer processes and whether they look abandoned
          pepel agents                     Agent sessions: working, idle or asleep, and why
          pepel freeze <pid>               Suspend an agent session without ending it; nothing is lost
          pepel thaw [<pid>|--all]         List suspended sessions, or wake one or all
          pepel leftovers                  Processes still running after their application quit
          pepel containers [--all]         Memory inside the container VM, by compose project
          pepel containers stop <project>  Stop (not remove) the containers of one compose project
          pepel containers keep <name>     Leave a container or compose project running (unkeep to undo)
          pepel containers limit [<GiB>]   Show or lower the Docker VM's memory limit (restarts Docker Desktop)
          pepel containers refresh-vm      Restart the Docker VM to return its memory, then start the same containers
          pepel agents instructions        Show, --install or --remove PEPEL's note in agents' global instructions
          pepel cleanup [--dry-run]        Preview what cleanup would do (default)
          pepel cleanup --safe [--yes]     Remove items classified safe
          pepel cleanup --review           Decide interactively on items that need review
          pepel terminate <pid> [--force]  Safely terminate a developer process (asks first)
          pepel protect <path>             Never clean this path  (--kind path|project|processName|command|port)
          pepel unprotect <path>           Remove a protection
          pepel pin <path> | unpin <path>  Keep a build generation regardless of retention
          pepel protections                List protection rules
          pepel history [--limit N]        Cleanup and termination audit log, storage growth
          pepel run [--enforce-budget] -- <build command>
                                           Run a build under PEPEL so its lifetime and outcome are known
          pepel agent <op> [key=value …]   Agent API: lease.acquire, lease.release, workspace.register, …
          pepel roots [add|remove <path>]  Show or change project roots
          pepel config [set <key> <json>]  Show or change settings (e.g. set monitoringMode '"manual"')
          pepel analyzers                  List storage analyzers

        Add --json to any read command for machine-readable output.
        Cleanup never bypasses the policy engine; there is no command that deletes an arbitrary path.
        """
}
