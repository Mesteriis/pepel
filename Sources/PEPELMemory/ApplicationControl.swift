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

    public init(
        isAvailable: Bool, quit: @escaping @Sendable (Int32) -> Bool, launch: @escaping @Sendable (String) async -> Bool,
        hide: @escaping @Sendable (Int32) -> Bool = { _ in false }
    ) {
        self.isAvailable = isAvailable
        self.quit = quit
        self.launch = launch
        self.hide = hide
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
        hide: { pid in NSRunningApplication(processIdentifier: pid)?.hide() ?? false })
}
