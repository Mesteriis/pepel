import AppKit
import Foundation
import PEPELEngine
import ServiceManagement
import UserNotifications

/// User notifications. Only available when running from an app bundle; a bare executable has
/// no bundle identifier and the notification centre refuses to work without one.
enum Notifier {
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static let memoryCategory = "PEPEL_MEMORY_PRESSURE"
    static let freeAction = "PEPEL_FREE_MEMORY"

    /// Receives the "Free memory" button of a memory pressure notification.
    private final class Responder: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
        var onFreeMemory: (@MainActor @Sendable () -> Void)?

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            guard response.actionIdentifier == Notifier.freeAction, let action = onFreeMemory else { return }
            await MainActor.run { action() }
        }
    }
    private static let responder = Responder()

    /// Registers the notification button. Call once at launch, from the main thread.
    static func configure(onFreeMemory: @escaping @MainActor @Sendable () -> Void) {
        guard available else { return }
        responder.onFreeMemory = onFreeMemory
        let center = UNUserNotificationCenter.current()
        center.delegate = responder
        let action = UNNotificationAction(identifier: freeAction, title: L("Free memory"), options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: memoryCategory, actions: [action], intentIdentifiers: [])])
    }

    /// Asks for permission the first time there is actually something to say, not at launch.
    static func post(id: String, title: String, body: String, category: String? = nil) {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            deliver(id: id, title: title, body: body, category: category)
        }
    }

    private static func deliver(id: String, title: String, body: String, category: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        // The attachment is moved by the system, so it gets its own copy of the image.
        if let source = Bundle.main.url(forResource: "NotificationIcon", withExtension: "png") {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("pepel-notification-\(UUID().uuidString).png")
            if (try? FileManager.default.copyItem(at: source, to: copy)) != nil,
                let attachment = try? UNNotificationAttachment(identifier: "icon", url: copy)
            {
                content.attachments = [attachment]
            }
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

/// Launch at login through the system login-item service. Requires an installed app bundle.
enum LoginItem {
    static var supported: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var isEnabled: Bool { supported && SMAppService.mainApp.status == .enabled }
    static var awaitsApproval: Bool { supported && SMAppService.mainApp.status == .requiresApproval }

    static var statusText: String {
        guard supported else { return L("Available when PEPEL runs from its app bundle.") }
        switch SMAppService.mainApp.status {
        case .enabled: return L("PEPEL starts when you log in.")
        case .requiresApproval: return L("Waiting for approval in System Settings › General › Login Items.")
        case .notFound: return L("Move PEPEL.app to Applications to enable this.")
        default: return L("PEPEL does not start at login.")
        }
    }

    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// Returns a message when the change could not be made.
    static func set(_ enabled: Bool) -> String? {
        guard supported else { return L("Launch at login needs PEPEL to run from its app bundle.") }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return L("Launch at login could not be changed: \(error.localizedDescription)")
        }
    }
}
