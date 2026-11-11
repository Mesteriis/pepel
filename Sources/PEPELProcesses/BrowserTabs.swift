import Foundation
import PEPELCore

/// Finds the processes that render tabs in Chromium-based browsers.
///
/// A browser gives every tab (or group of tabs of one site) its own renderer process. Ending an
/// idle one unloads those tabs: they stay in the tab strip and load again when visited, as after
/// the browser's own memory saver. What is lost is what a reload loses: unsent form input and
/// the scroll position. The process table does not say which tab is on screen, so only a
/// renderer that has used almost no CPU for the whole period counts as idle; the tab being
/// looked at, or one playing something, is busy.
public enum BrowserTabs {
    /// Browsers only. Electron applications use the same process layout, but there a renderer
    /// is the application's own window.
    public static let browsers: [String] = [
        "Google Chrome", "Google Chrome Beta", "Google Chrome Canary", "Chromium", "Dia", "Arc", "Microsoft Edge", "Brave Browser", "Vivaldi", "Opera",
        "Yandex",
    ]

    static func browser(of p: ProcessSnapshot) -> (name: String, bundlePath: String)? {
        guard let path = p.executablePath, let range = path.range(of: ".app/") else { return nil }
        let bundle = String(path[..<range.lowerBound]) + ".app"
        let name = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
        return browsers.contains(name) ? (name, bundle) : nil
    }

    public static func isTabRenderer(_ p: ProcessSnapshot) -> Bool {
        browser(of: p) != nil && p.arguments.contains("--type=renderer") && !p.arguments.contains("--extension-process")
    }

    public static func find(
        processes: [ProcessSnapshot], history: [ProcessIdentity: [ProcessObservation]], idleAfter: TimeInterval, minimumFootprint: Int64 = 150 * Bytes.mb, now: Date
    ) -> [BrowserTab] {
        processes.compactMap { p -> BrowserTab? in
            guard isTabRenderer(p), let browser = browser(of: p), p.footprintBytes >= minimumFootprint else { return nil }
            var idle: TimeInterval?
            if let first = history[p.identity]?.first, p.cpuTimeNs >= first.cpuTimeNs {
                let watched = now.timeIntervalSince(first.timestamp)
                if watched >= idleAfter, Double(p.cpuTimeNs - first.cpuTimeNs) / 1e9 < watched * 0.005 { idle = watched }
            }
            return BrowserTab(root: p.identity, browser: browser.name, bundlePath: browser.bundlePath, footprintBytes: p.footprintBytes, residentBytes: p.residentBytes, idleFor: idle)
        }
        .sorted { ($0.idleFor != nil ? 1 : 0, $0.footprintBytes) > ($1.idleFor != nil ? 1 : 0, $1.footprintBytes) }
    }
}
