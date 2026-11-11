import AppKit
import Foundation
import PEPELCore

/// Asks applications to quit and opens them again, the way a person would from the Dock.
/// Never a signal and never a forced quit: an application with unsaved work gets to ask about it,
/// and if it does not quit, PEPEL reports that and leaves it running.
public struct ApplicationControl: Sendable {
    public var isAvailable: Bool
    /// Sends the normal quit request. True when the request was delivered.
    public var quit: @Sendable (Int32) -> Bool
    /// Opens the application bundle without bringing it to the front.
    public var launch: @Sendable (String) async -> Bool
    /// Hides the application's windows.
    public var hide: @Sendable (Int32) -> Bool
    /// Applications macOS lists as running.
    public var running: @Sendable () -> [RunningApplicationInfo]
    /// Normal windows each process has, open, minimised, hidden or on another Space.
    public var windowCounts: @Sendable () -> [Int32: Int]
    /// Where an application with this bundle identifier is installed.
    public var locate: @Sendable (String) -> String?

    public init(
        isAvailable: Bool, quit: @escaping @Sendable (Int32) -> Bool, launch: @escaping @Sendable (String) async -> Bool,
        hide: @escaping @Sendable (Int32) -> Bool = { _ in false }, running: @escaping @Sendable () -> [RunningApplicationInfo] = { [] },
        windowCounts: @escaping @Sendable () -> [Int32: Int] = { [:] }, locate: @escaping @Sendable (String) -> String? = { _ in nil }
    ) {
        self.windowCounts = windowCounts
        self.locate = locate
        self.isAvailable = isAvailable
        self.quit = quit
        self.launch = launch
        self.hide = hide
        self.running = running
    }

    public static let unavailable = ApplicationControl(isAvailable: false, quit: { _ in false }, launch: { _ in false })

    public static let system = ApplicationControl(
        isAvailable: true,
        quit: { pid in NSRunningApplication(processIdentifier: pid)?.terminate() ?? false },
        launch: { path in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            return await withCheckedContinuation { continuation in
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration) { _, error in
                    continuation.resume(returning: error == nil)
                }
            }
        },
        hide: { pid in NSRunningApplication(processIdentifier: pid)?.hide() ?? false },
        running: {
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard let path = app.bundleURL?.path else { return nil }
                return RunningApplicationInfo(
                    pid: app.processIdentifier, bundlePath: path, name: app.localizedName ?? (path as NSString).lastPathComponent,
                    isRegular: app.activationPolicy == .regular, bundleID: app.bundleIdentifier)
            }
        },
        windowCounts: {
            // Window owners and sizes are available without the Screen Recording permission; titles are not read.
            let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            var counts: [Int32: Int] = [:]
            for window in info {
                guard let pid = window[kCGWindowOwnerPID as String] as? Int32, (window[kCGWindowLayer as String] as? Int) == 0 else { continue }
                let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
                // Tiny or empty windows are an application's own scaffolding, not something a person opened.
                guard (bounds["Width"] ?? 0) >= 40, (bounds["Height"] ?? 0) >= 40 else { continue }
                counts[pid, default: 0] += 1
            }
            return counts
        },
        locate: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path })
}
