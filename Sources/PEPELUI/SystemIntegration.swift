import AppKit
import Foundation
import ServiceManagement
import UserNotifications

/// User notifications. Only available when running from an app bundle; a bare executable has
/// no bundle identifier and the notification centre refuses to work without one.
enum Notifier {
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    /// Asks for permission the first time there is actually something to say, not at launch.
    static func post(id: String, title: String, body: String) {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            deliver(id: id, title: title, body: body)
        }
    }

    private static func deliver(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
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

    static var statusText: String {
        guard supported else { return "Available when PEPEL runs from its app bundle." }
        switch SMAppService.mainApp.status {
        case .enabled: return "PEPEL starts when you log in."
        case .requiresApproval: return "Waiting for approval in System Settings › General › Login Items."
        case .notFound: return "Move PEPEL.app to Applications to enable this."
        default: return "PEPEL does not start at login."
        }
    }

    /// Returns a message when the change could not be made.
    static func set(_ enabled: Bool) -> String? {
        guard supported else { return "Launch at login needs PEPEL to run from its app bundle." }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return "Launch at login could not be changed: \(error.localizedDescription)"
        }
    }
}
