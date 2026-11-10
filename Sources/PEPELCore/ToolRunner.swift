import Foundation

/// Locates and runs a small, fixed set of developer tools (git, docker, go, …) with a timeout and
/// a minimal environment. Only absolute paths from known directories are ever executed.
public struct ToolRunner: Sendable {
    public var searchPaths: [String]
    public var home: String
    /// When set, only these tools can be located; everything else is treated as not installed.
    public var allowedTools: Set<String>?

    public init(home: String = NSHomeDirectory(), searchPaths: [String]? = nil, allowedTools: Set<String>? = nil) {
        self.home = home
        self.allowedTools = allowedTools
        self.searchPaths = searchPaths ?? [
            "/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin", home + "/.docker/bin", home + "/.cargo/bin",
            home + "/go/bin", home + "/.local/bin", home + "/.local/share/mise/shims", "/usr/local/go/bin",
            "/Applications/Docker.app/Contents/Resources/bin",
        ]
    }

    /// A runner that finds nothing. Used in tests so no real tool is ever invoked.
    public static let disabled = ToolRunner(home: "/nonexistent", searchPaths: [])

    public func locate(_ name: String) -> String? {
        guard !name.contains("/"), allowedTools?.contains(name) ?? true else { return nil }
        return searchPaths.lazy.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    public func run(_ name: String, _ arguments: [String], timeout: TimeInterval = 10, cwd: String? = nil) -> (status: Int32, output: String)? {
        guard let executable = locate(name) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": searchPaths.joined(separator: ":"), "HOME": home, "LC_ALL": "C", "NO_COLOR": "1"]
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let box = OutputBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.set(pipe.fileHandleForReading.readDataToEndOfFile())
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
            return nil
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: box.get(), as: UTF8.self))
    }
}
