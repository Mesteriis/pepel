import Darwin
import Foundation
import PEPELCore

public protocol ProcessSource: Sendable {
    func snapshot() -> [ProcessSnapshot]
    /// TCP ports a process listens on. Queried only for processes where it matters.
    func listeningPorts(of pid: Int32) -> [UInt16]
    /// Identity currently behind a PID, or nil when the process is gone.
    func identity(of pid: Int32) -> ProcessIdentity?
}

/// Enumerates processes with libproc and sysctl. Without elevated rights the kernel only exposes
/// details (arguments, working directory, memory) for the current user's processes; others are skipped.
public struct ProcessEnumerator: ProcessSource {
    public var includeOtherUsers = false

    public init() {}

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    public func snapshot() -> [ProcessSnapshot] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        let me = getuid()
        var result: [ProcessSnapshot] = []
        result.reserveCapacity(Int(filled))
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            guard let p = Self.describe(pid), includeOtherUsers || p.uid == me else { continue }
            result.append(p)
        }
        return result
    }

    public static func describe(_ pid: pid_t) -> ProcessSnapshot? {
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { return nil }

        let start = UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec)
        let nameLength = MemoryLayout.size(ofValue: bsd.pbi_name)
        let commLength = MemoryLayout.size(ofValue: bsd.pbi_comm)
        var name = withUnsafePointer(to: &bsd.pbi_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: nameLength) { String(cString: $0) }
        }
        if name.isEmpty {
            name = withUnsafePointer(to: &bsd.pbi_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: commLength) { String(cString: $0) }
            }
        }

        var snapshot = ProcessSnapshot(
            identity: ProcessIdentity(pid: pid, startTime: start), parentPID: Int32(bsd.pbi_ppid),
            processGroup: Int32(bsd.pbi_pgid), uid: bsd.pbi_uid, name: name)
        snapshot.state =
            switch Int32(bsd.pbi_status) {
            case SRUN: .running
            case SSLEEP: .sleeping
            case SSTOP: .stopped
            case SZOMB: .zombie
            case SIDL: .idle
            default: .unknown
            }
        snapshot.hasControllingTerminal = bsd.e_tdev != UInt32.max && bsd.e_tdev != 0

        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
            snapshot.executablePath = pathBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }

        var vnode = proc_vnodepathinfo()
        let vnodeSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, vnodeSize) == vnodeSize {
            let cwd = withUnsafePointer(to: &vnode.pvi_cdir.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if !cwd.isEmpty { snapshot.workingDirectory = cwd }
        }

        var usage = rusage_info_v4()
        let usageResult = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        if usageResult == 0 {
            snapshot.residentBytes = Int64(usage.ri_resident_size)
            snapshot.footprintBytes = Int64(usage.ri_phys_footprint)
            let ticks = usage.ri_user_time &+ usage.ri_system_time
            snapshot.cpuTimeNs = ticks &* timebase.numer / timebase.denom
        }

        snapshot.arguments = arguments(of: pid)
        // The kernel truncates process names; prefer the full executable name when it extends it.
        if let path = snapshot.executablePath {
            let base = (path as NSString).lastPathComponent
            if snapshot.name.isEmpty || (base.count > snapshot.name.count && base.hasPrefix(snapshot.name)) { snapshot.name = base }
        }
        return snapshot
    }

    /// Reads the argument vector only. The environment block that follows it in the kernel buffer
    /// is never parsed, so secrets passed through the environment are not touched.
    public static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return [] }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path and the NUL padding after it.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var args: [String] = []
        while index < size, args.count < Int(argc) {
            let begin = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[begin..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    public func listeningPorts(of pid: Int32) -> [UInt16] { Self.listeningPorts(of: pid) }
    public func identity(of pid: Int32) -> ProcessIdentity? { Self.identity(of: pid) }

    /// TCP ports the process is listening on.
    public static func listeningPorts(of pid: pid_t) -> [UInt16] {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard used > 0 else { return [] }
        var ports = Set<UInt16>()
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize else { continue }
            guard info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            let port = UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport).byteSwapped
            if port != 0 { ports.insert(port) }
        }
        return ports.sorted()
    }

    /// Current identity of a PID, or nil when no such process exists any more.
    public static func identity(of pid: pid_t) -> ProcessIdentity? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        if Int32(bsd.pbi_status) == SZOMB { return nil }
        return ProcessIdentity(pid: pid, startTime: UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec))
    }
}
