import Foundation
import PEPELCore

/// Xcode DerivedData: one folder per workspace, each recording the workspace it was built from.
public struct XcodeDerivedDataAnalyzer: StorageAnalyzer {
    public let id = "xcode.derived-data"
    public let displayName = "Xcode DerivedData"
    public let detection = "Folders in ~/Library/Developer/Xcode/DerivedData; the owning workspace is read from each folder's info.plist."

    public init() {}

    public func supportedPaths(_ context: ScanContext) -> [String] {
        [context.home + "/Library/Developer/Xcode/DerivedData"]
    }

    public func discover(_ context: ScanContext) async -> AnalyzerOutput {
        var output = AnalyzerOutput()
        guard let root = context.homeDirectory("Library/Developer/Xcode/DerivedData") else { return output }
        guard let names = PathUtil.list(root) else {
            output.issues.append("DerivedData could not be read.")
            return output
        }
        for name in names.sorted() {
            let path = root + "/" + name
            guard let identity = PathUtil.identity(path), identity.isDirectory, !identity.isSymlink else { continue }
            if let plist = NSDictionary(contentsOfFile: path + "/info.plist"), let workspace = plist["WorkspacePath"] as? String {
                output.items.append(buildTree(context, path: path, name: name, workspace: workspace))
            } else if name.hasSuffix(".noindex") {
                output.items.append(
                    item(
                        context, category: .toolCache, path: path, title: name,
                        explanation: "Compiler cache shared by all Xcode projects. Xcode rebuilds it on demand; the next builds are slower.",
                        safety: .review, reason: "Shared cache; removing it slows the next build of every project."))
            }
        }
        return output
    }

    private func buildTree(_ context: ScanContext, path: String, name: String, workspace: String) -> StorageItem {
        let displayName = name.split(separator: "-").dropLast().joined(separator: "-")
        let configurations = (PathUtil.list(path + "/Build/Products") ?? []).filter { !$0.hasPrefix(".") }.sorted()
        let sourceExists = PathUtil.exists(workspace)
        let attribution = context.projects.attribute(path: workspace)
        let (branch, commit) = branchInfo(context, projectID: attribution?.projectID)
        var result = item(
            context, category: .buildOutput, path: path, title: displayName.isEmpty ? name : displayName,
            explanation: sourceExists
                ? "Build products, indexes and logs for \(PathUtil.display(workspace, home: context.home)). Xcode recreates them on the next build."
                : "Built from \(PathUtil.display(workspace, home: context.home)), which no longer exists. Nothing can use these products any more.",
            safety: sourceExists ? .review : .safe,
            reason: sourceExists ? "Reproducible; removing it forces a full rebuild and re-index." : "The source workspace was deleted or moved.",
            build: BuildMetadata(
                system: .xcode, configuration: configurations.isEmpty ? nil : configurations.joined(separator: ", "),
                branch: branch, commit: commit, sourcePath: workspace, sourceMissing: !sourceExists))
        // The folder lives outside the project; ownership comes from the recorded workspace path.
        result.projectID = attribution?.projectID
        result.projectConfidence = attribution == nil ? .unknown : .verified
        return result
    }

    public func validate(_ item: StorageItem) -> String? {
        guard let identity = PathUtil.identity(item.path) else { return "The path no longer exists." }
        if identity.isSymlink { return "The path is now a symbolic link." }
        guard (item.path as NSString).deletingLastPathComponent.hasSuffix("/Library/Developer/Xcode/DerivedData") else {
            return "The path is not directly inside DerivedData."
        }
        if item.category == .buildOutput, !PathUtil.exists(item.path + "/info.plist") { return "It no longer looks like a DerivedData build folder." }
        return nil
    }
}

/// Other Xcode-owned locations: archives (kept), device support files, simulator data.
public struct XcodeSupportAnalyzer: StorageAnalyzer {
    public let id = "xcode.support"
    public let displayName = "Xcode archives, device support and simulators"
    public let detection = "Fixed locations under ~/Library/Developer."

    public init() {}

    public func supportedPaths(_ context: ScanContext) -> [String] {
        ["Xcode/Archives", "Xcode/iOS DeviceSupport", "Xcode/watchOS DeviceSupport", "Xcode/tvOS DeviceSupport", "CoreSimulator/Caches", "CoreSimulator/Devices"]
            .map { context.home + "/Library/Developer/" + $0 }
    }

    public func discover(_ context: ScanContext) async -> AnalyzerOutput {
        var output = AnalyzerOutput()
        if let archives = context.homeDirectory("Library/Developer/Xcode/Archives") {
            output.items.append(
                item(
                    context, category: .archive, path: archives, title: "Xcode Archives",
                    explanation: "Archived builds with their debug symbols. Needed to symbolicate crash reports of shipped versions; they cannot be recreated exactly.",
                    safety: .protected, reason: "Archives are not reproducible.", reproducible: false, method: .none))
        }
        for platform in ["iOS", "watchOS", "tvOS", "visionOS"] {
            guard let base = context.homeDirectory("Library/Developer/Xcode/\(platform) DeviceSupport") else { continue }
            for name in (PathUtil.list(base) ?? []).sorted() where PathUtil.isDirectory(base + "/" + name) {
                output.items.append(
                    item(
                        context, category: .simulator, path: base + "/" + name, title: "\(platform) DeviceSupport \(name)",
                        explanation: "Debug symbols copied from a physical device. Xcode copies them again the next time a device with this OS version is connected.",
                        safety: .review, reason: "Recoverable by reconnecting the device; that takes several minutes."))
            }
        }
        if let caches = context.homeDirectory("Library/Developer/CoreSimulator/Caches") {
            output.items.append(
                item(
                    context, category: .simulator, path: caches, title: "Simulator caches",
                    explanation: "dyld shared caches for simulator runtimes. Regenerated when a simulator next boots.",
                    safety: .review, reason: "Reproducible; the next simulator boot is slower."))
        }
        if let devices = context.homeDirectory("Library/Developer/CoreSimulator/Devices") {
            output.items.append(
                item(
                    context, category: .simulator, path: devices, title: "Simulator devices",
                    explanation: "Simulator disk images including installed apps and their data.",
                    safety: .protected, reason: "May contain app data and test state that cannot be recreated.", reproducible: false, method: .none))
            output.items += unavailableSimulators(context, devices: devices)
        }
        return output
    }

    /// Simulators whose runtime is no longer installed, as reported by `simctl` itself.
    private func unavailableSimulators(_ context: ScanContext, devices: String) -> [StorageItem] {
        guard let result = context.tools.run("xcrun", ["simctl", "list", "devices", "unavailable", "-j"], timeout: 15),
            result.status == 0, let data = result.output.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let runtimes = json["devices"] as? [String: [[String: Any]]]
        else { return [] }
        let paths = runtimes.values.flatMap { $0 }.compactMap { $0["udid"] as? String }.map { devices + "/" + $0 }.filter(PathUtil.isDirectory)
        guard !paths.isEmpty else { return [] }
        return [
            StorageItem(
                analyzerID: id, category: .simulator, path: "tool://simctl/unavailable",
                title: "Unavailable simulators (\(paths.count))",
                explanation: "Simulator devices whose runtime is no longer installed. They cannot be booted. Removed through simctl.",
                safety: .review, safetyReason: "Unusable without their runtime, but they may still hold app data.", reproducible: false,
                method: .tool(.simulatorUnavailable), measuredPaths: paths)
        ]
    }

    public func validate(_ item: StorageItem) -> String? {
        if item.hasPseudoPath { return nil }
        guard let identity = PathUtil.identity(item.path) else { return "The path no longer exists." }
        if identity.isSymlink { return "The path is now a symbolic link." }
        return item.path.contains("/Library/Developer/") ? nil : "The path is outside ~/Library/Developer."
    }
}

/// SwiftPM `.build` directories inside projects, plus the shared SwiftPM cache.
public struct SwiftPMAnalyzer: StorageAnalyzer {
    public let id = "swiftpm"
    public let displayName = "Swift Package Manager"
    public let detection = "`.build` directories next to a Package.swift, split per target triple and configuration."

    public init() {}

    public func supportedPaths(_ context: ScanContext) -> [String] { [context.home + "/Library/Caches/org.swift.swiftpm"] }

    public func discover(_ context: ScanContext) async -> AnalyzerOutput {
        var output = AnalyzerOutput()
        for hit in context.hits(named: [".build"]) {
            guard hit.siblings.contains("Package.swift"), hit.gitIgnored != false else { continue }
            let (branch, commit) = branchInfo(context, projectID: hit.projectID)
            let package = (hit.parent as NSString).lastPathComponent
            for triple in (PathUtil.list(hit.path) ?? []).sorted() {
                let triplePath = hit.path + "/" + triple
                guard let identity = PathUtil.identity(triplePath), identity.isDirectory, !identity.isSymlink else { continue }
                switch triple {
                case "checkouts", "repositories", "artifacts", "registry":
                    output.items.append(
                        item(
                            context, category: .dependencyCache, path: triplePath, title: "\(package) · SwiftPM \(triple)",
                            explanation: "Dependency sources fetched by SwiftPM. `swift package resolve` downloads them again.",
                            safety: .review, reason: "Recoverable by downloading; needs network access."))
                default:
                    for configuration in ["debug", "release"] {
                        let path = triplePath + "/" + configuration
                        guard let id = PathUtil.identity(path), id.isDirectory, !id.isSymlink else { continue }
                        output.items.append(
                            item(
                                context, category: .buildOutput, path: path, title: "\(package) · \(configuration)",
                                explanation: "SwiftPM \(configuration) build products for \(triple). `swift build` recreates them.",
                                safety: .review, reason: "Reproducible; removing it forces a full rebuild.",
                                build: BuildMetadata(
                                    system: .swiftpm, configuration: "\(configuration) (\(triple))", branch: branch, commit: commit,
                                    sourcePath: hit.parent + "/Package.swift")))
                    }
                }
            }
        }
        if let cache = context.homeDirectory("Library/Caches/org.swift.swiftpm") {
            output.items.append(
                item(
                    context, category: .dependencyCache, path: cache, title: "SwiftPM shared cache",
                    explanation: "Repository and manifest cache shared by all packages. SwiftPM refills it as packages are resolved.",
                    safety: .review, reason: "Recoverable by downloading; needs network access."))
        }
        return output
    }

    public func validate(_ item: StorageItem) -> String? {
        guard let identity = PathUtil.identity(item.path) else { return "The path no longer exists." }
        if identity.isSymlink { return "The path is now a symbolic link." }
        if item.path.hasSuffix("/Library/Caches/org.swift.swiftpm") { return nil }
        return item.path.contains("/.build/") ? nil : "The path is not inside a SwiftPM .build directory."
    }
}
