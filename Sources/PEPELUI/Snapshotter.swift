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
        menuBarSheet(model, to: directory + "/menubar-modes.png")
        render(PopoverView(openDashboard: { _ in }), model: model, size: nil, to: directory + "/popover.png")
        // PEPEL_SNAPSHOT_HEIGHT renders taller pages, to see what is below the first screen.
        let height = ProcessInfo.processInfo.environment["PEPEL_SNAPSHOT_HEIGHT"].flatMap(Double.init) ?? 780
        for section in DashboardSection.allCases {
            model.section = section
            render(DashboardView(), model: model, size: CGSize(width: 1180, height: height), to: directory + "/dashboard-\(section.rawValue).png")
        }
    }

    /// Every menu bar mode on a dark and a light menu bar, at 2x, for choosing between them.
    private static func menuBarSheet(_ model: AppModel, to path: String) {
        var reading = model.menuBarReading
        if reading.history.count < 2 {
            // A believable last few minutes when the snapshot has only one reading.
            let now = reading.memoryTotal > 0 ? Double(reading.memoryUsed) / Double(reading.memoryTotal) : 0.6
            reading.history = (0..<48).map { i in min(0.98, max(0.05, now - 0.08 + 0.06 * sin(Double(i) / 5) + Double(i) * 0.0015)) }
        }
        let modes: [MenuBarMode] = [.memoryGraphAndDisk, .memoryGraph, .memoryAndDisk, .reclaimable]
        let rowHeight: CGFloat = 30, width: CGFloat = 330, scale: CGFloat = 2
        let size = NSSize(width: width * 2 + 30, height: rowHeight * CGFloat(modes.count) + 10)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        for (column, appearance) in [NSAppearance.Name.darkAqua, .aqua].enumerated() {
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                let x = 10 + CGFloat(column) * (width + 10)
                (column == 0 ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(x: x, y: 5, width: width, height: size.height - 10).fill()
                for (row, mode) in modes.enumerated() {
                    let y = size.height - 5 - rowHeight * CGFloat(row + 1) + (rowHeight - 22) / 2
                    var mine = reading
                    mine.text = mode == .reclaimable ? model.reclaimableText : nil
                    let image = MenuBarRenderer.image(mode, mine) ?? AppImages.menuBar(status: mine.status)
                    image.draw(in: NSRect(x: x + 12, y: y, width: image.size.width, height: image.size.height))
                    if mode == .reclaimable, let text = mine.text {
                        (" " + text as NSString).draw(
                            at: NSPoint(x: x + 12 + image.size.width, y: y + 3),
                            withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.labelColor])
                    }
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
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
