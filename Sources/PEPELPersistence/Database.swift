import Foundation
import SQLite3

public enum SQLValue: Sendable, Equatable {
    case int(Int64)
    case double(Double)
    case text(String)
    case null

    public var int: Int64 {
        switch self {
        case .int(let v): v
        case .double(let v): Int64(v)
        default: 0
        }
    }

    public var double: Double {
        switch self {
        case .double(let v): v
        case .int(let v): Double(v)
        default: 0
        }
    }

    public var text: String? {
        if case .text(let v) = self { return v }
        return nil
    }

    public var isNull: Bool { self == .null }
}

public struct DatabaseError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public var description: String { "SQLite: \(message)" }
}

/// Thin serialized wrapper over the system SQLite. WAL mode lets the app and the CLI share one file.
public final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(handle)
            throw DatabaseError(message: message)
        }
        sqlite3_busy_timeout(handle, 5000)
        if path != ":memory:" {
            _ = try? query("PRAGMA journal_mode=WAL")
            chmod(path, 0o600)
        }
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit { sqlite3_close(handle) }

    public func execute(_ sql: String, _ params: [SQLValue] = []) throws {
        _ = try run(sql, params, collect: false)
    }

    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [[SQLValue]] {
        try run(sql, params, collect: true)
    }

    public var lastInsertRowID: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Runs `body` atomically. Nested calls join the outer transaction.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        if sqlite3_get_autocommit(handle) == 0 { return try body() }
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func run(_ sql: String, _ params: [SQLValue], collect: Bool) throws -> [[SQLValue]] {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(statement) }
        for (index, param) in params.enumerated() {
            let position = Int32(index + 1)
            switch param {
            case .int(let v): sqlite3_bind_int64(statement, position, v)
            case .double(let v): sqlite3_bind_double(statement, position, v)
            case .text(let v): sqlite3_bind_text(statement, position, v, -1, Self.transient)
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        var rows: [[SQLValue]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw lastError() }
            guard collect else { continue }
            let count = sqlite3_column_count(statement)
            var row: [SQLValue] = []
            row.reserveCapacity(Int(count))
            for column in 0..<count {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: row.append(.double(sqlite3_column_double(statement, column)))
                case SQLITE_NULL: row.append(.null)
                default:
                    row.append(sqlite3_column_text(statement, column).map { .text(String(cString: $0)) } ?? .null)
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func lastError() -> DatabaseError {
        DatabaseError(message: String(cString: sqlite3_errmsg(handle)))
    }
}
