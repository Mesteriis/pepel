import Foundation
import PEPELCore

/// A notification about something PEPEL did on its own: what it closed or removed, and what that freed.
public struct ActionNotice: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case closure, cleanup, freeze, startup }
    public var id: String
    public var kind: Kind
    public var title: String
    public var body: String
}

/// Turns what the automatic rules recorded in the audit log into notifications a person can read
/// at a glance. The audit log is the one place every rule already writes to, so nothing a rule
/// does on its own goes unsaid, and nothing is said that did not happen.
extension PepelEngine {
    static let noticeCursorKey = "notices.lastAuditID"

    /// Notifications for automatic actions recorded after the last call. The first call only
    /// remembers where the log is, so old actions are not announced again.
    public func actionNotices() -> [ActionNotice] {
        let entries = store.audit(limit: 400)
        // An empty log is a position too: the first action after it must not be missed.
        let newest = entries.first?.id ?? 0
        guard let cursor = store.value(Self.noticeCursorKey).flatMap(Int64.init) else {
            try? store.setValue(String(newest), for: Self.noticeCursorKey)
            return []
        }
        try? store.setValue(String(max(cursor, newest)), for: Self.noticeCursorKey)
        let fresh = entries.filter { $0.id > cursor && $0.initiator == Initiator.automatic.rawValue }.reversed()
        return Self.notices(for: Array(fresh))
    }

    static func notices(for entries: [AuditEntry]) -> [ActionNotice] {
        var notices: [ActionNotice] = []
        var cleanups: [(rule: String, bytes: Int64, trashed: Bool)] = []
        var frozen: [AuditEntry] = []
        for entry in entries {
            switch (entry.kind, entry.outcome) {
            case (.termination, "quit (no window)"):
                let minutes = Int(entry.detail["minutes"] ?? "") ?? 0
                notices.append(ActionNotice(
                    id: "closed-\(entry.id)", kind: .closure, title: L("\(entry.subject) closed"),
                    body: entry.bytes > 0
                        ? L("No window was open for \(minutes) min. \(Bytes.format(entry.bytes)) of memory is free again.")
                        : L("No window was open for \(minutes) min.")))
            case (.termination, "terminated"):
                let freed = entry.detail["observedChange"].map { $0.hasPrefix("-") ? String($0.dropFirst()) : $0 }
                let held = entry.detail["footprintBefore"] ?? Bytes.format(entry.bytes)
                notices.append(ActionNotice(
                    id: "ended-\(entry.id)", kind: .closure, title: L("Ended \(entry.subject)"),
                    body: freed.map { L("It sat idle past its limit. It held \(held); memory in use dropped by \($0).") } ?? L("It sat idle past its limit. It held \(held).")))
            case (.termination, "suspended"):
                frozen.append(entry)
            case (.container, let outcome) where outcome.hasPrefix("stopped") || outcome.hasPrefix("paused"):
                let project = entry.detail["project"].map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? entry.subject
                let memory = entry.detail["memoryInsideVM"]
                let stopped = outcome.hasPrefix("stopped")
                notices.append(ActionNotice(
                    id: "containers-\(entry.id)", kind: .closure,
                    title: stopped ? L("Stopped the containers of \(project)") : L("Paused the containers of \(project)"),
                    body: memory.map { L("No agent worked in the project for a while. \($0) inside Docker's VM is free again; they start again with docker compose start.") }
                        ?? L("No agent worked in the project for a while; they start again with docker compose start.")))
            case (.container, let outcome) where outcome.hasPrefix("restarted") && entry.subject == "Docker Desktop VM":
                notices.append(ActionNotice(id: "vm-\(entry.id)", kind: .closure, title: L("Restarted Docker's VM"), body: L("Its memory is handed back to the Mac; the containers that ran were started again.")))
            case (.startup, "appeared"):
                let kind = entry.detail["kind"].flatMap(StartupItem.Kind.init(rawValue:))
                let owner = entry.detail["owner"] ?? entry.subject
                notices.append(ActionNotice(
                    id: "startup-\(entry.id)", kind: .startup, title: L("New in startup: \(owner)"),
                    body: L("\(entry.subject) (\(kind?.title ?? "")) will start on its own. Startup in PEPEL shows what it runs and can switch it off.")))
            case (.cleanup, "removed"), (.cleanup, "trashed"):
                if let rule = ruleTitle(entry.subject) { cleanups.append((rule, entry.bytes, entry.outcome == "trashed")) }
            default:
                continue
            }
        }
        if !cleanups.isEmpty {
            var byRule: [String: (bytes: Int64, trashed: Bool)] = [:]
            var order: [String] = []
            for item in cleanups {
                if byRule[item.rule] == nil { order.append(item.rule) }
                byRule[item.rule] = ((byRule[item.rule]?.bytes ?? 0) + item.bytes, (byRule[item.rule]?.trashed ?? false) || item.trashed)
            }
            let total = cleanups.reduce(Int64(0)) { $0 + $1.bytes }
            let lines = order.map { rule in
                let entry = byRule[rule]!
                return entry.trashed ? L("\(rule): \(Bytes.format(entry.bytes)) to the Trash") : L("\(rule): \(Bytes.format(entry.bytes))")
            }
            let undo = cleanups.contains { $0.trashed } ? " " + L("What went to the Trash can be put back from the Overview.") : ""
            notices.append(ActionNotice(
                id: "cleanup-\(entries.last?.id ?? 0)", kind: .cleanup, title: L("Freed \(Bytes.format(total)) on disk"),
                body: lines.joined(separator: "; ") + "." + undo))
        }
        if !frozen.isEmpty {
            let names = frozen.map { $0.subject.replacingOccurrences(of: #" \(PID \d+\)"#, with: "", options: .regularExpression) }
            notices.append(ActionNotice(
                id: "frozen-\(frozen.last!.id)", kind: .freeze, title: L("Paused \(frozen.count) idle agent sessions"),
                body: L("\(names.joined(separator: ", ")). They wake up when you return to their app.")))
        }
        return notices
    }

    /// The rule behind a cleanup record, from the record's own English subject.
    static func ruleTitle(_ subject: String) -> String? {
        let rules: [(String, RuleAction.Rule)] = [
            ("Docker:", .docker), ("Tool caches:", .toolCaches), ("Application caches:", .appCaches), ("Old logs:", .logs),
            ("Temporary folder:", .temp), ("Android emulator", .emulators), ("Android system image", .systemImages),
            ("Clausona backups:", .toolBackups),
        ]
        if let match = rules.first(where: { subject.hasPrefix($0.0) }) { return match.1.title }
        if subject.hasPrefix("Downloads and screenshots:") { return L("Downloads and screenshots") }
        // Cleanup items (projects left untouched, safe automatic cleanup) are recorded one by one under their own titles.
        return L("Project build output and caches")
    }
}
