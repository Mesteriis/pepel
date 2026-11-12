import Darwin
import Foundation
import PEPELCore

/// Reads what macOS starts on its own: launch agents and daemons from their property lists, their
/// state from `launchctl` in your session, and the memory of what they run. Only reads.
public struct StartupInventory: Sendable {
    public var home: String
    /// Folders searched, with the kind of what is in them.
    public var folders: [(path: String, kind: StartupItem.Kind)]
    /// Runs `launchctl` with the given arguments and returns its output; nil when it cannot run.
    public var launchctl: @Sendable ([String]) -> String?
    public var uid: UInt32

    public init(home: String, folders: [(String, StartupItem.Kind)]? = nil, uid: UInt32 = getuid(), launchctl: @escaping @Sendable ([String]) -> String?) {
        self.home = home
        self.folders = folders ?? [(home + "/Library/LaunchAgents", .userAgent), ("/Library/LaunchAgents", .sharedAgent), ("/Library/LaunchDaemons", .daemon)]
        self.uid = uid
        self.launchctl = launchctl
    }

    public var domain: String { "gui/\(uid)" }

    /// One row of `launchctl list`: PID ("-" when not running), last exit status, label.
    public static func parseList(_ text: String) -> [String: (pid: Int32?, status: Int32?)] {
        var jobs: [String: (Int32?, Int32?)] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            jobs[String(fields[2])] = (Int32(fields[0]), Int32(fields[1]))
        }
        return jobs
    }

    /// `launchctl print-disabled`: label → disabled.
    public static func parseDisabled(_ text: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.components(separatedBy: "\" => ")
            guard parts.count == 2, let label = parts[0].split(separator: "\"").last else { continue }
            result[String(label)] = parts[1].trimmingCharacters(in: .whitespaces).hasPrefix("disabled")
        }
        return result
    }

    /// The executable a job runs, from `launchctl print` of one job.
    public static func parseProgram(_ text: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("program = ") { return String(trimmed.dropFirst("program = ".count)) }
        }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("program identifier = ") {
                return String(trimmed.dropFirst("program identifier = ".count).split(separator: " ").first ?? "")
            }
        }
        return nil
    }

    static let systemFolders = ["/usr/bin/", "/bin/", "/usr/sbin/", "/sbin/", "/usr/libexec/", "/System/"]
    static let notPrograms: Set<String> = ["sb", "toml", "json", "yaml", "yml", "plist", "conf", "cfg", "log", "txt", "ini"]

    /// Who a job belongs to, in words a person recognises: the app it lives in ("zoom.us" for
    /// /Applications/zoom.us.app/…), the script or program a system tool runs for it (osascript,
    /// python3, open, sandbox-exec are only the means), or failing that its label without the
    /// reverse-DNS prefix ("hermes gateway" for ai.hermes.gateway).
    public static func owner(program: String?, arguments: [String] = [], label: String) -> String {
        func app(in path: String) -> String? {
            guard let range = path.range(of: ".app") else { return nil }
            let end = path[range.upperBound...]
            guard end.isEmpty || end.hasPrefix("/") else { return nil }
            return ((String(path[..<range.lowerBound]) + ".app") as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        }
        if let program, let name = app(in: program) { return name }
        let wrapper = program.map { p in systemFolders.contains { p.hasPrefix($0) } } ?? false
        if let program, program.hasPrefix("/"), !wrapper { return (program as NSString).lastPathComponent }
        // Run through a system tool: what it is given to run.
        for argument in arguments where argument.hasPrefix("/") || argument.hasPrefix("~") {
            if let name = app(in: argument) { return name }
            let ext = (argument as NSString).pathExtension.lowercased()
            if notPrograms.contains(ext) { continue }
            return (argument as NSString).lastPathComponent
        }
        let parts = label.split(separator: ".")
        let prefixes: Set<String> = ["com", "org", "net", "io", "ai", "dev", "app", "ru", "us", "local", "me", "co", "de", "uk"]
        // A developer team ID ("2BUA8C4S2C.com.1password…") and the reverse-DNS prefix say nothing to a person.
        let isTeamID: (Substring) -> Bool = { $0.count == 10 && $0.allSatisfy { $0.isUppercase || $0.isNumber } }
        let meaningful = parts.drop { isTeamID($0) || prefixes.contains($0.lowercased()) }
        return meaningful.isEmpty ? label : meaningful.joined(separator: " ")
    }

    /// The first process with this name among all users' (as `ps` reads it, no permission needed).
    /// The kernel keeps the first 16 characters of a name.
    public static func pid(named name: String, uid: UInt32 = 0) -> Int32? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        let count = size / MemoryLayout<kinfo_proc>.stride + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return nil }
        let wanted = String(name.prefix(Int(MAXCOMLEN)))
        for proc in procs.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            var comm = proc.kp_proc.p_comm
            let current = withUnsafeBytes(of: &comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if current == wanted, proc.kp_eproc.e_ucred.cr_uid == uid { return proc.kp_proc.p_pid }
        }
        return nil
    }

    public func items(processes: [ProcessSnapshot]) -> [StartupItem] {
        let jobs = launchctl(["list"]).map(Self.parseList) ?? [:]
        let disabled = launchctl(["print-disabled", domain]).map(Self.parseDisabled) ?? [:]
        var children: [Int32: [ProcessSnapshot]] = [:]
        for process in processes { children[process.parentPID, default: []].append(process) }
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        func tree(_ pid: Int32) -> (bytes: Int64, count: Int) {
            var bytes: Int64 = 0, count = 0, queue = [pid], seen = Set<Int32>()
            while let next = queue.popLast(), seen.insert(next).inserted {
                if let process = byPID[next] { bytes += process.footprintBytes; count += 1 }
                queue += (children[next] ?? []).map(\.pid)
            }
            return (bytes, count)
        }

        var items: [StartupItem] = []
        var labels = Set<String>()
        for (folder, kind) in folders {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".plist") }.sorted()
            for name in names {
                let path = folder + "/" + name
                guard let data = FileManager.default.contents(atPath: path),
                    let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                    let label = plist["Label"] as? String
                else { continue }
                let arguments = (plist["ProgramArguments"] as? [String]) ?? []
                let program = (plist["Program"] as? String) ?? arguments.first
                let keepAlive: Bool = (plist["KeepAlive"] as? Bool) ?? (plist["KeepAlive"] is [String: Any])
                var item = StartupItem(
                    label: label, kind: kind, plistPath: path, program: program, owner: Self.owner(program: program, arguments: Array(arguments.dropFirst()), label: label),
                    runAtLoad: plist["RunAtLoad"] as? Bool ?? false, keepAlive: keepAlive, interval: plist["StartInterval"] as? Int,
                    disabled: disabled[label] ?? (plist["Disabled"] as? Bool ?? false), loaded: jobs[label] != nil,
                    pid: jobs[label]?.pid ?? nil, lastExitStatus: jobs[label]?.status ?? nil)
                // A daemon is not in your session: it is running when its program is.
                // A daemon runs as root, outside the processes you can inspect: its name is what can be read.
                if kind == .daemon, let program {
                    item.pid = Self.pid(named: (program as NSString).lastPathComponent)
                }
                if let pid = item.pid { (item.footprintBytes, item.processCount) = tree(pid) }
                labels.insert(label)
                items.append(item)
            }
        }
        // Jobs in your session with no property list in those folders: helpers apps registered
        // from inside their bundles. Running apps (application.*) and macOS's own are left out.
        for (label, job) in jobs where !labels.contains(label) && !label.hasPrefix("com.apple.") && !label.hasPrefix("application.") {
            let program = launchctl(["print", domain + "/" + label]).flatMap(Self.parseProgram)
            // A system tool registered by macOS itself (ssh-agent) is part of macOS.
            if let program, Self.systemFolders.contains(where: { program.hasPrefix($0) }) { continue }
            var item = StartupItem(
                label: label, kind: .appHelper, plistPath: nil, program: program, owner: Self.owner(program: program, label: label),
                runAtLoad: true, keepAlive: false, interval: nil, disabled: disabled[label] ?? false, loaded: true, pid: job.pid, lastExitStatus: job.status)
            if let pid = item.pid { (item.footprintBytes, item.processCount) = tree(pid) }
            items.append(item)
        }
        return items.sorted { $0.footprintBytes != $1.footprintBytes ? $0.footprintBytes > $1.footprintBytes : $0.label < $1.label }
    }
}
