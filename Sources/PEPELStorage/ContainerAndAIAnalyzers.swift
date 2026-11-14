import Foundation
import PEPELCore

/// Docker resources as reported by the Docker CLI. Nothing is read from Docker's disk image
/// and nothing is ever removed except through `docker … prune`.
public struct DockerAnalyzer: StorageAnalyzer {
    public let id = "docker"
    public let displayName = L("Docker and containers")
    public let detection = L("`docker system df` for volumes (shown, never removed); fixed locations for Colima and Lima disks. Containers, images and build cache are under `pepel docker`.")

    public init() {}

    public func supportedPaths(_ context: ScanContext) -> [String] { [context.home + "/.colima", context.home + "/.lima"] }

    /// "1.2GB", "512MB", "0B", "3.4kB" → bytes.
    static func parseSize(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let number = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number) else { return nil }
        let multiplier: Double =
            switch trimmed.dropFirst(number.count).trimmingCharacters(in: .whitespaces).lowercased() {
            case "b", "": 1
            case "kb": 1e3
            case "mb": 1e6
            case "gb": 1e9
            case "tb": 1e12
            default: -1
            }
        return multiplier < 0 ? nil : Int64(value * multiplier)
    }

    public func discover(_ context: ScanContext) async -> AnalyzerOutput {
        var output = AnalyzerOutput()
        for (relative, title) in [(".colima", L("Colima virtual machines")), (".lima", L("Lima virtual machines"))] {
            guard let path = context.homeDirectory(relative) else { continue }
            output.items.append(
                item(
                    context, category: .container, path: path, title: title,
                    explanation: L("Virtual machine disks holding images, containers and volumes. Manage them with the tool that created them."),
                    safety: .protected, reason: L("May contain database volumes."), reproducible: false, method: .none))
        }
        guard context.tools.locate("docker") != nil else { return output }
        guard let result = context.tools.run("docker", ["system", "df", "--format", "{{json .}}"], timeout: 8), result.status == 0 else {
            output.issues.append(L("Docker is installed but its daemon did not answer; Docker resources were not inspected."))
            return output
        }
        for line in result.output.split(separator: "\n") {
            guard let data = line.data(using: .utf8), let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = row["Type"] as? String, let size = (row["Size"] as? String).flatMap(Self.parseSize)
            else { continue }
            // "Reclaimable" looks like "1.2GB (50%)".
            let reclaimable = (row["Reclaimable"] as? String).flatMap { Self.parseSize(String($0.split(separator: " ").first ?? "")) } ?? 0
            var entry: StorageItem
            // Containers, images and build cache are handled by the Docker panel, which knows how
            // long each has been unused; listing them here too would offer to wipe all of them.
            guard type == "Local Volumes" else { continue }
            switch type {
            case "Build Cache":
                entry = toolItem("build-cache", L("Docker build cache"), L("Cached build layers. Docker rebuilds layers as needed; the next image builds are slower."), .review, L("Reproducible by rebuilding."), .tool(.dockerBuildCache), .toolCache)
            case "Containers":
                entry = toolItem("stopped-containers", L("Stopped Docker containers"), L("Containers that are not running. Their writable layers are lost when removed; named volumes are kept."), .review, L("Stopped containers can still hold files you want."), .tool(.dockerStoppedContainers), .container)
            case "Images":
                entry = toolItem("dangling-images", L("Dangling Docker images"), L("Untagged image layers no container uses. Tagged images are left alone even when unused."), .review, L("Only untagged layers are pruned; the figure Docker reports also includes unused tagged images."), .tool(.dockerDanglingImages), .container)
            case "Local Volumes":
                entry = toolItem("volumes", L("Docker volumes"), L("Named and anonymous volumes. They often hold databases."), .protected, L("Volumes are never removed by PEPEL."), .none, .containerVolume)
            default:
                continue
            }
            guard size > 0 else { continue }
            entry.toolReportedReclaimable = entry.safety == .protected ? size : reclaimable
            output.items.append(entry)
        }
        return output
    }

    private func toolItem(
        _ slug: String, _ title: String, _ explanation: String, _ safety: SafetyClass, _ reason: String, _ method: CleanupMethod,
        _ category: ArtifactCategory
    ) -> StorageItem {
        StorageItem(
            analyzerID: id, category: category, path: "tool://docker/" + slug, title: title, explanation: explanation,
            safety: safety, safetyReason: reason, reproducible: safety != .protected, method: method)
    }
}

/// AI tool directories. Session state, history, credentials and model weights are reported for
/// visibility and always protected; only clearly temporary output is ever proposed.
public struct AIToolsAnalyzer: StorageAnalyzer {
    public let id = "ai-tools"
    public let displayName = L("AI tools and local models")
    public let detection = L("Fixed home-directory locations of each tool. Their contents are sized but never interpreted.")

    public init() {}

    private static let protectedLocations: [(path: String, title: String, category: ArtifactCategory, text: String)] = [
        (".claude", L("Claude Code state"), .agentState, L("Sessions, history, settings and credentials of Claude Code.")),
        (".codex", L("Codex state"), .agentState, L("Sessions, history, settings and credentials of Codex.")),
        (".local/share/opencode", L("OpenCode state"), .agentState, L("Sessions and history of OpenCode.")),
        (".config/opencode", L("OpenCode configuration"), .agentState, L("Configuration and credentials of OpenCode.")),
        (".hermes", L("Hermes state"), .agentState, L("Sessions, memory and configuration of Hermes.")),
        (".bb", L("BB state"), .agentState, L("Threads, projects, plugins and their models of BB.")),
        (".ollama/models", L("Ollama models"), .modelWeights, L("Model weights pulled by Ollama. Re-downloading can take hours.")),
        (".cache/huggingface", L("Hugging Face cache"), .modelWeights, L("Models and datasets downloaded through Hugging Face libraries, including MLX models.")),
        (".lmstudio/models", L("LM Studio models"), .modelWeights, L("Model weights downloaded by LM Studio.")),
    ]

    public func supportedPaths(_ context: ScanContext) -> [String] {
        Self.protectedLocations.map { context.home + "/" + $0.path } + [context.home + "/Library/Caches/claude-cli-nodejs"]
    }

    public func discover(_ context: ScanContext) async -> AnalyzerOutput {
        var output = AnalyzerOutput()
        for location in Self.protectedLocations {
            guard let path = context.homeDirectory(location.path) else { continue }
            output.items.append(
                item(
                    context, category: location.category, path: path, title: location.title, explanation: location.text,
                    safety: .protected,
                    reason: location.category == .modelWeights ? L("Reusable model weights are kept.") : L("Agent state and credentials are never touched."),
                    reproducible: false, method: .none))
        }
        if let cache = context.homeDirectory("Library/Caches/claude-cli-nodejs") {
            output.items.append(
                item(
                    context, category: .toolCache, path: cache, title: L("Claude Code cache"),
                    explanation: L("Cache directory of the Claude Code CLI in ~/Library/Caches. macOS itself may purge this location."),
                    safety: .review, reason: L("A cache by location, but its contents are not documented.")))
        }
        // Scratch directories agents create under the system temporary folder (claude-<uid>/<session>).
        for base in [context.sharedTemporaryDirectory + "/claude-\(getuid())", context.temporaryDirectory + "/claude-\(getuid())"] {
            guard let identity = PathUtil.identity(base), identity.isDirectory, !identity.isSymlink else { continue }
            for name in PathUtil.list(base) ?? [] {
                let path = base + "/" + name
                guard let id = PathUtil.identity(path), id.isDirectory, !id.isSymlink, let modified = PathUtil.modificationDate(path),
                    context.now.timeIntervalSince(modified) > 3 * 86_400
                else { continue }
                output.items.append(
                    item(
                        context, category: .temporary, path: path, title: L("Agent scratch \(name.prefix(24))"),
                        explanation: L("Temporary working files of an agent session, untouched for more than three days. The association with a finished session is a heuristic."),
                        safety: .review, reason: L("Temporary by location; PEPEL cannot verify that the session is finished."), reproducible: false))
            }
        }
        return output
    }
}

public enum AnalyzerRegistry {
    public static func all() -> [any StorageAnalyzer] {
        [
            XcodeDerivedDataAnalyzer(), XcodeSupportAnalyzer(), SwiftPMAnalyzer(), PythonAnalyzer(), NodeAnalyzer(), RustAnalyzer(),
            GoAnalyzer(), CMakeAnalyzer(), TestResultAnalyzer(), DockerAnalyzer(), AIToolsAnalyzer(),
        ]
    }
}
