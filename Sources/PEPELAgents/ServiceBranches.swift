import Foundation
import PEPELCore
import PEPELProcesses

/// What an agent's long-lived server (`codex app-server` and the like) has started and kept.
///
/// Such a server runs for as long as its application does and starts tool servers and shells for
/// each conversation. When a conversation ends they often stay. PEPEL cannot see conversations,
/// so it uses what it can observe: the same program running in several copies under one server,
/// where every copy but the newest has been idle for a long time. Those older copies are
/// candidates; a program that runs only once is never one.
public enum ServiceBranches {
    public static func find(
        processes: [ProcessSnapshot], services: [AgentSession], history: [ProcessIdentity: [ProcessObservation]], idleAfter: TimeInterval, now: Date
    ) -> [ServiceBranch] {
        let tree = ProcessTree(processes)
        var result: [ServiceBranch] = []
        for service in services where service.isService {
            guard let server = tree.process(service.root) else { continue }
            var branches: [ServiceBranch] = []
            for child in tree.children(of: server) {
                let members = [child] + tree.descendants(of: child)
                // Idle only when every process in the branch was watched for the whole period and
                // the branch as a whole used almost no CPU in it.
                var watched = TimeInterval.infinity
                var cpuSeconds = 0.0
                for member in members {
                    guard let first = history[member.identity]?.first, member.cpuTimeNs >= first.cpuTimeNs else {
                        watched = 0
                        break
                    }
                    watched = min(watched, now.timeIntervalSince(first.timestamp))
                    cpuSeconds += Double(member.cpuTimeNs - first.cpuTimeNs) / 1e9
                }
                let idle = watched >= idleAfter && watched.isFinite && cpuSeconds < watched * 0.005
                branches.append(
                    ServiceBranch(
                        root: child.identity, serviceRoot: service.root, serviceName: service.kind.displayName, signature: AgentDetector.signature(child),
                        name: child.name, processCount: members.count, footprintBytes: members.reduce(0) { $0 + $1.footprintBytes },
                        startedAt: child.identity.startDate, idleFor: idle ? watched : nil))
            }
            // Within one server: copies of the same program, newest last.
            for (_, group) in Dictionary(grouping: branches.indices, by: { branches[$0].signature }) {
                let newest = group.max { branches[$0].startedAt < branches[$1].startedAt }
                for index in group {
                    branches[index].copies = group.count
                    branches[index].isNewestCopy = index == newest
                }
            }
            result += branches
        }
        return result.sorted { ($0.isStale ? 1 : 0, $0.footprintBytes) > ($1.isStale ? 1 : 0, $1.footprintBytes) }
    }
}
