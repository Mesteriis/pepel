import Foundation
import PEPELCore

/// Reads container memory from the Docker CLI. Read-only: `docker info`, `docker stats
/// --no-stream` and `docker ps`. PEPEL never changes the virtual machine's limit and never
/// stops or restarts containers.
public struct ContainerInspector: Sendable {
    public typealias Runner = @Sendable (_ arguments: [String], _ timeout: TimeInterval) -> String?

    let run: Runner

    public init(tools: ToolRunner) {
        run = { arguments, timeout in
            guard let result = tools.run("docker", arguments, timeout: timeout), result.status == 0 else { return nil }
            return result.output
        }
    }

    /// For tests: answers come from the closure instead of a real Docker.
    public init(run: @escaping Runner) { self.run = run }

    /// "1.786GiB", "150.2MiB", "4.6kB", "512B" → bytes. Docker prints binary units here.
    public static func parseMemory(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let number = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number) else { return nil }
        let multiplier: Double
        switch trimmed.dropFirst(number.count).trimmingCharacters(in: .whitespaces).lowercased() {
        case "b", "": multiplier = 1
        case "kib": multiplier = 1024
        case "mib": multiplier = 1_048_576
        case "gib": multiplier = 1_073_741_824
        case "tib": multiplier = 1_099_511_627_776
        case "kb": multiplier = 1e3
        case "mb": multiplier = 1e6
        case "gb": multiplier = 1e9
        default: return nil
        }
        return Int64(value * multiplier)
    }

    /// Nil when Docker is not installed or its daemon does not answer.
    public func inspect(attributor: (any ProjectAttributing)? = nil, keep: [String] = [], now: Date = Date()) -> ContainerReport? {
        guard let info = run(["info", "--format", "{{.MemTotal}}\t{{.NCPU}}\t{{.ContainersRunning}}\t{{.Containers}}\t{{.OperatingSystem}}"], 6) else { return nil }
        let fields = info.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\t")
        guard fields.count >= 5, let limit = Int64(fields[0]) else { return nil }

        // Compose project and its directory come from labels Docker Compose itself sets.
        var labels: [String: (project: String?, directory: String?, keep: Bool, paused: Bool)] = [:]
        if let ps = run(["ps", "--format", "{{.Names}}\t{{.Label \"com.docker.compose.project\"}}\t{{.Label \"com.docker.compose.project.working_dir\"}}\t{{.Label \"pepel.keep\"}}\t{{.Status}}"], 6) {
            for line in ps.split(separator: "\n", omittingEmptySubsequences: true) {
                let parts = line.components(separatedBy: "\t")
                guard let name = parts.first, !name.isEmpty else { continue }
                let keepLabel = parts.count > 3 ? parts[3].trimmingCharacters(in: .whitespaces).lowercased() : ""
                labels[name] = (
                    parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil, parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil,
                    ["true", "1", "yes"].contains(keepLabel), parts.count > 4 && parts[4].contains("(Paused)")
                )
            }
        }
        let keepList = Set(keep)

        var containers: [ContainerMemory] = []
        if let stats = run(["stats", "--no-stream", "--format", "{{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}"], 15) {
            for line in stats.split(separator: "\n") {
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 3, let used = Self.parseMemory(parts[1].components(separatedBy: "/")[0]) else { continue }
                let label = labels[parts[0]]
                var container = ContainerMemory(
                    name: parts[0], composeProject: label?.project, workingDirectory: label?.directory, memoryBytes: used,
                    cpuPercent: Double(parts[2].replacingOccurrences(of: "%", with: "")) ?? 0)
                container.isPaused = label?.paused ?? false
                if label?.keep == true {
                    container.keepReason = "It carries the label pepel.keep."
                } else if keepList.contains(parts[0]) {
                    container.keepReason = "It is on PEPEL's keep list."
                } else if let project = label?.project, keepList.contains(project) {
                    container.keepReason = "Its compose project is on PEPEL's keep list."
                }
                containers.append(container)
            }
        }

        var grouped: [String: [ContainerMemory]] = [:]
        for container in containers { grouped[container.composeProject ?? "", default: []].append(container) }
        let groups = grouped.map { key, members -> ContainerGroup in
            let directory = members.compactMap(\.workingDirectory).first
            let attribution = directory.flatMap { attributor?.attribute(path: $0) }
            return ContainerGroup(
                id: key.isEmpty ? "standalone" : key, name: key.isEmpty ? "Started without Compose" : key, projectID: attribution?.projectID,
                projectConfidence: attribution == nil ? .unknown : .verified, containers: members.sorted { $0.memoryBytes > $1.memoryBytes })
        }
        .sorted { ($0.memoryBytes, $0.id) > ($1.memoryBytes, $1.id) }

        return ContainerReport(
            product: fields[4].isEmpty ? "Docker" : fields[4], vmLimitBytes: limit, cpus: Int(fields[1]) ?? 0, running: Int(fields[2]) ?? containers.count,
            total: Int(fields[3]) ?? containers.count, groups: groups, measuredAt: now)
    }
}
