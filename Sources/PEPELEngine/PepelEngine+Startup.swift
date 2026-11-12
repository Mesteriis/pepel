import Foundation
import PEPELCore
import PEPELProcesses

/// What macOS starts on its own, what it costs, and switching agents off and on again.
extension PepelEngine {
    static let startupSeenKey = "startup.seen"

    nonisolated func startupInventory() -> StartupInventory {
        if let startupOverride { return startupOverride }
        let tools = tools
        return StartupInventory(home: paths.home) { arguments in
            guard let result = tools.run("launchctl", arguments, timeout: 5), result.status == 0 else { return nil }
            return result.output
        }
    }

    /// Every launch agent, daemon and login helper, with its state and the memory of what it runs,
    /// and when PEPEL first saw it.
    public func startupItems() async -> [StartupItem] {
        let inventory = startupInventory(), processes = processSource.snapshot()
        var items = await Task.detached(priority: .utility) { inventory.items(processes: processes) }.value
        let seen = store.loadCodable([String: Date].self, key: Self.startupSeenKey) ?? [:]
        for index in items.indices { items[index].firstSeen = seen[items[index].id].flatMap { $0 == .distantPast ? nil : $0 } }
        return items
    }

    /// Records what is new since the last look (at most hourly) and writes it to the audit log,
    /// from which the notification is made. The first look only learns what is there.
    func watchStartupItems(now: Date = Date()) {
        let last = store.value("startup.lastWatch").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
        guard now.timeIntervalSince(last) >= 3600 else { return }
        try? store.setValue(String(now.timeIntervalSince1970), for: "startup.lastWatch")
        let items = startupInventory().items(processes: processSource.snapshot())
        var seen = store.loadCodable([String: Date].self, key: Self.startupSeenKey)
        let first = seen == nil
        var known = seen ?? [:]
        for item in items where known[item.id] == nil {
            // What was there before PEPEL first looked is not new.
            known[item.id] = first ? .distantPast : now
            guard !first else { continue }
            store.appendAudit(
                AuditEntry(
                    kind: .startup, initiator: Initiator.automatic.rawValue, subject: item.label, outcome: "appeared",
                    detail: ["kind": item.kind.rawValue, "owner": item.owner, "program": item.program ?? "", "plist": item.plistPath ?? ""]))
        }
        seen = known
        try? store.saveCodable(seen, key: Self.startupSeenKey)
    }

    /// Switches a launch agent off (it stops now and does not start again) or on (it is loaded
    /// and starts as its property list says). Never automatic, never for an agent of the API;
    /// a person confirms. The property list stays where it is.
    public func setStartupItem(_ label: String, enabled: Bool, confirmed: Bool, initiator: Initiator) async -> String? {
        switch initiator {
        case .agent: return L("Agents cannot change what starts at login.")
        case .automatic: return L("PEPEL never changes what starts at login on its own.")
        case .user, .cli: if !confirmed { return L("This needs your confirmation.") }
        }
        // Decided on a fresh reading, not on what was shown.
        let items = await startupItems()
        guard let item = items.first(where: { $0.label == label && ($0.kind == .userAgent || $0.kind == .sharedAgent) }) ?? items.first(where: { $0.label == label }) else {
            return L("No startup item is called \(label).")
        }
        if let refusal = item.managementRefusal { return refusal }
        let inventory = startupInventory(), target = inventory.domain + "/" + label
        if enabled {
            guard inventory.launchctl(["enable", target]) != nil else { return L("launchctl did not accept the change.") }
            // Already loaded is fine; otherwise load it now from its property list.
            if !item.loaded, let plist = item.plistPath { _ = inventory.launchctl(["bootstrap", inventory.domain, plist]) }
        } else {
            guard inventory.launchctl(["disable", target]) != nil else { return L("launchctl did not accept the change.") }
            if item.loaded { _ = inventory.launchctl(["bootout", target]) }
        }
        store.appendAudit(
            AuditEntry(
                kind: .startup, initiator: initiator.rawValue, subject: label, outcome: enabled ? "enabled" : "disabled", bytes: enabled ? 0 : item.footprintBytes,
                detail: ["kind": item.kind.rawValue, "owner": item.owner, "plist": item.plistPath ?? "", "wasRunning": item.isRunning ? "yes" : "no"]))
        return nil
    }
}
