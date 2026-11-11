import Foundation
import PEPELCore

/// Groups the process table by who is responsible for the memory.
public enum MemoryAttributor {
    static let virtualMachineNames: Set<String> = [
        "com.apple.Virtualization.VirtualMachine", "qemu-system-aarch64", "qemu-system-x86_64", "krunkit", "vfkit",
    ]

    /// The top-level `.app` a process lives in: a renderer helper nested three bundles deep
    /// belongs to the application the user launched.
    static func applicationBundle(of path: String) -> (path: String, name: String)? {
        guard let range = path.range(of: ".app/") else { return nil }
        let bundle = String(path[..<range.lowerBound]) + ".app"
        return (bundle, ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension)
    }

    /// Which container product a runtime process belongs to.
    static func containerProduct(_ p: ProcessSnapshot) -> String? {
        let path = p.executablePath ?? ""
        if path.contains("/Docker.app/") || p.name.hasPrefix("com.docker.") { return "Docker Desktop" }
        if path.contains("OrbStack.app") { return "OrbStack" }
        if p.name == "colima" || p.name == "limactl" || p.name == "lima" { return "Colima / Lima" }
        if p.name == "podman" || path.contains("podman") { return "Podman" }
        return nil
    }

    /// Stands in for the product in the owner's id when no container product could be matched.
    static let unidentifiedVM = "Virtual machine (owner not identified)"

    public static func attribute(
        processes: [ProcessSnapshot], assessments: [ProcessAssessment], sessions: [AgentSession],
        projectName: (String) -> String?
    ) -> [MemoryOwner] {
        let tree = ProcessTree(processes)
        let sessionByRoot = Dictionary(sessions.map { ($0.root, $0) }, uniquingKeysWith: { a, _ in a })
        let assessmentByID = Dictionary(assessments.map { ($0.process.identity, $0) }, uniquingKeysWith: { a, _ in a })

        // A virtual machine process is a child of launchd, so its owner is inferred: the container
        // product whose runtime started at the same moment. That is evidence, not proof.
        let runtimes = processes.compactMap { p in containerProduct(p).map { (product: $0, start: p.identity.startTime) } }
        func vmOwner(_ vm: ProcessSnapshot) -> (name: String, confidence: Confidence) {
            let near = runtimes.min { abs(Int64(bitPattern: $0.start &- vm.identity.startTime)) < abs(Int64(bitPattern: $1.start &- vm.identity.startTime)) }
            if let near, abs(Int64(bitPattern: near.start &- vm.identity.startTime)) < 30_000_000 { return (near.product, .probable) }
            if let only = Set(runtimes.map(\.product)).first, Set(runtimes.map(\.product)).count == 1 { return (only, .probable) }
            return (unidentifiedVM, .unknown)
        }

        struct Bucket {
            var owner: MemoryOwner
            var members: [ProcessSnapshot] = []
        }
        var buckets: [String: Bucket] = [:]
        func add(_ p: ProcessSnapshot, id: String, make: () -> MemoryOwner) {
            if buckets[id] == nil { buckets[id] = Bucket(owner: make()) }
            buckets[id]?.members.append(p)
        }

        for p in processes {
            let path = p.executablePath ?? ""

            if let session = ([p] + tree.ancestors(of: p)).lazy.compactMap({ sessionByRoot[$0.identity] }).first {
                let project = session.projectID.flatMap(projectName)
                add(p, id: "agent:\(session.root)") {
                    MemoryOwner(
                        id: "agent:\(session.root)", kind: .agentSession,
                        name: session.kind.displayName + (project.map { " · \($0)" } ?? ""),
                        detail: L("Session started \(TimeFormat.ago(session.startedAt)), with the tools and servers it launched."),
                        projectID: session.projectID)
                }
                continue
            }

            if virtualMachineNames.contains(p.name) || containerProduct(p) != nil {
                let (product, confidence) = containerProduct(p).map { ($0, Confidence.verified) } ?? vmOwner(p)
                add(p, id: "vm:\(product)") {
                    MemoryOwner(
                        id: "vm:\(product)", kind: .virtualMachine, name: product == unidentifiedVM ? L("Virtual machine (owner not identified)") : product,
                        detail: L("The virtual machine holds everything its containers use, up to its configured memory limit."),
                        confidence: confidence)
                }
                if virtualMachineNames.contains(p.name), confidence < (buckets["vm:\(product)"]?.owner.confidence ?? .verified) {
                    buckets["vm:\(product)"]?.owner.confidence = confidence
                }
                continue
            }

            if let app = applicationBundle(of: path) {
                add(p, id: "app:\(app.path)") {
                    MemoryOwner(id: "app:\(app.path)", kind: .application, name: app.name, detail: L("The application and its helper processes."))
                }
                continue
            }

            if let assessment = assessmentByID[p.identity], let projectID = assessment.projectID {
                add(p, id: "project:\(projectID)") {
                    MemoryOwner(
                        id: "project:\(projectID)", kind: .project, name: projectName(projectID) ?? (projectID as NSString).lastPathComponent,
                        detail: L("Builds, tests and servers running in this project outside an agent session."),
                        confidence: assessment.projectConfidence, projectID: projectID)
                }
                continue
            }

            if path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/") || path.hasPrefix("/Library/Apple/") {
                add(p, id: "system") {
                    MemoryOwner(id: "system", kind: .system, name: L("macOS services"), detail: L("System services running under your account."))
                }
                continue
            }

            // Stand-alone programs: grouped by executable so twenty copies read as one line.
            let name = path.isEmpty ? p.name : (path as NSString).lastPathComponent
            let isTool = assessmentByID[p.identity] != nil
            add(p, id: "exe:\(name)") {
                MemoryOwner(
                    id: "exe:\(name)", kind: isTool ? .developerTool : .other, name: name,
                    detail: isTool ? L("Developer processes not tied to a project or session.") : L("Started outside any application bundle."))
            }
        }

        return buckets.values.map { bucket in
            var owner = bucket.owner
            owner.processCount = bucket.members.count
            owner.footprintBytes = bucket.members.reduce(0) { $0 + $1.footprintBytes }
            owner.residentBytes = bucket.members.reduce(0) { $0 + $1.residentBytes }
            owner.notInRAMBytes = bucket.members.reduce(0) { $0 + max(0, $1.footprintBytes - $1.residentBytes) }
            owner.largest = bucket.members.sorted { $0.footprintBytes > $1.footprintBytes }.prefix(5).map {
                MemoryOwnerProcess(identity: $0.identity, name: $0.name, footprintBytes: $0.footprintBytes, residentBytes: $0.residentBytes)
            }
            return owner
        }
        .sorted { ($0.footprintBytes, $0.id) > ($1.footprintBytes, $1.id) }
    }

    /// One or two sentences on why memory is tight, from measurements only.
    public static func explanation(owners: [MemoryOwner], telemetry: SystemTelemetry) -> String {
        let squeezed = telemetry.compressedBytes + telemetry.swapUsedBytes
        guard let top = owners.first, top.footprintBytes > 0 else { return L("No process data yet.") }
        var sentences: [String] = []
        let share = telemetry.memoryTotalBytes > 0 ? Int(Double(top.footprintBytes) / Double(telemetry.memoryTotalBytes) * 100) : 0
        let percent = "\(share)%"
        if squeezed > Bytes.gb, top.notInRAMBytes > squeezed / 4 {
            sentences.append(
                L("\(top.name) is charged \(Bytes.format(top.footprintBytes)) (\(percent) of physical memory), of which about \(Bytes.format(top.notInRAMBytes)) is not in RAM: macOS has compressed or swapped it. That is most of the \(Bytes.format(squeezed)) compressed and swapped system-wide."))
        } else {
            sentences.append(L("\(top.name) is charged \(Bytes.format(top.footprintBytes)) (\(percent) of physical memory)."))
        }
        let agents = owners.filter { $0.kind == .agentSession }
        if agents.count > 1 {
            let total = agents.reduce(Int64(0)) { $0 + $1.footprintBytes }
            sentences.append(L("\(agents.count) agent sessions hold \(Bytes.format(total)) together."))
        }
        if squeezed > Bytes.gb { sentences.append(L("The split between RAM and compressed memory is an estimate per process.")) }
        return sentences.joined(separator: " ")
    }
}
