import Darwin
import Foundation
import PEPELCore

/// The memory journal on disk: one file per day, one JSON object per line, readable by the
/// user only. Plain files rather than the database so they can be read, copied and analysed
/// with anything.
public struct MemoryJournal: Sendable {
    public let directory: String

    public init(directory: String) { self.directory = directory }

    static func day(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func path(for date: Date) -> String { directory + "/" + Self.day(date) + ".jsonl" }

    private static let lock = NSLock()

    /// Appends one line. The file is opened for appending and created if missing in the same
    /// call, so two writers can never truncate each other's lines.
    @discardableResult
    public func append(_ sample: JournalSample) -> Bool {
        guard var line = try? Self.encoder().encode(sample) else { return false }
        line.append(0x0A)
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(path(for: sample.ts), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) } == line.count
    }

    /// Journal files, oldest first.
    public func files() -> [(day: String, path: String, bytes: Int64)] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasSuffix(".jsonl") && $0.count == 16 }.sorted()
            .map { name in
                let path = directory + "/" + name
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
                return (String(name.dropLast(6)), path, size)
            }
    }

    public func read(since: Date) -> [JournalSample] {
        let first = Self.day(since)
        let decoder = Self.decoder()
        var result: [JournalSample] = []
        for file in files() where file.day >= first {
            guard let text = try? String(contentsOfFile: file.path, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                // A line cut short by a crash is skipped, not fatal.
                guard let sample = try? decoder.decode(JournalSample.self, from: Data(line.utf8)), sample.ts >= since else { continue }
                result.append(sample)
            }
        }
        return result
    }

    /// Removes whole days older than the retention. Only files this journal names are touched.
    public func prune(keepDays: Int, now: Date = Date()) {
        let cutoff = Self.day(now.addingTimeInterval(-Double(keepDays) * 86_400))
        for file in files() where file.day < cutoff { try? FileManager.default.removeItem(atPath: file.path) }
    }
}
