import Foundation

/// One reading of the memory journal: what the Mac's memory looked like at a moment, who held
/// it, what every agent session and browser was doing, and what PEPEL did since the reading
/// before. Written every five minutes so that questions about memory can later be answered
/// from what actually happened rather than from one look at the present.
///
/// Names of applications, projects and agents are recorded; command lines and paths are not.
public struct JournalSample: Codable, Sendable, Hashable {
    public struct Owner: Codable, Sendable, Hashable {
        public var name: String
        public var kind: String
        public var bytes: Int64
        public var resident: Int64
        public var procs: Int

        public init(name: String, kind: String, bytes: Int64, resident: Int64, procs: Int) {
            self.name = name
            self.kind = kind
            self.bytes = bytes
            self.resident = resident
            self.procs = procs
        }
    }

    public struct Agent: Codable, Sendable, Hashable {
        public var agent: String
        public var project: String?
        public var pid: Int32
        /// working, idle, sleeping; "server" for an application's long-lived server.
        public var state: String
        public var suspended: Bool
        public var bytes: Int64
        public var resident: Int64
        public var procs: Int
        public var quietMinutes: Int?
        public var ageMinutes: Int

        public init(agent: String, project: String?, pid: Int32, state: String, suspended: Bool, bytes: Int64, resident: Int64, procs: Int, quietMinutes: Int?, ageMinutes: Int) {
            self.agent = agent
            self.project = project
            self.pid = pid
            self.state = state
            self.suspended = suspended
            self.bytes = bytes
            self.resident = resident
            self.procs = procs
            self.quietMinutes = quietMinutes
            self.ageMinutes = ageMinutes
        }
    }

    public struct Browser: Codable, Sendable, Hashable {
        public var name: String
        public var bytes: Int64
        public var resident: Int64
        public var procs: Int
        /// Tab processes of 150 MB or more, how many of them idle, and what the idle ones hold.
        public var tabs: Int
        public var idleTabs: Int
        public var idleBytes: Int64
        public var largestTab: Int64

        public init(name: String, bytes: Int64, resident: Int64, procs: Int, tabs: Int, idleTabs: Int, idleBytes: Int64, largestTab: Int64) {
            self.name = name
            self.bytes = bytes
            self.resident = resident
            self.procs = procs
            self.tabs = tabs
            self.idleTabs = idleTabs
            self.idleBytes = idleBytes
            self.largestTab = largestTab
        }
    }

    public struct Action: Codable, Sendable, Hashable {
        public var at: Date
        public var by: String
        public var subject: String
        public var outcome: String
        public var bytes: Int64

        public init(at: Date, by: String, subject: String, outcome: String, bytes: Int64) {
            self.at = at
            self.by = by
            self.subject = subject
            self.outcome = outcome
            self.bytes = bytes
        }
    }

    public var ts: Date
    public var total: Int64
    public var used: Int64
    public var app: Int64
    public var wired: Int64
    public var compressed: Int64
    public var cached: Int64
    public var free: Int64
    public var swap: Int64
    public var pressure: String
    public var owners: [Owner]
    public var agents: [Agent]
    public var browsers: [Browser]
    /// How many things PEPEL saw that could be acted on, by kind.
    public var counts: [String: Int]
    public var forecastMinutes: Int?
    public var actions: [Action]

    public init(
        ts: Date, total: Int64, used: Int64, app: Int64, wired: Int64, compressed: Int64, cached: Int64, free: Int64, swap: Int64, pressure: String,
        owners: [Owner], agents: [Agent], browsers: [Browser], counts: [String: Int], forecastMinutes: Int?, actions: [Action]
    ) {
        self.ts = ts
        self.total = total
        self.used = used
        self.app = app
        self.wired = wired
        self.compressed = compressed
        self.cached = cached
        self.free = free
        self.swap = swap
        self.pressure = pressure
        self.owners = owners
        self.agents = agents
        self.browsers = browsers
        self.counts = counts
        self.forecastMinutes = forecastMinutes
        self.actions = actions
    }
}

/// What a stretch of the journal says, in numbers a person can read.
public struct JournalDigest: Codable, Sendable, Hashable {
    public struct Range: Codable, Sendable, Hashable {
        public var min: Int64
        public var average: Int64
        public var max: Int64

        public init(min: Int64, average: Int64, max: Int64) {
            self.min = min
            self.average = average
            self.max = max
        }

        static func of(_ values: [Int64]) -> Range {
            guard let low = values.min(), let high = values.max() else { return Range(min: 0, average: 0, max: 0) }
            return Range(min: low, average: values.reduce(0, +) / Int64(values.count), max: high)
        }
    }

    public struct Holder: Codable, Sendable, Hashable, Identifiable {
        public var name: String
        public var kind: String
        public var memory: Range
        /// Share of readings in which it was present.
        public var presence: Double
        /// Last reading minus first reading in which it appeared.
        public var change: Int64
        public var id: String { kind + ":" + name }
    }

    public var from: Date?
    public var to: Date?
    public var samples: Int
    public var used: Range
    public var wired: Range
    public var compressed: Range
    public var swap: Range
    /// Share of readings at each pressure level.
    public var pressure: [String: Double]
    public var owners: [Holder]
    /// Per agent and project: how much its sessions held together.
    public var agents: [Holder]
    public var agentSessions: Range
    public var agentMemory: Range
    /// Share of agent-session readings in each state.
    public var agentStates: [String: Double]
    public var browsers: [Holder]
    public var browserTabs: Range
    public var idleTabMemory: Range
    public var actions: [String: Int]
    public var forecasts: Int

    public static func make(_ samples: [JournalSample]) -> JournalDigest {
        let sorted = samples.sorted { $0.ts < $1.ts }
        let count = max(1, sorted.count)
        func share(_ values: [String]) -> [String: Double] {
            Dictionary(grouping: values, by: { $0 }).mapValues { Double($0.count) / Double(max(1, values.count)) }
        }
        func holders(_ rows: [[(name: String, kind: String, bytes: Int64)]]) -> [Holder] {
            var series: [String: (name: String, kind: String, values: [Int64])] = [:]
            for row in rows {
                // Several sessions of one agent in one project count together within a reading.
                var totals: [String: (name: String, kind: String, bytes: Int64)] = [:]
                for item in row {
                    let key = item.kind + ":" + item.name
                    totals[key] = (item.name, item.kind, (totals[key]?.bytes ?? 0) + item.bytes)
                }
                for (key, item) in totals { series[key, default: (item.name, item.kind, [])].values.append(item.bytes) }
            }
            return series.values
                .map { Holder(name: $0.name, kind: $0.kind, memory: .of($0.values), presence: Double($0.values.count) / Double(count), change: ($0.values.last ?? 0) - ($0.values.first ?? 0)) }
                .sorted { $0.memory.average * Int64($0.presence * 1000) > $1.memory.average * Int64($1.presence * 1000) }
        }
        let sessions = sorted.map { $0.agents.filter { $0.state != "server" } }
        return JournalDigest(
            from: sorted.first?.ts, to: sorted.last?.ts, samples: sorted.count,
            used: .of(sorted.map(\.used)), wired: .of(sorted.map(\.wired)), compressed: .of(sorted.map(\.compressed)), swap: .of(sorted.map(\.swap)),
            pressure: share(sorted.map(\.pressure)),
            owners: Array(holders(sorted.map { $0.owners.map { ($0.name, $0.kind, $0.bytes) } }).prefix(20)),
            agents: Array(holders(sorted.map { $0.agents.map { ($0.agent + " · " + ($0.project ?? "no project"), $0.state == "server" ? "server" : "session", $0.bytes) } }).prefix(20)),
            agentSessions: .of(sessions.map { Int64($0.count) }), agentMemory: .of(sorted.map { $0.agents.reduce(0) { $0 + $1.bytes } }),
            agentStates: share(sessions.flatMap { $0.map { $0.suspended ? "suspended" : $0.state } }),
            browsers: holders(sorted.map { $0.browsers.map { ($0.name, "browser", $0.bytes) } }),
            browserTabs: .of(sorted.map { Int64($0.browsers.reduce(0) { $0 + $1.tabs }) }), idleTabMemory: .of(sorted.map { $0.browsers.reduce(0) { $0 + $1.idleBytes } }),
            actions: Dictionary(grouping: sorted.flatMap(\.actions), by: \.outcome).mapValues(\.count), forecasts: sorted.filter { $0.forecastMinutes != nil }.count)
    }
}
