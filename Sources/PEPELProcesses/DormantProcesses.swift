import Foundation
import PEPELCore

/// Finds processes that live almost entirely in swap: a lot of memory charged to them, hardly
/// any of it in RAM, and no CPU use. They cost little RAM, but they keep swap and the
/// compressor full, and they are usually something started long ago and forgotten.
public enum DormantProcesses {
    public static let minimumFootprint: Int64 = 500 * Bytes.mb
    /// At most this share of the footprint may be in RAM.
    public static let maximumResidentShare = 0.15

    static func isSystem(_ path: String) -> Bool {
        ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }

    /// - Parameters:
    ///   - excluded: processes with rules of their own (agent sessions and what they started,
    ///     the virtual machine, PEPEL and what it runs in).
    public static func find(
        processes: [ProcessSnapshot], assessments: [ProcessAssessment], history: [ProcessIdentity: [ProcessObservation]], excluded: Set<ProcessIdentity>,
        attributor: (any ProjectAttributing)?, currentUID: UInt32, now: Date
    ) -> [ProcessAssessment] {
        let assessed = Dictionary(assessments.map { ($0.process.identity, $0) }, uniquingKeysWith: { first, _ in first })
        let tree = ProcessTree(processes)
        var result: [ProcessAssessment] = []
        for p in processes where p.uid == currentUID && !excluded.contains(p.identity) {
            guard p.footprintBytes >= minimumFootprint, Double(p.residentBytes) <= Double(p.footprintBytes) * maximumResidentShare else { continue }
            guard let path = p.executablePath, !isSystem(path), !path.contains(".app/Contents/") else { continue }
            // Over everything PEPEL has seen of it: a process that works now and then is not dormant.
            var percent: Double?
            if let first = history[p.identity]?.first, now.timeIntervalSince(first.timestamp) >= 600, p.cpuTimeNs >= first.cpuTimeNs {
                percent = Double(p.cpuTimeNs - first.cpuTimeNs) / 1e9 / now.timeIntervalSince(first.timestamp) * 100
                if percent! >= 1 { continue }
            }
            let descendants = tree.descendants(of: p)
            let known = assessed[p.identity]
            var evidence = [
                L("\(Bytes.format(p.footprintBytes)) is charged to it and \(Bytes.format(p.residentBytes)) of that is in RAM; the rest is compressed or in swap."),
                L("Started \(TimeFormat.ago(p.identity.startDate))."),
            ]
            evidence.append(
                percent.map {
                    let share = String(format: "%.2f%%", $0)
                    let watched = TimeFormat.age(now.timeIntervalSince(history[p.identity]!.first!.timestamp))
                    return L("Used \(share) of a core over the \(watched) PEPEL has watched it.")
                } ?? L("PEPEL has not watched it long enough to say how busy it is."))
            if !p.listeningPorts.isEmpty { evidence.append(L("It listens on port \(p.listeningPorts.map(String.init).joined(separator: ", ")); something may still connect to it.")) }
            // A protection or another "never" established elsewhere stands.
            var eligibility = TerminationEligibility.approvalRequired(warning: L("PEPEL does not know what this process is for; it only sees that nothing has touched it."))
            if let known, case .never = known.eligibility { eligibility = known.eligibility }
            let attribution = p.workingDirectory.flatMap { attributor?.attribute(path: $0) }
            var assessment = ProcessAssessment(
                process: p, role: known?.role ?? RoleClassifier.role(of: p, attributor: attributor), lifecycle: known?.lifecycle ?? .abandonedSubprocess,
                confidence: .probable, projectID: known?.projectID ?? attribution?.projectID, projectConfidence: known?.projectConfidence ?? (attribution == nil ? .unknown : .verified),
                evidence: evidence, eligibility: eligibility, descendantCount: descendants.count,
                subtreeFootprintBytes: descendants.reduce(p.footprintBytes) { $0 + $1.footprintBytes })
            assessment.cpuPercent = percent
            assessment.dormant = true
            result.append(assessment)
        }
        return result.sorted { $0.subtreeFootprintBytes > $1.subtreeFootprintBytes }
    }
}
