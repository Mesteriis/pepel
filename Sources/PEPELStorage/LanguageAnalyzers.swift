import Foundation
import PEPELCore

/// Shared validation for analyzers whose items are either a fixed cache location or a
/// well-known directory name inside a project.
private func validateShape(_ item: StorageItem, allowedNames: Set<String>, allowedFragments: [String]) -> String? {
    if item.hasPseudoPath { return nil }
    guard let identity = PathUtil.identity(item.path) else { return L("The path no longer exists.") }
    if identity.isSymlink { return L("The path is now a symbolic link.") }
    let name = (item.path as NSString).lastPathComponent
    if allowedNames.contains(name) || allowedFragments.contains(where: { item.path.contains($0) }) { return nil }
    return L("The path no longer matches what this analyzer recognises.")
}

public struct PythonAnalyzer: StorageAnalyzer {
    public let id = "python"
    public let displayName = "Python"
    public let detection = L("Tool caches by name, virtual environments by their pyvenv.cfg, pip and uv caches at their fixed locations.")

    public init() {}

    public func supportedPaths(_ context: ScanContext) -> [String] {
        ["Library/Caches/pip", ".cache/pip", ".cache/uv"].map { context.home + "/" + $0 }
    }

    public func discover(_ context: ScanContext) async -> AnalyzerOutput {
        var output = AnalyzerOutput()
        let python: Set<String> = ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "tox.ini", "noxfile.py", "Pipfile"]
        for hit in context.hits {
            let owner = (hit.parent as NSString).lastPathComponent
            switch hit.name {
            case ".pytest_cache", ".mypy_cache", ".ruff_cache":
                guard hit.gitIgnored != false else { continue }
                let tool = hit.name.dropFirst().replacingOccurrences(of: "_cache", with: "")
                output.items.append(
                    item(
                        context, category: .toolCache, path: hit.path, title: L("\(owner) · \(tool) cache"),
                        explanation: L("Cache written by \(tool). It is recreated automatically on the next run and holds no results worth keeping."),
                        safety: .safe, reason: L("Pure cache, recreated automatically.")))
            case ".tox", ".nox":
                guard hit.gitIgnored != false else { continue }
                output.items.append(
                    item(
                        context, category: .virtualEnvironment, path: hit.path, title: L("\(owner) · \(hit.name.dropFirst()) environments"),
                        explanation: L("Test environments created by \(hit.name.dropFirst()). Recreated on the next run, which reinstalls every dependency."),
                        safety: .review, reason: L("Reproducible, but rebuilding takes time and network access.")))
            case ".venv", "venv":
                guard PathUtil.exists(hit.path + "/pyvenv.cfg") else { continue }
                output.items.append(
                    item(
                        context, category: .virtualEnvironment, path: hit.path, title: L("\(owner) · virtual environment"),
                        explanation: L("Python virtual environment. It may contain packages installed by hand that no lock file records."),
                        safety: .review, reason: L("Recreating it may not restore packages installed by hand; removed on its own only under the rule for projects left untouched.")))
            case "build", "dist":
                guard hit.gitIgnored == true, !hit.siblings.isDisjoint(with: python), !hit.siblings.contains("package.json") else { continue }
                output.items.append(
                    item(
                        context, category: .buildOutput, path: hit.path, title: "\(owner) · Python \(hit.name)",
                        explanation: L("Python packaging output, ignored by git. Recreated by building the package again."),
                        safety: .review, reason: L("Reproducible; may contain release artefacts you have not uploaded yet."),
                        build: BuildMetadata(system: .python, configuration: hit.name, branch: branchInfo(context, projectID: hit.projectID).branch)))
            default:
                continue
            }
        }
        for relative in ["Library/Caches/pip", ".cache/pip"] {
            guard let path = context.homeDirectory(relative) else { continue }
            output.items.append(
                item(
                    context, category: .dependencyCache, path: path, title: L("pip cache"),
                    explanation: L("Downloaded and built wheels. pip downloads them again when needed."),
                    safety: .review, reason: L("Recoverable by downloading; needs network access.")))
        }
        if let uv = context.homeDirectory(".cache/uv") {
            output.items.append(
                item(
                    context, category: .dependencyCache, path: uv, title: L("uv cache"),
                    explanation: L("Packages cached by uv. Environments created by uv link into this cache, so the space freed can be smaller than shown."),
                    safety: .review, reason: L("Recoverable by downloading; needs network access."),
                    method: context.tools.locate("uv") != nil ? .tool(.uvCacheClean) : .filesystem))
        }
        return output
    }

    public func validate(_ item: StorageItem) -> String? {
        validateShape(
            item, allowedNames: [".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".nox", ".venv", "venv", "build", "dist"],
            allowedFragments: ["/Library/Caches/pip", "/.cache/pip", "/.cache/uv"])
    }
}

public struct NodeAnalyzer: StorageAnalyzer {
    public let id = "node"
    public let displayName = "Node.js"
    public let detection = L("node_modules and framework output directories next to a package.json; npm, pnpm and Yarn caches at their fixed locations.")

    public init() {}

    public func supportedPaths(_ context: ScanContext) -> [String] {
        [".npm/_cacache", "Library/Caches/Yarn", ".yarn/berry/cache", "Library/pnpm/store"].map { context.home + "/" + $0 }
    }

    public func discover(_ context: ScanContext) async -> AnalyzerOutput {
        var output = AnalyzerOutput()
        for hit in context.hits where hit.siblings.contains("package.json") {
            let owner = (hit.parent as NSString).lastPathComponent
            let branch = branchInfo(context, projectID: hit.projectID).branch
            switch hit.name {
            case "node_modules":
                guard hit.gitIgnored != false else { continue }
                output.items.append(
                    item(
                        context, category: .dependencies, path: hit.path, title: "\(owner) · node_modules",
                        explanation: L("Installed npm packages. Restored by the package manager's install command."),
                        safety: .review, reason: L("Reproducible from the lock file; reinstalling takes time and network access.")))
            case ".next", ".nuxt", ".turbo", ".parcel-cache", ".svelte-kit", ".angular":
                guard hit.gitIgnored != false else { continue }
                output.items.append(
                    item(
                        context, category: .buildOutput, path: hit.path, title: "\(owner) · \(hit.name)",
                        explanation: L("Framework build output and cache. Recreated by the next build or dev-server start."),
                        safety: .review, reason: L("Reproducible; a running dev server would have to be restarted."),
                        build: BuildMetadata(system: .node, configuration: String(hit.name.dropFirst()), branch: branch)))
            case "dist", "build", "out":
                // Ambiguous names: only when git confirms they are not source.
                guard hit.gitIgnored == true else { continue }
                output.items.append(
                    item(
                        context, category: .buildOutput, path: hit.path, title: "\(owner) · \(hit.name)",
                        explanation: L("Bundler output, ignored by git. Recreated by the project's build script."),
                        safety: .review, reason: L("Reproducible; may be what a local server is currently serving."),
                        build: BuildMetadata(system: .node, configuration: hit.name, branch: branch)))
            default:
                continue
            }
        }
        for (relative, title) in [(".npm/_cacache", L("npm cache")), ("Library/Caches/Yarn", L("Yarn cache")), (".yarn/berry/cache", L("Yarn Berry cache"))] {
            guard let path = context.homeDirectory(relative) else { continue }
            output.items.append(
                item(
                    context, category: .dependencyCache, path: path, title: title,
                    explanation: L("Downloaded package tarballs. Downloaded again when needed."),
                    safety: .review, reason: L("Recoverable by downloading; needs network access.")))
        }
        if let store = context.homeDirectory("Library/pnpm/store") {
            var entry = item(
                context, category: .dependencyCache, path: store, title: L("pnpm store"),
                explanation: L("Content-addressable package store. Projects hard-link into it, so only packages no project references can be freed; pnpm decides which."),
                safety: .review, reason: L("Shared with every pnpm project on this machine."),
                method: context.tools.locate("pnpm") != nil ? .tool(.pnpmStorePrune) : .none)
            // The amount pnpm will free is not knowable in advance; do not claim any.
            entry.toolReportedReclaimable = 0
            output.items.append(entry)
        }
        return output
    }

    public func validate(_ item: StorageItem) -> String? {
        validateShape(
            item, allowedNames: ["node_modules", ".next", ".nuxt", ".turbo", ".parcel-cache", ".svelte-kit", ".angular", "dist", "build", "out"],
            allowedFragments: ["/.npm/_cacache", "/Library/Caches/Yarn", "/.yarn/berry/cache", "/Library/pnpm/store"])
    }
}

public struct RustAnalyzer: StorageAnalyzer {
    public let id = "rust"
    public let displayName = "Rust / Cargo"
    public let detection = L("`target` directories next to a Cargo.toml that carry Cargo's own markers; registry and git caches under ~/.cargo.")

    public init() {}

    public func supportedPaths(_ context: ScanContext) -> [String] {
        [".cargo/registry/cache", ".cargo/registry/src", ".cargo/git/checkouts"].map { context.home + "/" + $0 }
    }

    public func discover(_ context: ScanContext) async -> AnalyzerOutput {
        var output = AnalyzerOutput()
        for hit in context.hits(named: ["target"]) {
            guard hit.siblings.contains("Cargo.toml"), hit.gitIgnored != false,
                PathUtil.exists(hit.path + "/CACHEDIR.TAG") || PathUtil.exists(hit.path + "/.rustc_info.json")
            else { continue }
            let owner = (hit.parent as NSString).lastPathComponent
            let (branch, commit) = branchInfo(context, projectID: hit.projectID)
            for profile in (PathUtil.list(hit.path) ?? []).sorted() {
                let path = hit.path + "/" + profile
                guard let identity = PathUtil.identity(path), identity.isDirectory, !identity.isSymlink else { continue }
                output.items.append(
                    item(
                        context, category: .buildOutput, path: path, title: "\(owner) · target/\(profile)",
                        explanation: L("Cargo build products for the \(profile) profile. `cargo build` recreates them."),
                        safety: .review, reason: L("Reproducible; removing it forces a full rebuild."),
                        build: BuildMetadata(system: .cargo, configuration: profile, branch: branch, commit: commit, sourcePath: hit.parent + "/Cargo.toml")))
            }
        }
        for (relative, title, text) in [
            (".cargo/registry/cache", L("Cargo registry archives"), L("Downloaded crate archives. Cargo restores them when needed.")),
            (".cargo/registry/src", L("Cargo registry sources"), L("Unpacked crate sources; Cargo unpacks them again from the archives. Cargo restores them when needed.")),
            (".cargo/git/checkouts", L("Cargo git checkouts"), L("Checkouts of git dependencies; Cargo recreates them from its git database. Cargo restores them when needed.")),
        ] {
            guard let path = context.homeDirectory(relative) else { continue }
            output.items.append(
                item(
                    context, category: .dependencyCache, path: path, title: title, explanation: text,
                    safety: .review, reason: L("Recoverable; may need network access.")))
        }
        return output
    }

    public func validate(_ item: StorageItem) -> String? {
        validateShape(item, allowedNames: [], allowedFragments: ["/target/", "/.cargo/registry/", "/.cargo/git/checkouts"])
    }
}

public struct GoAnalyzer: StorageAnalyzer {
    public let id = "go"
    public let displayName = "Go"
    public let detection = L("Build and module cache locations reported by `go env`, plus leftover go-build directories in the temporary folder.")

    public init() {}

    public func supportedPaths(_ context: ScanContext) -> [String] {
        [context.home + "/Library/Caches/go-build", context.home + "/go/pkg/mod", context.temporaryDirectory]
    }

    public func discover(_ context: ScanContext) async -> AnalyzerOutput {
        var output = AnalyzerOutput()
        var buildCache = context.home + "/Library/Caches/go-build"
        var moduleCache = context.home + "/go/pkg/mod"
        let hasGo = context.tools.locate("go") != nil
        if hasGo, let env = context.tools.run("go", ["env", "GOCACHE", "GOMODCACHE"], timeout: 5), env.status == 0 {
            let lines = env.output.split(separator: "\n").map(String.init)
            if lines.count == 2, lines.allSatisfy({ $0.hasPrefix("/") }) {
                buildCache = lines[0]
                moduleCache = lines[1]
            }
        }
        if PathUtil.isDirectory(buildCache) {
            output.items.append(
                item(
                    context, category: .toolCache, path: PathUtil.canonical(buildCache), title: L("Go build cache"),
                    explanation: L("Compiled packages and cached test results. Go rebuilds them when needed."),
                    safety: .review, reason: L("Reproducible; the next builds and tests are slower."),
                    method: hasGo ? .tool(.goBuildCache) : .filesystem))
        }
        if PathUtil.isDirectory(moduleCache) {
            output.items.append(
                item(
                    context, category: .dependencyCache, path: PathUtil.canonical(moduleCache), title: L("Go module cache"),
                    explanation: L("Downloaded module sources shared by all Go projects. Go downloads them again when needed."),
                    safety: .review, reason: L("Recoverable by downloading; needs network access."),
                    method: hasGo ? .tool(.goModuleCache) : .filesystem))
        }
        // `go test` and `go run` leave go-build* work directories behind when interrupted.
        let temp = context.temporaryDirectory
        for name in PathUtil.list(temp) ?? [] where name.hasPrefix("go-build") {
            let path = temp + "/" + name
            guard let identity = PathUtil.identity(path), identity.isDirectory, !identity.isSymlink,
                let modified = PathUtil.modificationDate(path), context.now.timeIntervalSince(modified) > 86_400
            else { continue }
            output.items.append(
                item(
                    context, category: .temporary, path: path, title: L("Go temporary build \(name.dropFirst("go-build".count))"),
                    explanation: L("Work directory left by an interrupted `go test` or `go run`, untouched for more than a day."),
                    safety: .safe, reason: L("Temporary directory of a finished Go command.")))
        }
        return output
    }

    public func validate(_ item: StorageItem) -> String? {
        validateShape(item, allowedNames: ["go-build", "mod"], allowedFragments: ["/go-build"])
    }
}

/// CMake and Ninja build trees, recognised by the files those tools write into them.
public struct CMakeAnalyzer: StorageAnalyzer {
    public let id = "cmake"
    public let displayName = "CMake / Ninja"
    public let detection = L("Directories containing CMakeCache.txt or build.ninja. Plain Make output has no reliable marker and is not detected.")

    public init() {}

    public func discover(_ context: ScanContext) async -> AnalyzerOutput {
        var output = AnalyzerOutput()
        for hit in context.hits where hit.name == "build" || hit.name == "out" || hit.name.hasPrefix("cmake-build-") {
            let hasCMake = PathUtil.exists(hit.path + "/CMakeCache.txt")
            let hasNinja = PathUtil.exists(hit.path + "/build.ninja")
            guard hasCMake || hasNinja, hit.gitIgnored != false else { continue }
            let owner = (hit.parent as NSString).lastPathComponent
            let (branch, commit) = branchInfo(context, projectID: hit.projectID)
            output.items.append(
                item(
                    context, category: .buildOutput, path: hit.path, title: "\(owner) · \(hit.name)",
                    explanation: L("\(hasCMake ? "CMake" : "Ninja") build tree. Recreated by configuring and building again."),
                    safety: .review, reason: L("Reproducible; removing it forces reconfiguration and a full rebuild."),
                    build: BuildMetadata(system: hasCMake ? .cmake : .ninja, configuration: hit.name, branch: branch, commit: commit)))
        }
        return output
    }

    public func validate(_ item: StorageItem) -> String? {
        guard let identity = PathUtil.identity(item.path) else { return L("The path no longer exists.") }
        if identity.isSymlink { return L("The path is now a symbolic link.") }
        return PathUtil.exists(item.path + "/CMakeCache.txt") || PathUtil.exists(item.path + "/build.ninja")
            ? nil : L("It no longer contains CMake or Ninja build files.")
    }
}

/// Test result bundles written into projects by `xcodebuild -resultBundlePath`.
public struct TestResultAnalyzer: StorageAnalyzer {
    public let id = "test-results"
    public let displayName = L("Test result bundles")
    public let detection = L("`.xcresult` bundles inside projects.")

    public init() {}

    public func discover(_ context: ScanContext) async -> AnalyzerOutput {
        var output = AnalyzerOutput()
        for hit in context.hits where hit.name.hasSuffix(".xcresult") && hit.gitIgnored != false {
            output.items.append(
                item(
                    context, category: .testArtifact, path: hit.path, title: hit.name,
                    explanation: L("Xcode test result bundle with logs and attachments."),
                    safety: .review, reason: L("Not reproducible exactly; you may still need a failed run's report."), reproducible: false))
        }
        return output
    }

    public func validate(_ item: StorageItem) -> String? {
        validateShape(item, allowedNames: [], allowedFragments: [".xcresult"])
    }
}
