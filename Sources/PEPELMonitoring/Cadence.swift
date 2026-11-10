import Foundation
import PEPELCore

public struct MonitorConditions: Sendable, Equatable {
    public var paused = false
    public var mode: MonitoringMode = .notifyOnly
    public var onBattery = false
    public var batteryAware = true
    public var userIdleSeconds: TimeInterval = 0
    public var pressure: MemoryPressureLevel = .normal
    public var activeBuilds = 0
    public var inQuietHours = false
    public var diskLow = false
    /// Seconds since the previous full scan finished; nil when none ran yet.
    public var sinceLastFullScan: TimeInterval?
    /// True when watched directories reported changes since the previous scan.
    public var changesPending = true

    public init() {}
}

public struct MonitorCadence: Sendable, Equatable {
    /// Seconds until the next light sample (telemetry + process table).
    public var lightInterval: TimeInterval
    /// True when a full storage scan should start now.
    public var runFullScan: Bool
    public var reason: String
}

/// Decides how hard the monitor works. Pure, so the adaptive behaviour is testable.
public enum CadencePolicy {
    public static let fullScanInterval: TimeInterval = 30 * 60
    /// A scan postponed by active builds runs anyway after this long.
    public static let maxDeferral: TimeInterval = 3 * 3600

    public static func cadence(for c: MonitorConditions) -> MonitorCadence {
        if c.paused {
            return MonitorCadence(lightInterval: 60, runFullScan: false, reason: "paused")
        }
        var light: TimeInterval = 10
        var why = "normal"
        if c.pressure == .critical {
            light = 4
            why = "critical memory pressure"
        } else if c.pressure == .elevated {
            light = 6
            why = "elevated memory pressure"
        } else if c.onBattery && c.batteryAware {
            light = 30
            why = "on battery"
        } else if c.userIdleSeconds > 600 && c.activeBuilds == 0 {
            light = 45
            why = "workstation idle"
        }

        guard c.mode != .manual else {
            return MonitorCadence(lightInterval: light, runFullScan: false, reason: why + ", manual mode")
        }

        var interval = fullScanInterval
        if c.onBattery && c.batteryAware { interval *= 4 }
        if c.inQuietHours { interval *= 4 }
        if c.diskLow { interval = min(interval, 10 * 60) }

        guard let since = c.sinceLastFullScan else {
            return MonitorCadence(lightInterval: light, runFullScan: true, reason: why + ", first scan")
        }
        guard since >= interval else {
            return MonitorCadence(lightInterval: light, runFullScan: false, reason: why)
        }
        if !c.changesPending && !c.diskLow {
            return MonitorCadence(lightInterval: light, runFullScan: false, reason: why + ", no filesystem changes")
        }
        if c.activeBuilds > 0 && since < maxDeferral && !c.diskLow {
            return MonitorCadence(lightInterval: light, runFullScan: false, reason: why + ", scan deferred during active builds")
        }
        return MonitorCadence(lightInterval: light, runFullScan: true, reason: why + ", scan due")
    }
}
