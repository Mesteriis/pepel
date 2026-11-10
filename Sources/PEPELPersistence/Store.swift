import Foundation
import PEPELCore

/// Typed access to PEPEL's persistent state. Every multi-statement update runs in a transaction.
public final class PepelStore: Sendable {
    public let db: Database

    public init(path: String) throws {
        db = try Database(path: path)
        try migrate()
    }

    public static func inMemory() throws -> PepelStore { try PepelStore(path: ":memory:") }

    private func migrate() throws {
        let version = try db.query("PRAGMA user_version").first?.first?.int ?? 0
        if version == 1 {
            // v2: disk-write accounting per observation, used to tell a working agent from a sleeping one.
            try db.transaction {
                try db.execute("ALTER TABLE observations ADD COLUMN written INTEGER NOT NULL DEFAULT 0")
                try db.execute("PRAGMA user_version = 2")
            }
        }
        guard version < 1 else { return }
        try db.transaction {
            for sql in [
                "CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value TEXT NOT NULL)",
                """
                CREATE TABLE IF NOT EXISTS telemetry(ts REAL NOT NULL, disk_total INTEGER, disk_available INTEGER,
                  disk_free INTEGER, mem_used INTEGER, compressed INTEGER, swap_used INTEGER, pressure TEXT,
                  reclaimable INTEGER)
                """,
                "CREATE INDEX IF NOT EXISTS telemetry_ts ON telemetry(ts)",
                "CREATE TABLE IF NOT EXISTS usage(ts REAL NOT NULL, scope TEXT NOT NULL, key TEXT NOT NULL, name TEXT NOT NULL, bytes INTEGER NOT NULL)",
                "CREATE INDEX IF NOT EXISTS usage_ts ON usage(scope, ts)",
                """
                CREATE TABLE IF NOT EXISTS audit(id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, kind TEXT NOT NULL,
                  initiator TEXT NOT NULL, subject TEXT NOT NULL, outcome TEXT NOT NULL, bytes INTEGER NOT NULL, detail TEXT NOT NULL)
                """,
                "CREATE TABLE IF NOT EXISTS protections(id TEXT PRIMARY KEY, kind TEXT NOT NULL, value TEXT NOT NULL, note TEXT NOT NULL, created REAL NOT NULL)",
                """
                CREATE TABLE IF NOT EXISTS leases(id TEXT PRIMARY KEY, owner TEXT NOT NULL, path TEXT NOT NULL, purpose TEXT NOT NULL,
                  created REAL NOT NULL, expires REAL NOT NULL, released REAL)
                """,
                "CREATE TABLE IF NOT EXISTS builds(id TEXT PRIMARY KEY, started REAL NOT NULL, json TEXT NOT NULL)",
                "CREATE TABLE IF NOT EXISTS observations(pid INTEGER NOT NULL, start INTEGER NOT NULL, ts REAL NOT NULL, cpu INTEGER NOT NULL, footprint INTEGER NOT NULL, written INTEGER NOT NULL DEFAULT 0)",
                "CREATE INDEX IF NOT EXISTS observations_id ON observations(pid, start, ts)",
                "PRAGMA user_version = 2",
            ] { try db.execute(sql) }
        }
    }

    // MARK: Key-value and settings

    public func value(_ key: String) -> String? {
        (try? db.query("SELECT value FROM kv WHERE key = ?", [.text(key)]))?.first?.first?.text
    }

    public func setValue(_ value: String, for key: String) throws {
        try db.execute(
            "INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key), .text(value)])
    }

    public func loadSettings(home: String = NSHomeDirectory()) -> PepelSettings {
        guard let json = value("settings"), let data = json.data(using: .utf8) else {
            var settings = PepelSettings()
            settings.projectRoots = PepelSettings.detectDefaultRoots(home: home)
            return settings
        }
        return PepelSettings.decodeLenient(data)
    }

    public func saveSettings(_ settings: PepelSettings) throws {
        try setValue(String(decoding: try JSONEncoder().encode(settings), as: UTF8.self), for: "settings")
    }

    public func loadCodable<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let json = value(key), let data = json.data(using: .utf8) else { return nil }
        return try? Self.decoder.decode(type, from: data)
    }

    public func saveCodable<T: Encodable>(_ value: T, key: String) throws {
        try setValue(String(decoding: try Self.encoder.encode(value), as: UTF8.self), for: key)
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    // MARK: Audit log

    @discardableResult
    public func appendAudit(_ entry: AuditEntry) -> Int64 {
        let detail = (try? JSONEncoder().encode(entry.detail)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        do {
            return try db.transaction {
                try db.execute(
                    "INSERT INTO audit(ts, kind, initiator, subject, outcome, bytes, detail) VALUES(?,?,?,?,?,?,?)",
                    [
                        .double(entry.timestamp.timeIntervalSince1970), .text(entry.kind.rawValue), .text(entry.initiator),
                        .text(entry.subject), .text(entry.outcome), .int(entry.bytes), .text(detail),
                    ])
                return db.lastInsertRowID
            }
        } catch {
            return -1
        }
    }

    public func audit(limit: Int = 200, kinds: [AuditKind]? = nil) -> [AuditEntry] {
        var sql = "SELECT id, ts, kind, initiator, subject, outcome, bytes, detail FROM audit"
        var params: [SQLValue] = []
        if let kinds, !kinds.isEmpty {
            sql += " WHERE kind IN (" + kinds.map { _ in "?" }.joined(separator: ",") + ")"
            params = kinds.map { .text($0.rawValue) }
        }
        sql += " ORDER BY id DESC LIMIT ?"
        params.append(.int(Int64(limit)))
        let rows = (try? db.query(sql, params)) ?? []
        return rows.compactMap { row in
            guard let kind = AuditKind(rawValue: row[2].text ?? "") else { return nil }
            let detail = (row[7].text?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
            return AuditEntry(
                id: row[0].int, timestamp: Date(timeIntervalSince1970: row[1].double), kind: kind,
                initiator: row[3].text ?? "", subject: row[4].text ?? "", outcome: row[5].text ?? "",
                bytes: row[6].int, detail: detail ?? [:])
        }
    }

    // MARK: Protection rules

    public func protections() -> [ProtectionRule] {
        let rows = (try? db.query("SELECT id, kind, value, note, created FROM protections ORDER BY created")) ?? []
        return rows.compactMap { row in
            guard let kind = ProtectionKind(rawValue: row[1].text ?? "") else { return nil }
            return ProtectionRule(
                id: row[0].text ?? "", kind: kind, value: row[2].text ?? "", note: row[3].text ?? "",
                createdAt: Date(timeIntervalSince1970: row[4].double))
        }
    }

    public func addProtection(_ rule: ProtectionRule) throws {
        try db.transaction {
            try db.execute("DELETE FROM protections WHERE kind = ? AND value = ?", [.text(rule.kind.rawValue), .text(rule.value)])
            try db.execute(
                "INSERT INTO protections(id, kind, value, note, created) VALUES(?,?,?,?,?)",
                [.text(rule.id), .text(rule.kind.rawValue), .text(rule.value), .text(rule.note), .double(rule.createdAt.timeIntervalSince1970)])
        }
    }

    public func removeProtection(id: String) throws {
        try db.execute("DELETE FROM protections WHERE id = ?", [.text(id)])
    }

    public func removeProtection(kind: ProtectionKind, value: String) throws {
        try db.execute("DELETE FROM protections WHERE kind = ? AND value = ?", [.text(kind.rawValue), .text(value)])
    }

    // MARK: Leases

    public func leases(includeInactive: Bool = false, now: Date = Date()) -> [ResourceLease] {
        let rows = (try? db.query("SELECT id, owner, path, purpose, created, expires, released FROM leases ORDER BY created DESC LIMIT 500")) ?? []
        let all = rows.map { row in
            ResourceLease(
                id: row[0].text ?? "", owner: row[1].text ?? "", path: row[2].text ?? "", purpose: row[3].text ?? "",
                createdAt: Date(timeIntervalSince1970: row[4].double), expiresAt: Date(timeIntervalSince1970: row[5].double),
                releasedAt: row[6].isNull ? nil : Date(timeIntervalSince1970: row[6].double))
        }
        return includeInactive ? all : all.filter { $0.isActive(at: now) }
    }

    public func saveLease(_ lease: ResourceLease) throws {
        try db.execute(
            """
            INSERT INTO leases(id, owner, path, purpose, created, expires, released) VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET expires = excluded.expires, released = excluded.released, purpose = excluded.purpose
            """,
            [
                .text(lease.id), .text(lease.owner), .text(lease.path), .text(lease.purpose),
                .double(lease.createdAt.timeIntervalSince1970), .double(lease.expiresAt.timeIntervalSince1970),
                lease.releasedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            ])
    }

    /// Returns false when no such active lease exists.
    public func releaseLease(id: String, now: Date = Date()) throws -> Bool {
        try db.transaction {
            let found = try db.query("SELECT 1 FROM leases WHERE id = ? AND released IS NULL", [.text(id)])
            guard !found.isEmpty else { return false }
            try db.execute("UPDATE leases SET released = ? WHERE id = ?", [.double(now.timeIntervalSince1970), .text(id)])
            return true
        }
    }

    // MARK: Wrapper build records

    public func saveBuild(_ record: BuildRecord) throws {
        let json = String(decoding: try Self.encoder.encode(record), as: UTF8.self)
        try db.execute(
            "INSERT INTO builds(id, started, json) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET json = excluded.json",
            [.text(record.id), .double(record.startedAt.timeIntervalSince1970), .text(json)])
    }

    public func builds(limit: Int = 500) -> [BuildRecord] {
        let rows = (try? db.query("SELECT json FROM builds ORDER BY started DESC LIMIT ?", [.int(Int64(limit))])) ?? []
        return rows.compactMap { $0[0].text?.data(using: .utf8) }.compactMap { try? Self.decoder.decode(BuildRecord.self, from: $0) }
    }
}
