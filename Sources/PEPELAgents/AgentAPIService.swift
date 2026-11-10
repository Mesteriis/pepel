import Foundation
import PEPELCore
import PEPELPersistence

public struct APIError: Error, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct DisposableMark: Codable, Sendable, Hashable {
    public var owner: String
    public var path: String
    public var markedAt: Date
}

/// Operations PEPEL performs on the engine's behalf for the agent API.
public struct AgentAPIHooks: Sendable {
    public var requestScan: @Sendable () async -> Void
    /// JSON description of what a user-run cleanup would do. Nothing is removed.
    public var previewCleanup: @Sendable () async -> Data
    public var status: @Sendable () async -> Data

    public init(
        requestScan: @escaping @Sendable () async -> Void = {}, previewCleanup: @escaping @Sendable () async -> Data = { Data("{}".utf8) },
        status: @escaping @Sendable () async -> Data = { Data("{}".utf8) }
    ) {
        self.requestScan = requestScan
        self.previewCleanup = previewCleanup
        self.status = status
    }
}

/// What agents may ask of PEPEL. Deliberately narrow: agents can protect, lease, register and
/// preview. There is no operation here that deletes a file or signals a process.
public struct AgentAPIService: Sendable {
    public static let maxLeaseSeconds = 24 * 3600
    public static let operations = [
        "ping", "status", "scan.request", "cleanup.preview", "lease.acquire", "lease.renew", "lease.release", "lease.list",
        "build.register", "workspace.register", "artifact.disposable", "artifact.protect", "task.complete",
    ]

    public let store: PepelStore
    public let hooks: AgentAPIHooks
    public let home: String

    public init(store: PepelStore, hooks: AgentAPIHooks = AgentAPIHooks(), home: String = NSHomeDirectory()) {
        self.store = store
        self.hooks = hooks
        self.home = home
    }

    private func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    private func path(_ args: [String: String]) throws -> String {
        guard let raw = args["path"], !raw.isEmpty else { throw APIError("missing 'path'") }
        let canonical = PathUtil.canonical(raw, home: home)
        guard canonical.hasPrefix("/"), canonical != "/", canonical != PathUtil.canonical(home) else { throw APIError("path is too broad") }
        return canonical
    }

    private func owner(_ args: [String: String]) throws -> String {
        guard let owner = args["owner"]?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty, owner.count <= 80 else {
            throw APIError("missing 'owner'")
        }
        return owner
    }

    private func seconds(_ args: [String: String], default value: Int) -> TimeInterval {
        TimeInterval(min(Self.maxLeaseSeconds, max(60, Int(args["seconds"] ?? "") ?? value)))
    }

    private func audit(_ subject: String, _ outcome: String, owner: String) {
        store.appendAudit(AuditEntry(kind: .agent, initiator: "agent:\(owner)", subject: subject, outcome: outcome))
    }

    public func disposables() -> [DisposableMark] {
        store.loadCodable([DisposableMark].self, key: "agent.disposables") ?? []
    }

    public func handle(op: String, args: [String: String], now: Date = Date()) async throws -> Data {
        switch op {
        case "ping":
            return encode(["pong": "pepel"])
        case "status":
            return await hooks.status()
        case "scan.request":
            await hooks.requestScan()
            return encode(["requested": true])
        case "cleanup.preview":
            return await hooks.previewCleanup()

        case "lease.acquire", "workspace.register", "build.register":
            let owner = try owner(args)
            let purpose = op == "workspace.register" ? "workspace" : op == "build.register" ? "build: \(args["command"] ?? "")" : (args["purpose"] ?? "")
            let lease = ResourceLease(
                owner: owner, path: try path(args), purpose: String(purpose.prefix(200)), createdAt: now,
                expiresAt: now.addingTimeInterval(seconds(args, default: 3600)))
            try store.saveLease(lease)
            audit(lease.path, "\(op) until \(lease.expiresAt.formatted(date: .omitted, time: .shortened))", owner: owner)
            return encode(lease)

        case "lease.renew":
            guard let id = args["id"], var lease = store.leases(includeInactive: true, now: now).first(where: { $0.id == id }) else {
                throw APIError("unknown lease")
            }
            guard lease.releasedAt == nil else { throw APIError("lease was released") }
            lease.expiresAt = now.addingTimeInterval(seconds(args, default: 3600))
            try store.saveLease(lease)
            return encode(lease)

        case "lease.release":
            guard let id = args["id"] else { throw APIError("missing 'id'") }
            guard try store.releaseLease(id: id, now: now) else { throw APIError("unknown or already released lease") }
            // Releasing a lease only stops protecting the path. Whether it can be cleaned is
            // decided later by the usual usage checks.
            return encode(["released": true])

        case "lease.list":
            return encode(store.leases(now: now))

        case "task.complete":
            let owner = try owner(args)
            var released = 0
            for lease in store.leases(now: now) where lease.owner == owner {
                if try store.releaseLease(id: lease.id, now: now) { released += 1 }
            }
            audit("task complete", "released \(released) lease(s)", owner: owner)
            return encode(["released": released])

        case "artifact.protect":
            let target = try path(args)
            try store.addProtection(ProtectionRule(kind: .path, value: target, note: "Protected by agent \(args["owner"] ?? "unknown")", createdAt: now))
            audit(target, "protected", owner: args["owner"] ?? "unknown")
            return encode(["protected": target])

        case "artifact.disposable":
            let owner = try owner(args)
            let target = try path(args)
            // An agent may only mark things inside a workspace it registered itself, and the mark
            // is a hint for the user's review list, never a permission to delete.
            let workspaces = store.leases(includeInactive: true, now: now).filter { $0.owner == owner && $0.purpose == "workspace" }
            guard workspaces.contains(where: { PathUtil.isInside(target, root: $0.path) && target != $0.path || target == $0.path }) else {
                throw APIError("path is not inside a workspace registered by '\(owner)'")
            }
            var marks = disposables().filter { $0.path != target }
            marks.append(DisposableMark(owner: owner, path: target, markedAt: now))
            try store.saveCodable(Array(marks.suffix(500)), key: "agent.disposables")
            audit(target, "marked disposable (needs your review)", owner: owner)
            return encode(["marked": target, "note": "Listed for the user's review; not deleted."])

        default:
            throw APIError("unknown operation '\(op)'")
        }
    }
}
