import Foundation

/// What Docker keeps on disk, resource by resource, as Docker itself reports it.
public struct DockerDiskReport: Codable, Sendable, Hashable {
    public struct Container: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var imageID: String
        /// running, exited, created, paused, dead, restarting.
        public var state: String
        public var createdAt: Date?
        /// When it last stopped; nil while running or when Docker does not say.
        public var finishedAt: Date?
        public var sizeBytes: Int64
        public var composeProject: String?
        public var keepLabel: Bool

        public var isRunning: Bool { state == "running" || state == "paused" || state == "restarting" }

        public init(id: String, name: String, imageID: String, state: String, createdAt: Date?, finishedAt: Date?, sizeBytes: Int64, composeProject: String?, keepLabel: Bool) {
            self.id = id
            self.name = name
            self.imageID = imageID
            self.state = state
            self.createdAt = createdAt
            self.finishedAt = finishedAt
            self.sizeBytes = sizeBytes
            self.composeProject = composeProject
            self.keepLabel = keepLabel
        }
    }

    public struct Image: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var createdAt: Date?
        /// When it was last pulled, built or tagged on this Mac.
        public var arrivedAt: Date?
        public var sizeBytes: Int64
        /// What removing only this image frees: layers no other image shares.
        public var uniqueBytes: Int64
        public var isDangling: Bool

        public init(id: String, name: String, createdAt: Date?, arrivedAt: Date?, sizeBytes: Int64, uniqueBytes: Int64, isDangling: Bool) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
            self.arrivedAt = arrivedAt
            self.sizeBytes = sizeBytes
            self.uniqueBytes = uniqueBytes
            self.isDangling = isDangling
        }
    }

    public struct Volume: Codable, Sendable, Hashable, Identifiable {
        public var name: String
        public var sizeBytes: Int64
        /// Containers (running or stopped) that mount it.
        public var links: Int
        public var createdAt: Date?
        public var composeProject: String?
        public var isAnonymous: Bool
        public var id: String { name }

        public init(name: String, sizeBytes: Int64, links: Int, createdAt: Date?, composeProject: String?, isAnonymous: Bool) {
            self.name = name
            self.sizeBytes = sizeBytes
            self.links = links
            self.createdAt = createdAt
            self.composeProject = composeProject
            self.isAnonymous = isAnonymous
        }
    }

    public struct CacheEntry: Codable, Sendable, Hashable {
        public var sizeBytes: Int64
        public var lastUsedAt: Date?
        public var inUse: Bool

        public init(sizeBytes: Int64, lastUsedAt: Date?, inUse: Bool) {
            self.sizeBytes = sizeBytes
            self.lastUsedAt = lastUsedAt
            self.inUse = inUse
        }
    }

    public var containers: [Container]
    public var images: [Image]
    public var volumes: [Volume]
    public var buildCache: [CacheEntry]
    /// What Docker's disk image occupies on the Mac; 0 when it could not be read.
    public var diskImageBytes: Int64
    public var measuredAt: Date

    public init(containers: [Container], images: [Image], volumes: [Volume], buildCache: [CacheEntry], diskImageBytes: Int64 = 0, measuredAt: Date = Date()) {
        self.containers = containers
        self.images = images
        self.volumes = volumes
        self.buildCache = buildCache
        self.diskImageBytes = diskImageBytes
        self.measuredAt = measuredAt
    }

    public var buildCacheBytes: Int64 { buildCache.reduce(0) { $0 + $1.sizeBytes } }
    public var imageBytes: Int64 { images.reduce(0) { $0 + $1.uniqueBytes } }
    public var volumeBytes: Int64 { volumes.reduce(0) { $0 + $1.sizeBytes } }
}

public enum DockerCleanKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case containers, images, buildCache, networks, volumes
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .containers: "Stopped containers"
        case .images: "Images no container uses"
        case .buildCache: "Build cache"
        case .networks: "Unused networks"
        case .volumes: "Volumes no container mounts"
        }
    }

    /// Volumes hold data that rebuilding does not bring back, so they are never cleaned on PEPEL's own initiative.
    public var reproducible: Bool { self != .volumes }
}

/// What a Docker cleanup would remove, decided from one report.
public struct DockerCleanupPlan: Codable, Sendable, Hashable {
    public var days: Int
    public var containers: [DockerDiskReport.Container]
    public var images: [DockerDiskReport.Image]
    public var volumes: [DockerDiskReport.Volume]
    public var buildCacheBytes: Int64
    public var buildCacheEntries: Int
    /// What was left alone, and why, in a sentence each.
    public var skipped: [String]

    public func bytes(_ kind: DockerCleanKind) -> Int64 {
        switch kind {
        case .containers: containers.reduce(0) { $0 + $1.sizeBytes }
        case .images: images.reduce(0) { $0 + $1.uniqueBytes }
        case .buildCache: buildCacheBytes
        case .networks: 0
        case .volumes: volumes.reduce(0) { $0 + $1.sizeBytes }
        }
    }

    public func count(_ kind: DockerCleanKind) -> Int {
        switch kind {
        case .containers: containers.count
        case .images: images.count
        case .buildCache: buildCacheEntries
        case .networks: 0
        case .volumes: volumes.count
        }
    }

    /// What can be rebuilt or pulled again: everything but volumes.
    public var reproducibleBytes: Int64 { DockerCleanKind.allCases.filter(\.reproducible).reduce(0) { $0 + bytes($1) } }

    /// - Parameters:
    ///   - days: how long a resource must have been unused.
    ///   - keep: container or compose project names to leave alone.
    ///   - activeProjects: compose projects an agent session is working in right now.
    public static func make(_ report: DockerDiskReport, days: Int, keep: Set<String>, activeProjects: Set<String>, now: Date = Date()) -> DockerCleanupPlan {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var skipped: [String] = []
        // A compose project with anything running is in use as a whole: its stopped one-shot
        // containers (migrations, init jobs) belong to the running stack.
        let running = Set(report.containers.filter(\.isRunning).compactMap(\.composeProject))
        var kept = 0, inUse = 0, recent = 0
        let containers = report.containers.filter { container in
            guard !container.isRunning else { return false }
            if container.keepLabel || keep.contains(container.name) || container.composeProject.map(keep.contains) == true { kept += 1; return false }
            if let project = container.composeProject, running.contains(project) || activeProjects.contains(project) { inUse += 1; return false }
            guard let stopped = container.finishedAt ?? container.createdAt, stopped <= cutoff else { recent += 1; return false }
            return true
        }
        if kept > 0 { skipped.append("\(kept) stopped container\(kept == 1 ? " is" : "s are") on the keep list.") }
        if inUse > 0 { skipped.append("\(inUse) stopped container\(inUse == 1 ? " belongs" : "s belong") to a compose project that is running or that an agent is working in.") }
        if recent > 0 { skipped.append("\(recent) stopped container\(recent == 1 ? "" : "s") stopped less than \(days) days ago.") }

        // An image is free once every container that uses it is going away too.
        let leaving = Set(containers.map(\.id))
        let stillUsed = Set(report.containers.filter { !leaving.contains($0.id) }.map(\.imageID))
        var freshImages = 0
        let images = report.images.filter { image in
            guard !stillUsed.contains(image.id) else { return false }
            guard let arrived = image.arrivedAt ?? image.createdAt, arrived <= cutoff else { freshImages += 1; return false }
            return true
        }
        if freshImages > 0 { skipped.append("\(freshImages) unused image\(freshImages == 1 ? " was" : "s were") pulled or built less than \(days) days ago.") }

        let volumes = report.volumes.filter { volume in
            guard volume.links == 0, !keep.contains(volume.name), volume.composeProject.map(keep.contains) != true else { return false }
            if let project = volume.composeProject, running.contains(project) || activeProjects.contains(project) { return false }
            guard let created = volume.createdAt else { return days == 0 }
            return created <= cutoff
        }
        // An entry whose last use is unknown is not assumed to be old.
        let cache = report.buildCache.filter { entry in
            guard !entry.inUse else { return false }
            guard let used = entry.lastUsedAt else { return days == 0 }
            return used <= cutoff
        }
        return DockerCleanupPlan(
            days: days, containers: containers, images: images, volumes: volumes, buildCacheBytes: cache.reduce(0) { $0 + $1.sizeBytes },
            buildCacheEntries: cache.count, skipped: skipped)
    }
}

public struct DockerCleanupReport: Codable, Sendable, Hashable {
    public struct Step: Codable, Sendable, Hashable, Identifiable {
        public var kind: DockerCleanKind
        public var removed: Int
        public var attempted: Int
        public var notes: [String]
        public var id: String { kind.rawValue }

        public init(kind: DockerCleanKind, removed: Int, attempted: Int, notes: [String] = []) {
            self.kind = kind
            self.removed = removed
            self.attempted = attempted
            self.notes = notes
        }
    }

    public var steps: [Step]
    /// Docker's own total (images, containers, volumes, cache) before and after.
    public var dockerBytesBefore: Int64
    public var dockerBytesAfter: Int64
    /// The disk image on the Mac before and after, the figure that matters for free space.
    public var diskImageBefore: Int64
    public var diskImageAfter: Int64
    public var compacted: Bool
    public var compactNote: String

    public init(steps: [Step], dockerBytesBefore: Int64, dockerBytesAfter: Int64, diskImageBefore: Int64, diskImageAfter: Int64, compacted: Bool, compactNote: String) {
        self.steps = steps
        self.dockerBytesBefore = dockerBytesBefore
        self.dockerBytesAfter = dockerBytesAfter
        self.diskImageBefore = diskImageBefore
        self.diskImageAfter = diskImageAfter
        self.compacted = compacted
        self.compactNote = compactNote
    }

    public var freedOnDisk: Int64 { diskImageBefore - diskImageAfter }
}
