import Foundation
import PEPELCore
import PEPELPersistence

/// Opt-in wrapper behind `pepel run -- <build command>`.
///
/// Builds PEPEL launches itself are the only ones whose start, end and outcome it knows for
/// certain. The record marks the project as building while the command runs and gives the
/// resulting artifacts a real success/failure status.
public struct BuildWrapper: Sendable {
    public let store: PepelStore

    public init(store: PepelStore) { self.store = store }

    /// Runs `command` with inherited standard streams and returns its exit status.
    public func run(command: [String], workingDirectory: String, projectID: String?, branch: String?, commit: String?) -> Int32 {
        guard let tool = command.first else { return 64 }
        var record = BuildRecord(
            projectID: projectID, workingDirectory: workingDirectory,
            command: ArgumentRedactor.redact(command).joined(separator: " "), branch: branch, commit: commit,
            wrapperPID: getpid())
        try? store.saveBuild(record)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + command.dropFirst()
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        // Let Ctrl-C reach the build; the wrapper waits and records how it ended.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        var status: Int32
        do {
            try process.run()
            process.waitUntilExit()
            status = process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
        } catch {
            FileHandle.standardError.write(Data("pepel: cannot start \(tool): \(error.localizedDescription)\n".utf8))
            status = 127
        }
        record.finishedAt = Date()
        record.exitCode = status
        try? store.saveBuild(record)
        return status
    }
}
