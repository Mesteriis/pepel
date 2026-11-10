import CoreGraphics
import Darwin
import Foundation
import IOKit.ps
import PEPELCore

/// Reads disk, memory, swap and power state through public system interfaces. No privileges needed.
public struct TelemetryReader: Sendable {
    public init() {}

    public func read(volumePath: String = NSHomeDirectory()) -> SystemTelemetry {
        var t = SystemTelemetry()
        readDisk(volumePath, into: &t)
        readMemory(into: &t)
        t.pressure = Self.pressureLevel()
        readSwap(into: &t)
        t.onBattery = Self.onBattery()
        return t
    }

    private func readDisk(_ path: String, into t: inout SystemTelemetry) {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys) else { return }
        t.diskTotalBytes = Int64(values.volumeTotalCapacity ?? 0)
        t.diskFreeBytes = Int64(values.volumeAvailableCapacity ?? 0)
        t.diskAvailableBytes = values.volumeAvailableCapacityForImportantUsage ?? t.diskFreeBytes
    }

    private func readMemory(into t: inout SystemTelemetry) {
        t.memoryTotalBytes = Int64(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let page = Int64(getpagesize())
        let purgeable = Int64(stats.purgeable_count)
        t.appMemoryBytes = max(0, Int64(stats.internal_page_count) - purgeable) * page
        t.wiredBytes = Int64(stats.wire_count) * page
        t.compressedBytes = Int64(stats.compressor_page_count) * page
        t.cachedFileBytes = (Int64(stats.external_page_count) + purgeable) * page
        t.freeBytes = max(0, Int64(stats.free_count) - Int64(stats.speculative_count)) * page
    }

    private func readSwap(into t: inout SystemTelemetry) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return }
        t.swapUsedBytes = Int64(usage.xsu_used)
        t.swapTotalBytes = Int64(usage.xsu_total)
    }

    /// The kernel's own pressure level: 1 normal, 2 warning, 4 critical.
    public static func pressureLevel() -> MemoryPressureLevel {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        switch level {
        case 4: return .critical
        case 2: return .elevated
        default: return .normal
        }
    }

    public static func onBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    /// Seconds since the last keyboard or pointer event in this login session.
    public static func userIdleSeconds() -> TimeInterval {
        guard let anyEvent = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }
}
