import Foundation
import PEPELCore

public struct TelemetryPoint: Codable, Sendable, Hashable, Identifiable {
    public var timestamp: Date
    public var diskTotal: Int64
    public var diskAvailable: Int64
    public var memoryUsed: Int64
    public var compressed: Int64
    public var swapUsed: Int64
    public var pressure: MemoryPressureLevel
    /// Reclaimable total of the most recent scan at that time, when one existed.
    public var reclaimable: Int64?

    public var id: Date { timestamp }
    public var diskUsed: Int64 { diskTotal - diskAvailable }
}

public struct UsagePoint: Codable, Sendable, Hashable {
    public var timestamp: Date
    public var key: String
    public var name: String
    public var bytes: Int64
}

/// Growth over a window. `actualSpan` is shorter than the requested window when history does not
/// reach back that far; callers show the real span instead of pretending.
public struct GrowthFigure: Codable, Sendable, Hashable {
    public var requestedWindow: TimeInterval
    public var actualSpan: TimeInterval
    public var deltaBytes: Int64

    public init(requestedWindow: TimeInterval, actualSpan: TimeInterval, deltaBytes: Int64) {
        self.requestedWindow = requestedWindow
        self.actualSpan = actualSpan
        self.deltaBytes = deltaBytes
    }

    public var coversWindow: Bool { actualSpan >= requestedWindow * 0.9 }
}

extension PepelStore {
    // MARK: Telemetry history

    public func recordTelemetry(_ t: SystemTelemetry, reclaimable: Int64?) {
        try? db.execute(
            "INSERT INTO telemetry(ts, disk_total, disk_available, disk_free, mem_used, compressed, swap_used, pressure, reclaimable) VALUES(?,?,?,?,?,?,?,?,?)",
            [
                .double(t.timestamp.timeIntervalSince1970), .int(t.diskTotalBytes), .int(t.diskAvailableBytes),
                .int(t.diskFreeBytes), .int(t.memoryUsedBytes), .int(t.compressedBytes), .int(t.swapUsedBytes),
                .text(t.pressure.rawValue), reclaimable.map { .int($0) } ?? .null,
            ])
    }

    public func telemetryHistory(since: Date, maxPoints: Int = 400) -> [TelemetryPoint] {
        let rows = (try? db.query(
            "SELECT ts, disk_total, disk_available, mem_used, compressed, swap_used, pressure, reclaimable FROM telemetry WHERE ts >= ? ORDER BY ts",
            [.double(since.timeIntervalSince1970)])) ?? []
        let points = rows.map { row in
            TelemetryPoint(
                timestamp: Date(timeIntervalSince1970: row[0].double), diskTotal: row[1].int, diskAvailable: row[2].int,
                memoryUsed: row[3].int, compressed: row[4].int, swapUsed: row[5].int,
                pressure: MemoryPressureLevel(rawValue: row[6].text ?? "") ?? .normal,
                reclaimable: row[7].isNull ? nil : row[7].int)
        }
        guard points.count > maxPoints else { return points }
        let stride = Double(points.count) / Double(maxPoints)
        return (0..<maxPoints).map { points[min(points.count - 1, Int(Double($0) * stride))] } + [points[points.count - 1]]
    }

    /// Change in used disk space over `window`, from recorded snapshots only.
    public func diskGrowth(window: TimeInterval, now: Date = Date()) -> GrowthFigure? {
        let cutoff = now.addingTimeInterval(-window).timeIntervalSince1970
        let latest = try? db.query("SELECT ts, disk_total - disk_available FROM telemetry ORDER BY ts DESC LIMIT 1")
        // Closest snapshot at or before the cutoff; otherwise the oldest one we have.
        var baseline = try? db.query(
            "SELECT ts, disk_total - disk_available FROM telemetry WHERE ts <= ? ORDER BY ts DESC LIMIT 1", [.double(cutoff)])
        if baseline?.isEmpty ?? true {
            baseline = try? db.query("SELECT ts, disk_total - disk_available FROM telemetry ORDER BY ts ASC LIMIT 1")
        }
        // A few seconds of history say nothing about growth; wait for at least five minutes.
        guard let end = latest?.first, let start = baseline?.first, end[0].double - start[0].double >= 300 else { return nil }
        return GrowthFigure(
            requestedWindow: window, actualSpan: min(window, end[0].double - start[0].double),
            deltaBytes: end[1].int - start[1].int)
    }

    /// Jumps in used disk space between consecutive snapshots taken close together.
    public func storageSpikes(since: Date, thresholdBytes: Int64 = 5 * Bytes.gb) -> [(at: Date, deltaBytes: Int64)] {
        let rows = (try? db.query(
            "SELECT ts, disk_total - disk_available FROM telemetry WHERE ts >= ? ORDER BY ts", [.double(since.timeIntervalSince1970)])) ?? []
        var spikes: [(Date, Int64)] = []
        for (previous, current) in zip(rows, rows.dropFirst()) {
            let delta = current[1].int - previous[1].int
            if delta >= thresholdBytes, current[0].double - previous[0].double <= 1800 {
                spikes.append((Date(timeIntervalSince1970: current[0].double), delta))
            }
        }
        return spikes
    }

    // MARK: Usage snapshots (per project / per category)

    public func recordUsage(scope: String, entries: [(key: String, name: String, bytes: Int64)], at timestamp: Date = Date()) {
        try? db.transaction {
            for entry in entries {
                try db.execute(
                    "INSERT INTO usage(ts, scope, key, name, bytes) VALUES(?,?,?,?,?)",
                    [.double(timestamp.timeIntervalSince1970), .text(scope), .text(entry.key), .text(entry.name), .int(entry.bytes)])
            }
        }
    }

    /// Latest recorded value per key at or before `date`.
    public func usage(scope: String, atOrBefore date: Date) -> [String: UsagePoint] {
        let rows = (try? db.query(
            """
            SELECT u.ts, u.key, u.name, u.bytes FROM usage u
            JOIN (SELECT key, MAX(ts) AS ts FROM usage WHERE scope = ? AND ts <= ? GROUP BY key) m
              ON m.key = u.key AND m.ts = u.ts
            WHERE u.scope = ?
            """, [.text(scope), .double(date.timeIntervalSince1970), .text(scope)])) ?? []
        var result: [String: UsagePoint] = [:]
        for row in rows {
            let point = UsagePoint(
                timestamp: Date(timeIntervalSince1970: row[0].double), key: row[1].text ?? "", name: row[2].text ?? "", bytes: row[3].int)
            result[point.key] = point
        }
        return result
    }

    // MARK: Process observations

    public func recordObservations(_ processes: [ProcessSnapshot], at timestamp: Date = Date()) {
        try? db.transaction {
            for p in processes {
                try db.execute(
                    "INSERT INTO observations(pid, start, ts, cpu, footprint) VALUES(?,?,?,?,?)",
                    [
                        .int(Int64(p.identity.pid)), .int(Int64(bitPattern: p.identity.startTime)),
                        .double(timestamp.timeIntervalSince1970), .int(Int64(bitPattern: p.cpuTimeNs)), .int(p.footprintBytes),
                    ])
            }
        }
    }

    public func observations(since: Date) -> [ProcessIdentity: [ProcessObservation]] {
        let rows = (try? db.query(
            "SELECT pid, start, ts, cpu, footprint FROM observations WHERE ts >= ? ORDER BY ts", [.double(since.timeIntervalSince1970)])) ?? []
        var result: [ProcessIdentity: [ProcessObservation]] = [:]
        for row in rows {
            let identity = ProcessIdentity(pid: Int32(truncatingIfNeeded: row[0].int), startTime: UInt64(bitPattern: row[1].int))
            result[identity, default: []].append(
                ProcessObservation(
                    timestamp: Date(timeIntervalSince1970: row[2].double), cpuTimeNs: UInt64(bitPattern: row[3].int),
                    footprintBytes: row[4].int))
        }
        return result
    }

    /// Drops history that is no longer needed. Called occasionally by the monitor.
    public func prune(now: Date = Date()) {
        let day: TimeInterval = 86_400
        try? db.transaction {
            try db.execute("DELETE FROM observations WHERE ts < ?", [.double(now.timeIntervalSince1970 - 2 * day)])
            try db.execute("DELETE FROM telemetry WHERE ts < ?", [.double(now.timeIntervalSince1970 - 90 * day)])
            try db.execute("DELETE FROM usage WHERE ts < ?", [.double(now.timeIntervalSince1970 - 90 * day)])
        }
    }
}
