import Foundation
import PEPELCore

/// Finds booted simulators from the process table alone: each one is a `launchd_sim` whose
/// arguments name its device directory. No tool is run to detect them.
public enum Simulators {
    static func udid(of p: ProcessSnapshot) -> String? {
        guard p.name == "launchd_sim" else { return nil }
        for argument in p.arguments {
            guard let range = argument.range(of: "/CoreSimulator/Devices/") else { continue }
            let candidate = String(argument[range.upperBound...].prefix(36))
            if UUID(uuidString: candidate) != nil { return candidate }
        }
        return nil
    }

    static func deviceName(udid: String, home: String) -> String? {
        let path = home + "/Library/Developer/CoreSimulator/Devices/\(udid)/device.plist"
        guard let data = FileManager.default.contents(atPath: path),
            let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        return plist["name"] as? String
    }

    /// - Parameter workingSessions: agent sessions working now; agents drive simulators without the Simulator window.
    public static func booted(processes: [ProcessSnapshot], home: String, workingSessions: Int) -> [BootedSimulator] {
        let tree = ProcessTree(processes)
        var busy: String?
        if processes.contains(where: { $0.executablePath?.hasSuffix("Simulator.app/Contents/MacOS/Simulator") ?? false }) {
            busy = "The Simulator application is open."
        } else if processes.contains(where: { $0.name == "xcodebuild" || ($0.executablePath?.hasSuffix("Xcode.app/Contents/MacOS/Xcode") ?? false) }) {
            busy = "Xcode or xcodebuild is running."
        } else if workingSessions > 0 {
            busy = "\(workingSessions) agent session\(workingSessions == 1 ? " is" : "s are") working and may be driving it."
        }
        return processes.compactMap { p -> BootedSimulator? in
            guard let udid = udid(of: p) else { return nil }
            let members = tree.descendants(of: p)
            return BootedSimulator(
                udid: udid, name: deviceName(udid: udid, home: home) ?? "Simulator \(udid.prefix(8))", root: p.identity, processCount: members.count + 1,
                footprintBytes: members.reduce(p.footprintBytes) { $0 + $1.footprintBytes }, bootedAt: p.identity.startDate, inUse: busy)
        }
        .sorted { $0.footprintBytes > $1.footprintBytes }
    }

    /// Language servers and indexers that talk to their editor over standard input and output.
    /// Once the editor or agent that started one is gone it has nobody to answer, ever.
    static let stdioTools: Set<String> = [
        "sourcekit-lsp", "gopls", "rust-analyzer", "pyright-langserver", "typescript-language-server", "clangd", "jdtls", "lua-language-server",
        "ruby-lsp", "solargraph", "zls", "bash-language-server", "vscode-json-language-server", "yaml-language-server",
    ]

    /// Such tools whose parent has exited (they were re-parented to launchd).
    public static func orphanedTools(
        processes: [ProcessSnapshot], excluded: Set<ProcessIdentity>, attributor: (any ProjectAttributing)?, currentUID: UInt32, now: Date,
        minimumAge: TimeInterval = 300
    ) -> [ProcessAssessment] {
        let tree = ProcessTree(processes)
        return processes.compactMap { p -> ProcessAssessment? in
            guard p.uid == currentUID, p.parentPID == 1, !excluded.contains(p.identity), now.timeIntervalSince(p.identity.startDate) >= minimumAge else { return nil }
            let names = [p.name] + p.arguments.prefix(4).map { ($0 as NSString).lastPathComponent }
            guard let tool = names.first(where: { stdioTools.contains($0) }) else { return nil }
            // Started with a socket or port instead of stdio: something may still connect.
            guard p.listeningPorts.isEmpty, !p.arguments.contains(where: { $0.hasPrefix("--socket") || $0.hasPrefix("--port") || $0 == "--tcp" }) else { return nil }
            let descendants = tree.descendants(of: p)
            let attribution = p.workingDirectory.flatMap { attributor?.attribute(path: $0) }
            var assessment = ProcessAssessment(
                process: p, role: .ide, lifecycle: .abandonedSubprocess, confidence: .verified, projectID: attribution?.projectID,
                projectConfidence: attribution == nil ? .unknown : .verified,
                evidence: [
                    "\(tool) serves one editor or agent over standard input and output.",
                    "The program that started it has exited, so nothing can talk to it any more.",
                    "Started \(TimeFormat.ago(p.identity.startDate)).",
                ],
                eligibility: .automaticEligible, descendantCount: descendants.count,
                subtreeFootprintBytes: descendants.reduce(p.footprintBytes) { $0 + $1.footprintBytes })
            assessment.orphanedTool = true
            return assessment
        }
        .sorted { $0.subtreeFootprintBytes > $1.subtreeFootprintBytes }
    }
}
