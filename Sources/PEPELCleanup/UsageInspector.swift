import Foundation
import PEPELCore

/// Establishes which artifacts are in use by running processes right now.
public enum UsageInspector {
    /// - Returns: item id → human-readable reason, for every item that appears to be in use.
    public static func inspect(
        items: [StorageItem], processes: [ProcessSnapshot], assessments: [ProcessAssessment], runningWrappedBuilds: [BuildRecord] = []
    ) -> [String: String] {
        let working = assessments.filter {
            $0.lifecycle == .activeBuildOrTest || $0.lifecycle == .activeDevService || $0.lifecycle == .agentSession
                || ($0.lifecycle == .backgroundService && $0.role == .devServer)
        }
        let builders = assessments.filter { $0.lifecycle == .activeBuildOrTest }
        var result: [String: String] = [:]

        for item in items where !item.hasPseudoPath {
            let root = item.path
            if let p = processes.first(where: { $0.executablePath.map { PathUtil.isInside($0, root: root) } ?? false }) {
                result[item.id] = "\(p.name) (PID \(p.pid)) is running from it."
                continue
            }
            if let p = processes.first(where: { $0.workingDirectory.map { PathUtil.isInside($0, root: root) } ?? false }) {
                result[item.id] = "It is the working directory of \(p.name) (PID \(p.pid))."
                continue
            }
            if let a = working.first(where: { a in a.process.arguments.contains { $0.contains(root) } }) {
                result[item.id] = "Referenced by running \(a.process.name) (PID \(a.process.pid))."
                continue
            }
            if let projectID = item.projectID {
                let projectScoped: Set<ArtifactCategory> = [.buildOutput, .dependencies, .virtualEnvironment, .dependencyCache, .testArtifact, .toolCache]
                if projectScoped.contains(item.category) {
                    // Linter and test caches are recreated on demand: a language server or an
                    // agent's helper in the project does not need them, only a running build or test.
                    let blockers = item.category == .toolCache ? builders : working
                    if let a = blockers.first(where: { $0.projectID == projectID && $0.role != .agent }) {
                        result[item.id] = "\(a.process.name) (PID \(a.process.pid)) is running in this project."
                        continue
                    }
                    if let record = runningWrappedBuilds.first(where: { $0.projectID == projectID }) {
                        result[item.id] = "A wrapped build is running in this project: \(record.command)"
                        continue
                    }
                }
            } else if item.category == .toolCache || item.category == .dependencyCache, let a = builders.first {
                // Shared caches cannot be tied to one build; while anything builds they are left alone.
                result[item.id] = "Builds are running (\(a.process.name), PID \(a.process.pid)); shared caches may be in use."
            }
        }
        return result
    }
}
