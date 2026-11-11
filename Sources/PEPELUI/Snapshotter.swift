import AppKit
import PEPELEngine
import SwiftUI

/// Renders the real views with the real engine state into PNG files. Used to produce
/// documentation screenshots without needing screen-recording permission:
/// `PEPEL_SNAPSHOT_DIR=docs/screenshots PEPEL.app/Contents/MacOS/PEPEL`.
@MainActor
public enum Snapshotter {
    public static var directory: String? { ProcessInfo.processInfo.environment["PEPEL_SNAPSHOT_DIR"] }

    public static func run(model: AppModel, directory: String) async {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        model.settings = await model.engine.currentSettings()
        // Two samples a moment apart so CPU activity is known.
        _ = await model.engine.refreshLive()
        try? await Task.sleep(for: .seconds(3))
        model.live = await model.engine.refreshLive()
        // Container memory is read in the background; give it a moment and sample again.
        try? await Task.sleep(for: .seconds(4))
        model.live = await model.engine.refreshLive()
        if await model.engine.storage == nil || ProcessInfo.processInfo.environment["PEPEL_SNAPSHOT_SCAN"] != nil {
            _ = await model.engine.scan()
        } else {
            await model.engine.reevaluateStorage()
        }
        model.storage = await model.engine.storage
        model.alerts = await model.engine.alerts()
        model.cadence = "normal"
        model.growth = model.engine.growth()
        model.audit = model.engine.store.audit(limit: 300)
        model.telemetryHistory = model.engine.store.telemetryHistory(since: Date().addingTimeInterval(-7 * 86_400))
        model.protections = model.engine.store.protections()
        model.leases = model.engine.store.leases()
        model.plan = await model.engine.cleanupPlan(initiator: .user)
        model.activity.plan = await model.engine.actionPlan()
        model.activity.restore = model.engine.restoreCenter()
        _ = await model.engine.selfUsage()
        try? await Task.sleep(for: .seconds(1))
        model.activity.selfUsage = await model.engine.selfUsage()
        // The disk map of a chosen folder, measured before the pictures are taken.
        if let mapRoot = ProcessInfo.processInfo.environment["PEPEL_SNAPSHOT_MAP"] {
            model.setDiskMapRoot(mapRoot)
            // PEPEL_SNAPSHOT_MAP_SECONDS stops the wait early, to picture the map while it fills in.
            let limit = ProcessInfo.processInfo.environment["PEPEL_SNAPSHOT_MAP_SECONDS"].flatMap(Double.init) ?? 1800
            let started = Date()
            while model.isMeasuringDiskMap, Date().timeIntervalSince(started) < limit { try? await Task.sleep(for: .milliseconds(200)) }
        }

        render(MenuBarLabel().padding(.horizontal, 10).padding(.vertical, 4).background(Color.black), model: model, size: nil, to: directory + "/menubar.png")
        render(PopoverView(openDashboard: { _ in }), model: model, size: nil, to: directory + "/popover.png")
        // PEPEL_SNAPSHOT_HEIGHT renders taller pages, to see what is below the first screen.
        let height = ProcessInfo.processInfo.environment["PEPEL_SNAPSHOT_HEIGHT"].flatMap(Double.init) ?? 780
        for section in DashboardSection.allCases {
            model.section = section
            render(DashboardView(), model: model, size: CGSize(width: 1180, height: height), to: directory + "/dashboard-\(section.rawValue).png")
        }
    }

    private static func render<V: View>(_ view: V, model: AppModel, size: CGSize?, to path: String) {
        let root = view.environment(model).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        let fitted = size ?? host.fittingSize
        host.frame = CGRect(origin: .zero, size: fitted)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        // Let lazy stacks and charts lay out before capturing.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        window.orderOut(nil)
    }
}
