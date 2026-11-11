import Foundation
import PEPELCore

/// Reads what Docker keeps on disk and removes what a plan names. Everything goes through the
/// `docker` command line; the disk image is only ever measured, never opened.
public struct DockerDisk: Sendable {
    public typealias Runner = @Sendable (_ arguments: [String], _ timeout: TimeInterval) -> (status: Int32, output: String)?

    let run: Runner
    /// Docker Desktop's disk image, for measuring what the Mac actually gets back.
    let diskImagePath: String?

    public init(tools: ToolRunner, home: String) {
        run = { arguments, timeout in tools.run("docker", arguments, timeout: timeout) }
        let path = home + "/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
        diskImagePath = FileManager.default.fileExists(atPath: path) ? path : nil
    }

    public init(diskImagePath: String? = nil, run: @escaping Runner) {
        self.run = run
        self.diskImagePath = diskImagePath
    }

    // MARK: Parsing

    /// "1.2GB", "512MB", "0B", "3.4kB" → bytes (Docker prints decimal units here).
    static func size(_ text: String?) -> Int64 {
        guard let text else { return 0 }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let number = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number) else { return 0 }
        switch trimmed.dropFirst(number.count).trimmingCharacters(in: .whitespaces).lowercased() {
        case "kb": return Int64((value * 1e3).rounded())
        case "mb": return Int64((value * 1e6).rounded())
        case "gb": return Int64((value * 1e9).rounded())
        case "tb": return Int64((value * 1e12).rounded())
        default: return Int64(value.rounded())
        }
    }

    /// Docker prints three date shapes: "2026-11-11 08:59:20 +0100 CET", the same with a
    /// fraction, and RFC 3339 with nanoseconds. The zero date means "never".
    static func date(_ text: String?) -> Date? {
        guard var text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty, !text.hasPrefix("0001-01-01") else { return nil }
        // RFC 3339 has its "T" in the eleventh place; "UTC" and "CET" at the end do not count.
        if text.count > 10, text[text.index(text.startIndex, offsetBy: 10)] == "T" {
            if let dot = text.firstIndex(of: ".") {
                let rest = text[dot...].dropFirst().drop { $0.isNumber }
                text = String(text[..<dot]) + rest
            }
            return ISO8601DateFormatter().date(from: text)
        }
        let parts = text.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        let time = parts[1].split(separator: ".").first.map(String.init) ?? String(parts[1])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: "\(parts[0]) \(time) \(parts[2])")
    }

    static func labels(_ text: String?) -> [String: String] {
        var result: [String: String] = [:]
        for pair in (text ?? "").split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if let key = parts.first { result[String(key)] = parts.count > 1 ? String(parts[1]) : "" }
        }
        return result
    }

    func diskImageBytes() -> Int64 {
        guard let diskImagePath else { return 0 }
        var info = stat()
        return stat(diskImagePath, &info) == 0 ? Int64(info.st_blocks) * 512 : 0
    }

    // MARK: Reading

    public func report() -> DockerDiskReport? {
        guard let result = run(["system", "df", "-v", "--format", "{{json .}}"], 90), result.status == 0,
            let root = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) as? [String: Any]
        else { return nil }
        func rows(_ key: String) -> [[String: Any]] { root[key] as? [[String: Any]] ?? [] }
        func text(_ row: [String: Any], _ key: String) -> String? { row[key] as? String }

        // When each stopped container stopped: one `inspect` for all of them.
        var finished: [String: Date] = [:]
        let containerRows = rows("Containers")
        let ids = containerRows.compactMap { text($0, "ID") }
        if !ids.isEmpty, let inspected = run(["inspect", "--format", "{{.Id}}\t{{.State.FinishedAt}}"] + ids, 60) {
            for line in inspected.output.split(separator: "\n") {
                let parts = line.components(separatedBy: "\t")
                if parts.count == 2, let date = Self.date(parts[1]) { finished[parts[0]] = date }
            }
        }
        let containers = containerRows.compactMap { row -> DockerDiskReport.Container? in
            guard let id = text(row, "ID") else { return nil }
            let labels = Self.labels(text(row, "Labels"))
            return DockerDiskReport.Container(
                id: id, name: text(row, "Names") ?? String(id.prefix(12)), imageID: text(row, "Image") ?? "", state: text(row, "State") ?? "",
                createdAt: Self.date(text(row, "CreatedAt")), finishedAt: finished[id], sizeBytes: Self.size(text(row, "Size")?.components(separatedBy: " ").first),
                composeProject: labels["com.docker.compose.project"], keepLabel: ["true", "1", "yes"].contains((labels["pepel.keep"] ?? "").lowercased()))
        }

        var arrived: [String: Date] = [:]
        let imageRows = rows("Images")
        let imageIDs = imageRows.compactMap { text($0, "ID") }
        if !imageIDs.isEmpty, let inspected = run(["image", "inspect", "--format", "{{.Id}}\t{{.Metadata.LastTagTime}}"] + imageIDs, 60) {
            for line in inspected.output.split(separator: "\n") {
                let parts = line.components(separatedBy: "\t")
                if parts.count == 2, let date = Self.date(parts[1]) { arrived[parts[0]] = date }
            }
        }
        let images = imageRows.compactMap { row -> DockerDiskReport.Image? in
            guard let id = text(row, "ID") else { return nil }
            let repository = text(row, "Repository") ?? "<none>", tag = text(row, "Tag") ?? "<none>"
            let dangling = repository == "<none>"
            return DockerDiskReport.Image(
                id: id, name: dangling ? "untagged \(id.replacingOccurrences(of: "sha256:", with: "").prefix(12))" : "\(repository):\(tag)",
                createdAt: Self.date(text(row, "CreatedAt")), arrivedAt: arrived[id], sizeBytes: Self.size(text(row, "Size")),
                uniqueBytes: Self.size(text(row, "UniqueSize")), isDangling: dangling)
        }

        var created: [String: Date] = [:]
        let volumeRows = rows("Volumes")
        let names = volumeRows.compactMap { text($0, "Name") }
        if !names.isEmpty, let inspected = run(["volume", "inspect", "--format", "{{.Name}}\t{{.CreatedAt}}"] + names, 60) {
            for line in inspected.output.split(separator: "\n") {
                let parts = line.components(separatedBy: "\t")
                if parts.count == 2, let date = Self.date(parts[1]) { created[parts[0]] = date }
            }
        }
        let volumes = volumeRows.compactMap { row -> DockerDiskReport.Volume? in
            guard let name = text(row, "Name") else { return nil }
            let labels = Self.labels(text(row, "Labels"))
            return DockerDiskReport.Volume(
                name: name, sizeBytes: Self.size(text(row, "Size")), links: Int(text(row, "Links") ?? "") ?? 0, createdAt: created[name],
                composeProject: labels["com.docker.compose.project"], isAnonymous: labels["com.docker.volume.anonymous"] != nil)
        }
        let cache = rows("BuildCache").map { row in
            DockerDiskReport.CacheEntry(sizeBytes: Self.size(text(row, "Size")), lastUsedAt: Self.date(text(row, "LastUsedAt")), inUse: text(row, "InUse") == "true")
        }
        return DockerDiskReport(containers: containers, images: images, volumes: volumes, buildCache: cache, diskImageBytes: diskImageBytes())
    }

    /// Docker's own total across images, containers, volumes and build cache.
    func totalBytes() -> Int64 {
        guard let result = run(["system", "df", "--format", "{{.Size}}"], 30), result.status == 0 else { return 0 }
        return result.output.split(separator: "\n").reduce(0) { $0 + Self.size(String($1)) }
    }

    // MARK: Removing

    /// Removes exactly what the plan names, by identifier, and never with force: a container
    /// that started again or an image that found a user in the meantime is refused by Docker.
    public func clean(_ plan: DockerCleanupPlan, kinds: Set<DockerCleanKind>, compact: Bool) -> DockerCleanupReport {
        var report = DockerCleanupReport(
            steps: [], dockerBytesBefore: totalBytes(), dockerBytesAfter: 0, diskImageBefore: diskImageBytes(), diskImageAfter: 0, compacted: false, compactNote: "")
        if kinds.contains(.containers), !plan.containers.isEmpty {
            var removed = 0
            var notes: [String] = []
            for chunk in stride(from: 0, to: plan.containers.count, by: 40).map({ Array(plan.containers[$0..<min($0 + 40, plan.containers.count)]) }) {
                let result = run(["rm"] + chunk.map(\.id), 300)
                let printed = Set((result?.output ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
                removed += chunk.filter { printed.contains($0.id) }.count
                notes += chunk.filter { !printed.contains($0.id) }.map { "\($0.name) was not removed (it may have started again)." }
            }
            report.steps.append(.init(kind: .containers, removed: removed, attempted: plan.containers.count, notes: notes))
        }
        if kinds.contains(.images), !plan.images.isEmpty {
            var removed = 0
            var refused = 0
            for image in plan.images {
                if run(["rmi", image.id], 120)?.status == 0 { removed += 1 } else { refused += 1 }
            }
            report.steps.append(.init(kind: .images, removed: removed, attempted: plan.images.count, notes: refused > 0 ? ["Docker refused \(refused): still referenced by a container or another image."] : []))
        }
        if kinds.contains(.buildCache), plan.buildCacheEntries > 0 {
            // `until` here means "not used since"; Docker takes hours.
            let result = run(["builder", "prune", "--force", "--filter", "until=\(max(0, plan.days) * 24)h"], 900)
            let line = (result?.output ?? "").split(separator: "\n").last { $0.lowercased().contains("reclaimed") }.map(String.init)
            report.steps.append(.init(kind: .buildCache, removed: result?.status == 0 ? plan.buildCacheEntries : 0, attempted: plan.buildCacheEntries, notes: line.map { [$0] } ?? []))
        }
        if kinds.contains(.networks) {
            let result = run(["network", "prune", "--force", "--filter", "until=\(max(0, plan.days) * 24)h"], 120)
            let removed = (result?.output ?? "").split(separator: "\n").filter { !$0.contains(":") && !$0.isEmpty }.count
            report.steps.append(.init(kind: .networks, removed: removed, attempted: removed))
        }
        if kinds.contains(.volumes), !plan.volumes.isEmpty {
            var removed = 0
            for volume in plan.volumes where run(["volume", "rm", volume.name], 120)?.status == 0 { removed += 1 }
            report.steps.append(.init(kind: .volumes, removed: removed, attempted: plan.volumes.count, notes: removed < plan.volumes.count ? ["Docker refused \(plan.volumes.count - removed): mounted by a container."] : []))
        }
        if compact {
            let outcome = self.compact()
            report.compacted = outcome.done
            report.compactNote = outcome.note
        }
        report.dockerBytesAfter = totalBytes()
        report.diskImageAfter = diskImageBytes()
        return report
    }

    /// Tells the VM's filesystem to hand unused blocks back, which is what shrinks the disk image
    /// on the Mac. Docker has no command for it, so it is done from a privileged one-off
    /// container of an image that is already here; nothing is pulled.
    public func compact() -> (done: Bool, note: String) {
        guard let list = run(["images", "--format", "{{.Repository}}:{{.Tag}}"], 30), list.status == 0 else { return (false, "Docker did not answer.") }
        let candidates = list.output.split(separator: "\n").map(String.init).filter { name in
            !name.contains("<none>") && ["alpine", "busybox"].contains { name.lowercased().contains($0) }
        }
        guard let image = candidates.first else {
            return (false, "No local image with the needed tools (an Alpine or BusyBox one) is present; Docker returns the space by itself over time.")
        }
        let script = "nsenter -t 1 -m -- fstrim -v /var/lib/docker"
        guard let result = run(["run", "--rm", "--privileged", "--pid=host", "--network=none", "--entrypoint", "sh", image, "-c", script], 600), result.status == 0 else {
            return (false, "The trim could not be run from \(image).")
        }
        return (true, result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
