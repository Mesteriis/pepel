import Foundation
import PEPELCore

public struct MemoryConsumer: Codable, Sendable, Identifiable, Hashable {
    public var identity: ProcessIdentity
    public var name: String
    public var footprintBytes: Int64
    /// Footprint change across the observation history, when there is one.
    public var growthBytes: Int64?
    public var isDeveloperWorkload: Bool

    public var id: ProcessIdentity { identity }
}

public struct MemoryAdvice: Codable, Sendable {
    public var level: MemoryPressureLevel
    public var headline: String
    public var detail: String
    /// Abandoned-process candidates, largest process tree first. Never chosen by size alone.
    public var proposals: [ProcessAssessment]
    public var developerFootprintBytes: Int64
    public var topConsumers: [MemoryConsumer]
    /// Footprint held by the proposals. Terminating them frees at most this much, usually less.
    public var proposalFootprintBytes: Int64
}

/// Interprets memory telemetry the way macOS means it: pressure, compression and swap matter;
/// "free" RAM does not. Recovery is only ever proposed through abandoned developer processes.
public enum MemoryGuardian {
    public static func advise(
        telemetry: SystemTelemetry, processes: [ProcessSnapshot], assessments: [ProcessAssessment],
        history: [ProcessIdentity: [ProcessObservation]] = [:]
    ) -> MemoryAdvice {
        let developer = Set(assessments.map(\.process.identity))
        let consumers = processes.sorted { $0.footprintBytes > $1.footprintBytes }.prefix(12).map { p in
            MemoryConsumer(
                identity: p.identity, name: p.name, footprintBytes: p.footprintBytes,
                growthBytes: history[p.identity]?.first.map { p.footprintBytes - $0.footprintBytes },
                isDeveloperWorkload: developer.contains(p.identity))
        }
        // A candidate nested inside another candidate's tree is covered by its ancestor.
        let candidates = assessments.filter { $0.lifecycle.isAbandonedCandidate && !$0.eligibility.isNever }
            .sorted { $0.subtreeFootprintBytes > $1.subtreeFootprintBytes }
        let proposalBytes = candidates.reduce(Int64(0)) { $0 + $1.process.footprintBytes }
        let developerBytes = assessments.reduce(Int64(0)) { $0 + $1.process.footprintBytes }

        let swap = telemetry.swapUsedBytes > 0 ? " " + L("Swap in use: \(Bytes.format(telemetry.swapUsedBytes)).") : ""
        let headline: String
        var detail: String
        switch telemetry.pressure {
        case .normal:
            headline = L("Memory is healthy")
            detail = L("macOS reports normal memory pressure. \(Bytes.format(telemetry.cachedFileBytes)) of RAM is file cache, which is released on demand; low free memory is expected and not a problem.") + swap
        case .elevated:
            headline = L("Memory pressure is elevated")
            detail = L("macOS is compressing memory (\(Bytes.format(telemetry.compressedBytes)) compressed).") + swap + " " + L("The system is still responsive but has little headroom.")
        case .critical:
            headline = L("Memory pressure is critical")
            detail = L("macOS is compressing and swapping heavily (\(Bytes.format(telemetry.compressedBytes)) compressed).") + swap + " " + L("Applications may stall.")
        }
        if candidates.isEmpty {
            if telemetry.pressure != .normal {
                detail += " " + L("PEPEL found no abandoned developer processes to recover memory from; the largest consumers are listed for your judgement.")
            }
        } else {
            let n = candidates.count
            detail += " " + L("\(n) developer processes look abandoned, holding up to \(Bytes.format(proposalBytes)).")
        }
        return MemoryAdvice(
            level: telemetry.pressure, headline: headline, detail: detail, proposals: candidates,
            developerFootprintBytes: developerBytes, topConsumers: Array(consumers), proposalFootprintBytes: proposalBytes)
    }
}
