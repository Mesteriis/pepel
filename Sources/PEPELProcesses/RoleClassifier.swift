import Foundation
import PEPELCore

/// Classifies what a process is from its executable and command line. Purely name-based, so the
/// result is a role, not a judgement about whether the process is still needed.
public enum RoleClassifier {
    private static let interpreters: Set<String> = [
        "python", "python3", "node", "bun", "deno", "ruby", "java", "uv", "npm", "pnpm", "yarn", "npx", "poetry", "pipenv",
        "hatch", "tsx", "ts-node",
    ]
    private static let containerNames: Set<String> = [
        "docker", "dockerd", "com.docker.backend", "com.docker.virtualization", "com.docker.build", "colima", "limactl",
        "lima", "containerd", "podman", "qemu-system-aarch64", "orbstack", "docker-compose", "docker-buildx",
    ]
    private static let testNames: Set<String> = [
        "pytest", "py.test", "xctest", "jest", "vitest", "mocha", "playwright", "swiftpm-testing-helper",
        "swiftpm-xctest-helper", "tox", "nox", "nextest", "cargo-nextest",
    ]
    private static let serverNames: Set<String> = [
        "uvicorn", "gunicorn", "hypercorn", "daphne", "vite", "next-server", "nodemon", "webpack-dev-server", "air",
        "streamlit", "ts-node-dev", "wrangler",
    ]
    private static let buildNames: Set<String> = [
        "xcodebuild", "swift-build", "swift-frontend", "swiftc", "swift-driver", "swift-package", "clang", "clang++", "ld",
        "ld64", "rustc", "ninja", "make", "gmake", "cmake", "gradle", "tsc", "esbuild", "webpack", "rollup", "turbo",
        "swbbuildservice", "xcbbuildservice", "cc", "c++", "cc1", "cargo-build", "ibtool", "actool", "lipo", "dsymutil",
    ]
    private static let ideMarkers = [
        "/Xcode.app/Contents/MacOS/", "Visual Studio Code.app", "Cursor.app", "Zed.app", "/JetBrains/", "IntelliJ",
        "PyCharm", "WebStorm", "GoLand", "CLion", "RustRover", "Sublime Text.app", "Nova.app", "Windsurf.app",
    ]
    private static let languageServers: Set<String> = [
        "sourcekit-lsp", "gopls", "rust-analyzer", "pyright", "pyright-langserver", "typescript-language-server", "clangd",
    ]

    static func baseName(_ p: ProcessSnapshot) -> String {
        ((p.executablePath ?? p.name) as NSString).lastPathComponent
    }

    /// Lowercased basenames of every argument, so `/x/node_modules/.bin/vite` matches `vite`.
    static func tokens(_ p: ProcessSnapshot) -> [String] {
        p.arguments.map { ($0 as NSString).lastPathComponent.lowercased() }
    }

    public static func agentKind(of p: ProcessSnapshot) -> AgentKind? {
        let base = baseName(p)
        let first = p.arguments.first.map { ($0 as NSString).lastPathComponent } ?? ""
        let joined = p.arguments.prefix(4).joined(separator: " ")
        // "Claude" (capitalised) inside an app bundle is the desktop application, not an agent session.
        if base == "claude" || first == "claude" || joined.contains("@anthropic-ai/claude-code") { return .claudeCode }
        if base == "codex" || base.hasPrefix("codex-") || first == "codex" || joined.contains("@openai/codex") { return .codex }
        if base == "opencode" || first == "opencode" || joined.contains("opencode-ai") { return .openCode }
        if base == "hermes-agent" || first == "hermes-agent" || (base == "hermes" && !(p.executablePath ?? "").contains("node_modules")) {
            return .hermes
        }
        return nil
    }

    public static func role(of p: ProcessSnapshot, attributor: (any ProjectAttributing)? = nil) -> ProcessRole {
        if agentKind(of: p) != nil { return .agent }
        let path = p.executablePath ?? ""
        let base = baseName(p).lowercased()
        for prefix in ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"] where path.hasPrefix(prefix) {
            return .system
        }
        if containerNames.contains(base) || path.contains("/Docker.app/") || path.contains("OrbStack.app") { return .container }

        let tokens = tokens(p)
        let tokenSet = Set(tokens)
        let line = p.arguments.joined(separator: " ").lowercased()
        let isInterpreter = interpreters.contains(base) || base.hasPrefix("python") || base.hasPrefix("ruby")
        let sub = tokens.count > 1 ? tokens[1] : ""

        // Tests first: `swift test` and `cargo test` would otherwise read as builds.
        if testNames.contains(base) || !tokenSet.isDisjoint(with: testNames) { return .testRunner }
        if ["cargo", "swift", "go", "bun", "deno", "npm", "pnpm", "yarn"].contains(base), sub == "test" { return .testRunner }
        if base == "xcodebuild", tokenSet.contains("test") || tokenSet.contains("test-without-building") { return .testRunner }
        if path.contains("/target/debug/deps/") || path.contains("/target/release/deps/") || base.hasSuffix(".test")
            || path.contains(".xctest/")
        {
            return .testRunner
        }
        if isInterpreter, line.contains("-m pytest") || line.contains("-m unittest") || line.contains("manage.py test") {
            return .testRunner
        }

        if serverNames.contains(base) || !tokenSet.isDisjoint(with: serverNames) { return .devServer }
        if tokenSet.contains("next") || tokenSet.contains("nuxt") || tokenSet.contains("astro") || tokenSet.contains("remix") {
            if tokenSet.contains("dev") || tokenSet.contains("start") { return .devServer }
        }
        for marker in [
            "manage.py runserver", "fastapi dev", "fastapi run", "flask run", "rails server", "rails s", "http.server",
            "run dev", "run start", "run serve", "webpack serve", "pnpm dev", "yarn dev", "bun dev", "bun --hot", "-m uvicorn",
            "-m gunicorn", "-m http.server", "php -s", "hugo server", "jekyll serve", "mkdocs serve",
        ] where line.contains(marker) {
            return .devServer
        }

        if buildNames.contains(base) { return .buildTool }
        if ["cargo", "swift", "go"].contains(base), ["build", "check", "install", "run", "package", "vet", "bench", "clippy", "doc"].contains(sub) {
            return .buildTool
        }
        if isInterpreter {
            if !tokenSet.isDisjoint(with: ["tsc", "webpack", "rollup", "esbuild", "turbo"]) { return .buildTool }
            if (tokenSet.contains("vite") || tokenSet.contains("next")) && tokenSet.contains("build") { return .buildTool }
            if line.contains("run build") || line.contains("-m build") || line.contains("setup.py build") { return .buildTool }
        }

        if languageServers.contains(base) { return .ide }
        for marker in ideMarkers where path.contains(marker) { return .ide }
        if path.contains(".app/Contents/") { return .userApp }

        if let attributor {
            if attributor.attribute(path: path) != nil { return .projectBinary }
            if isInterpreter, let cwd = p.workingDirectory, attributor.attribute(path: cwd) != nil { return .projectBinary }
        }
        return .other
    }
}
