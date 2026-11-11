import AppKit
import Observation
import PEPELEngine
import PEPELUI
import SwiftUI

/// The menu bar item, owned directly through AppKit.
///
/// SwiftUI's `MenuBarExtra` gives the item no stable autosave name, so macOS never remembered
/// where the user dragged it and put it back at the far left on every launch — which is exactly
/// the area menu bar managers such as Hidden Bar collapse. A named `NSStatusItem` keeps its place.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    /// Changing this name makes macOS treat the item as new and honour the seeded position again;
    /// a position the user (or an earlier build) stored under the old name no longer applies.
    private static let autosaveName = "PEPELStatus"
    private let model: AppModel
    private var item: NSStatusItem
    private let popover = NSPopover()
    private let openDashboard: (DashboardSection) -> Void

    init(model: AppModel, openDashboard: @escaping (DashboardSection) -> Void) {
        self.model = model
        self.openDashboard = openDashboard
        // First launch only: start among the always-visible icons on the right (the value is the
        // distance from the right edge of the menu bar). After that the user's own placement wins.
        let positionKey = "NSStatusItem Preferred Position \(Self.autosaveName)"
        // Seeded once. macOS only reads this for an item it has not placed before; afterwards the
        // user's own placement wins. 200 lies between the system's Spotlight (188) and Battery
        // (220) items, to the right of Wi-Fi and of any menu bar manager's separator.
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(200.0, forKey: positionKey)
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveName
        item.behavior = []
        item.isVisible = true
        super.init()

        configureButton()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(
            rootView: PopoverView { [weak self] section in
                self?.popover.performClose(nil)
                self?.openDashboard(section)
            }
            .environment(model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        observe()
        // Polled rather than notification-driven: when a menu bar manager shoves the item
        // off-screen, the status window does not reliably post a move notification.
        placementTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recordPlacementIfChanged() }
        }
    }

    private var placementTimer: Timer?
    private var lastPlacement = ""
    private func configureButton() {
        guard let button = item.button else { return }
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.target = self
        button.action = #selector(toggle)
    }

    /// Records where the item actually is in `menubar-placement.log` in PEPEL's support
    /// directory whenever that changes, so a "the icon is missing" report can be diagnosed from facts.
    private var unplacedSeconds = 0

    private func recordPlacementIfChanged() {
        // A zero-height frame means macOS has not given the item a place in the menu bar.
        let placed = (item.button?.window?.frame.height ?? 0) > 0
        unplacedSeconds = placed ? 0 : unplacedSeconds + 1
        if placed {
            model.menuBarItem(placed: true)
        } else if unplacedSeconds == 12 {
            model.menuBarItem(placed: false)
            lastPlacement = ""  // so the log line below records the notice
        }
        var state: String
        if let window = item.button?.window {
            let screen = window.screen
            let onAnyScreen = NSScreen.screens.contains { $0.frame.intersects(window.frame) }
            state = "frame=\(NSStringFromRect(window.frame)) screen=\(screen?.localizedName ?? "nil")"
            state += " fromRight=\(Int((screen?.frame.maxX ?? 0) - window.frame.maxX)) onAnyScreen=\(onAnyScreen)"
            state += " occlusionVisible=\(window.occlusionState.contains(.visible)) windowVisible=\(window.isVisible) isVisible=\(item.isVisible)"
            state += " saved=\(UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position \(Self.autosaveName)").map { "\($0)" } ?? "none")"
        } else {
            state = "no window; isVisible=\(item.isVisible)"
        }
        if let notice = model.menuBarNotice { state += " notice=\"\(notice.prefix(60))…\"" }
        guard state != lastPlacement else { return }
        lastPlacement = state
        let path = model.engine.paths.supportDirectory + "/menubar-placement.log"
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(state)"
        try? (existing.split(separator: "\n").suffix(80).joined(separator: "\n") + "\n" + line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Redraws the item whenever the state it shows changes.
    private func observe() {
        withObservationTracking {
            guard let button = item.button else { return }
            button.image = MenuBarContent.image(model)
            let title = MenuBarContent.title(model)
            button.title = title.isEmpty ? "" : " " + title
            button.setAccessibilityLabel(MenuBarContent.accessibilityLabel(model))
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    /// Opens the popover with the Free memory plan ready (the global shortcut).
    func showFreeMemory() {
        model.prepareReclaim()
        guard let button = item.button, let window = button.window, window.frame.height > 0 else {
            // The icon is not on screen (hidden by a menu bar manager): use the dashboard instead.
            openDashboard(.memory)
            return
        }
        if !popover.isShown {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel.make()
    private var statusItem: StatusItemController?
    private var dashboard: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app: no Dock icon until the dashboard window is open.
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = makeMenu()
        if let directory = Snapshotter.directory {
            Task {
                await Snapshotter.run(model: model, directory: directory)
                NSApp.terminate(nil)
            }
            return
        }
        statusItem = StatusItemController(model: model) { [weak self] section in self?.showDashboard(section) }
        model.start()
        followHotKeySetting()
    }

    private let hotKey = HotKey()

    /// Registers or releases the global shortcut whenever the setting changes.
    private func followHotKeySetting() {
        withObservationTracking {
            if model.settings.freeMemoryHotkey {
                _ = hotKey.register { [weak self] in self?.statusItem?.showFreeMemory() }
            } else {
                hotKey.unregister()
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.followHotKeySetting() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Nothing may stay suspended once PEPEL is not there to wake it.
    func applicationWillTerminate(_ notification: Notification) { model.wakeEverything(reason: "PEPEL quit") }

    /// Opening the app again while it runs shows the dashboard. This is the way in when the
    /// menu bar icon is hidden by a menu bar manager.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard(.overview)
        return false
    }

    private func showDashboard(_ section: DashboardSection) {
        model.open(section)
        if dashboard == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "PEPEL"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 980, height: 620)
            window.contentViewController = NSHostingController(rootView: DashboardView().environment(model))
            window.setContentSize(NSSize(width: 1180, height: 780))
            window.setFrameAutosaveName("PEPELDashboard")
            if !window.setFrameUsingName("PEPELDashboard") { window.center() }
            window.delegate = self
            dashboard = window
        }
        NSApp.setActivationPolicy(.regular)
        dashboard?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Without a main menu the dashboard would have no ⌘Q, ⌘W or copy and paste.
    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: L("Hide PEPEL"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: L("Quit PEPEL"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: L("Edit"))
        edit.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: L("Window"))
        window.addItem(withTitle: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        // "PEPEL" is the product name and stays as it is.
        for (title, menu) in [("PEPEL", app), (L("Edit"), edit), (L("Window"), window)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        return main
    }
}

@main
enum PepelMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
