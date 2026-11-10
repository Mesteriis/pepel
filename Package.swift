// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PEPEL",
    platforms: [.macOS(.v14)],
    products: [
        // Named PEPELApp, not PEPEL: on a case-insensitive volume "PEPEL" and "pepel" would be one file.
        .executable(name: "PEPELApp", targets: ["PEPELApp"]),
        .executable(name: "pepel", targets: ["PEPELCLI"]),
        .library(name: "PEPELEngine", targets: ["PEPELEngine"]),
    ],
    targets: [
        .target(name: "PEPELCore"),
        .target(name: "PEPELPersistence", dependencies: ["PEPELCore"]),
        .target(name: "PEPELProjects", dependencies: ["PEPELCore"]),
        .target(name: "PEPELProcesses", dependencies: ["PEPELCore"]),
        .target(name: "PEPELMemory", dependencies: ["PEPELCore"]),
        .target(name: "PEPELStorage", dependencies: ["PEPELCore", "PEPELProjects"]),
        .target(name: "PEPELBuilds", dependencies: ["PEPELCore", "PEPELPersistence"]),
        .target(name: "PEPELAgents", dependencies: ["PEPELCore", "PEPELPersistence", "PEPELProcesses"]),
        .target(name: "PEPELCleanup", dependencies: ["PEPELCore", "PEPELPersistence"]),
        .target(name: "PEPELMonitoring", dependencies: ["PEPELCore"]),
        .target(
            name: "PEPELEngine",
            dependencies: [
                "PEPELCore", "PEPELPersistence", "PEPELProjects", "PEPELProcesses", "PEPELMemory",
                "PEPELStorage", "PEPELBuilds", "PEPELAgents", "PEPELCleanup", "PEPELMonitoring",
            ]
        ),
        .target(name: "PEPELUI", dependencies: ["PEPELEngine"]),
        .executableTarget(name: "PEPELApp", dependencies: ["PEPELUI"]),
        .executableTarget(name: "PEPELCLI", dependencies: ["PEPELEngine"]),
        .testTarget(name: "PEPELTests", dependencies: ["PEPELEngine"]),
    ]
)
