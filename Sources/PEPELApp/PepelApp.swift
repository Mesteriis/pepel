import AppKit
import PEPELUI
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let model = AppModel.make()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app: no Dock icon until the dashboard window is open.
        NSApp.setActivationPolicy(.accessory)
        if let directory = Snapshotter.directory {
            Task {
                await Snapshotter.run(model: Self.model, directory: directory)
                NSApp.terminate(nil)
            }
            return
        }
        Self.model.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct PepelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            PopoverView { section in
                AppDelegate.model.open(section)
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
            .environment(AppDelegate.model)
        } label: {
            MenuBarLabel().environment(AppDelegate.model)
        }
        .menuBarExtraStyle(.window)

        Window("PEPEL", id: "dashboard") {
            DashboardView()
                .environment(AppDelegate.model)
                .onDisappear { NSApp.setActivationPolicy(.accessory) }
        }
        .defaultSize(width: 1180, height: 780)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}
