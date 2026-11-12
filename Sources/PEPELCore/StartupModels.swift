import Foundation

/// Something macOS starts on its own: a launch agent of yours or of an installed app, a system
/// daemon an app installed, or a helper an app registered to run at login.
public struct StartupItem: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// `~/Library/LaunchAgents`: yours, started in your session.
        case userAgent
        /// `/Library/LaunchAgents`: installed by an app for every user, started in your session.
        case sharedAgent
        /// `/Library/LaunchDaemons`: runs as root, outside your session; changing it needs an administrator.
        case daemon
        /// Registered by an app from inside its bundle (Login Items in System Settings).
        case appHelper

        public var title: String {
            switch self {
            case .userAgent: L("Your launch agents")
            case .sharedAgent: L("Launch agents installed by apps")
            case .daemon: L("System daemons installed by apps")
            case .appHelper: L("Helpers apps registered to run at login")
            }
        }
    }

    public var label: String
    public var kind: Kind
    public var plistPath: String?
    /// The executable it starts, when known.
    public var program: String?
    /// The app it belongs to, or the executable's name.
    public var owner: String
    public var runAtLoad: Bool
    public var keepAlive: Bool
    /// `StartInterval` in seconds, or nil.
    public var interval: Int?
    /// Switched off with `launchctl disable` (or in System Settings).
    public var disabled: Bool
    /// Known to launchd in your session right now.
    public var loaded: Bool
    public var pid: Int32?
    public var lastExitStatus: Int32?
    /// Memory of the running process and everything it started.
    public var footprintBytes: Int64 = 0
    public var processCount = 0
    /// When PEPEL first saw it; nil for what was there before PEPEL looked.
    public var firstSeen: Date?

    public var id: String { kind.rawValue + ":" + label }
    public var isRunning: Bool { pid != nil }
    public var isApple: Bool { label.hasPrefix("com.apple.") }

    public init(
        label: String, kind: Kind, plistPath: String?, program: String?, owner: String, runAtLoad: Bool, keepAlive: Bool, interval: Int?, disabled: Bool,
        loaded: Bool, pid: Int32?, lastExitStatus: Int32?
    ) {
        self.label = label
        self.kind = kind
        self.plistPath = plistPath
        self.program = program
        self.owner = owner
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.interval = interval
        self.disabled = disabled
        self.loaded = loaded
        self.pid = pid
        self.lastExitStatus = lastExitStatus
    }

    /// Why PEPEL will not switch it on or off, or nil when it can.
    public var managementRefusal: String? {
        if isApple { return L("It is part of macOS.") }
        if label.hasPrefix("dev.pepel.") || label.hasPrefix("application.dev.pepel.") { return L("It is PEPEL itself; use Settings › Start PEPEL when you log in.") }
        switch kind {
        case .daemon: return L("A system daemon runs as root; switching it needs an administrator, so PEPEL only shows it.")
        case .appHelper: return L("The app manages it; switch it in System Settings › General › Login Items.")
        case .userAgent, .sharedAgent: return plistPath == nil ? L("Its property list was not found.") : nil
        }
    }

    /// How it is started, in a few words.
    public var schedule: String {
        if keepAlive { return L("always kept running") }
        if let interval { return L("every \(max(1, interval / 60)) min") }
        if runAtLoad { return L("at login") }
        return L("on demand")
    }
}
