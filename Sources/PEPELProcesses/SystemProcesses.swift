import Foundation
import PEPELCore

/// The large processes inside "macOS services", and which of them can simply be restarted.
///
/// A handful of system components are kept alive by launchd: end one and macOS starts a fresh
/// copy within a second, which is the long-standing remedy when one has grown (`killall Dock`).
/// Everything else in the group is shown for information only.
public enum SystemProcesses {
    /// Component → what the user notices when it restarts.
    public static let restartable: [String: String] = [
        "Dock": L("The Dock and Mission Control disappear for a second; minimised windows stay."),
        "Finder": L("Finder windows close and the desktop icons redraw; file operations in progress are interrupted."),
        "SystemUIServer": L("Menu bar extras redraw."),
        "ControlCenter": L("Control Centre and its menu bar items redraw."),
        "NotificationCenter": L("Notification Centre and widgets reload."),
        "chronod": L("Widgets reload their content."),
        "Spotlight": L("The Spotlight window closes if it is open."),
    ]

    /// - Parameter excluded: processes that belong to another owner with rules of its own (the virtual machine).
    public static func find(processes: [ProcessSnapshot], excluded: Set<ProcessIdentity> = [], currentUID: UInt32, minimumFootprint: Int64 = 300 * Bytes.mb) -> [SystemProcess] {
        processes.compactMap { p -> SystemProcess? in
            guard p.uid == currentUID, !excluded.contains(p.identity), p.footprintBytes >= minimumFootprint, let path = p.executablePath else { return nil }
            // Applications Apple ships (Mail, Safari) are applications, and a virtual machine is its owner's.
            guard !path.hasPrefix("/System/Applications/"), !p.name.contains("Virtualization.VirtualMachine") else { return nil }
            guard ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"].contains(where: { path.hasPrefix($0) }) else { return nil }
            var note = restartable[p.name]
            let canRestart = note != nil
            if note == nil {
                note = p.name.hasPrefix("com.apple.WebKit.WebContent")
                    ? L("Web content shown inside an application. PEPEL cannot tell which one.")
                    : L("Part of macOS; PEPEL does not restart it.")
            }
            return SystemProcess(root: p.identity, name: p.name, footprintBytes: p.footprintBytes, residentBytes: p.residentBytes, restartable: canRestart, note: note ?? "")
        }
        .sorted { ($0.restartable ? 1 : 0, $0.footprintBytes) > ($1.restartable ? 1 : 0, $1.footprintBytes) }
    }
}
