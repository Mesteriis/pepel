import Foundation
import Testing

@testable import PEPELCore
@testable import PEPELEngine
@testable import PEPELPersistence
@testable import PEPELProcesses

/// A scripted launchctl that records what it was asked to do.
final class FakeLaunchctl: @unchecked Sendable {
    let lock = NSLock()
    var calls: [[String]] = []
    var list = "PID\tStatus\tLabel\n4242\t0\tdev.example.sync\n-\t0\tcom.example.updater\n-\t0\tcom.vendor.helper\n-\t0\tcom.apple.something\n"
    var disabled = "\tdisabled services = {\n\t\t\"dev.example.backup\" => disabled\n\t}\n"

    func run(_ arguments: [String]) -> String? {
        lock.lock(); defer { lock.unlock() }
        calls.append(arguments)
        switch arguments.first {
        case "list": return list
        case "print-disabled": return disabled
        case "print": return "\tprogram identifier = com.vendor.helper (mode: 1)\n"
        default: return ""
        }
    }
}

@Suite("Startup items")
struct StartupTests {
    func plist(_ path: String, _ object: [String: Any]) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = try! PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        FileManager.default.createFile(atPath: path, contents: data)
    }

    func setUp() -> (Fixture, FakeLaunchctl, StartupInventory) {
        let f = Fixture(), fake = FakeLaunchctl()
        let agents = f.home + "/Library/LaunchAgents", shared = f.root + "/shared", daemons = f.root + "/daemons"
        plist(agents + "/dev.example.sync.plist", ["Label": "dev.example.sync", "ProgramArguments": ["/usr/bin/python3", "/Users/me/bin/sync.py"], "KeepAlive": true])
        plist(agents + "/dev.example.backup.plist", ["Label": "dev.example.backup", "Program": "/opt/tools/backup", "StartInterval": 3600])
        plist(shared + "/com.example.updater.plist", ["Label": "com.example.updater", "ProgramArguments": ["/Applications/Example.app/Contents/MacOS/updater"], "RunAtLoad": true])
        plist(daemons + "/com.example.daemon.plist", ["Label": "com.example.daemon", "Program": "/Library/Example/exampled"])
        let inventory = StartupInventory(
            home: f.home, folders: [(agents, .userAgent), (shared, .sharedAgent), (daemons, .daemon)], uid: 501, launchctl: { fake.run($0) })
        return (f, fake, inventory)
    }

    @Test("Agents, daemons and app helpers are read with their state, owner and memory; macOS's own are left out")
    func inventory() {
        let (f, _, inventory) = setUp()
        defer { _ = f }
        let processes = [
            process(4242, parent: 1, name: "python3", footprint: 300 * Bytes.mb),
            process(4243, parent: 4242, name: "worker", footprint: 100 * Bytes.mb),
        ]
        let items = inventory.items(processes: processes)
        let sync = items.first { $0.label == "dev.example.sync" }
        #expect(sync?.owner == "sync.py" && sync?.isRunning == true && sync?.footprintBytes == 400 * Bytes.mb && sync?.processCount == 2)
        #expect(sync?.schedule == "always kept running")
        #expect(items.first { $0.label == "dev.example.backup" }?.disabled == true)
        #expect(items.first { $0.label == "dev.example.backup" }?.schedule == "every 60 min")
        #expect(items.first { $0.label == "com.example.updater" }?.owner == "Example")
        #expect(items.first { $0.label == "com.example.daemon" }?.kind == .daemon)
        let helper = items.first { $0.label == "com.vendor.helper" }
        #expect(helper?.kind == .appHelper && helper?.managementRefusal != nil)
        #expect(!items.contains { $0.isApple })
    }

    @Test("Owners: the app, the script a system tool runs, or the label without its prefix")
    func owners() {
        #expect(StartupInventory.owner(program: "/usr/bin/open", arguments: ["-g", "/Users/me/Applications/Clausona.app"], label: "x") == "Clausona")
        #expect(StartupInventory.owner(program: "/usr/bin/sandbox-exec", arguments: ["-f", "/a/local.sb", "/a/bin/server"], label: "x") == "server")
        #expect(StartupInventory.owner(program: "/usr/bin/osascript", arguments: ["-l", "JavaScript", "-e", "code"], label: "ai.hermes.gateway") == "hermes gateway")
        #expect(StartupInventory.parseProgram("\tprogram = /opt/x/bin/tool\n") == "/opt/x/bin/tool")
    }

    @Test("Switching off disables and stops an agent; refused for agents of the API, automation, daemons and macOS")
    func switching() async throws {
        let (f, fake, inventory) = setUp()
        let store = try PepelStore.inMemory()
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled, analyzers: [],
            processSource: FakeProcessSource(processes: []), telemetry: { SystemTelemetry() })
        await engine.setStartupInventory(inventory)
        #expect(await engine.setStartupItem("dev.example.sync", enabled: false, confirmed: true, initiator: .agent) != nil)
        #expect(await engine.setStartupItem("dev.example.sync", enabled: false, confirmed: true, initiator: .automatic) != nil)
        #expect(await engine.setStartupItem("dev.example.sync", enabled: false, confirmed: false, initiator: .user) != nil)
        #expect(await engine.setStartupItem("com.example.daemon", enabled: false, confirmed: true, initiator: .user) != nil)
        #expect(await engine.setStartupItem("com.vendor.helper", enabled: false, confirmed: true, initiator: .user) != nil)
        #expect(!fake.calls.contains { $0.first == "disable" })

        #expect(await engine.setStartupItem("dev.example.sync", enabled: false, confirmed: true, initiator: .user) == nil)
        #expect(fake.calls.contains(["disable", "gui/501/dev.example.sync"]) && fake.calls.contains(["bootout", "gui/501/dev.example.sync"]))
        #expect(await engine.setStartupItem("dev.example.backup", enabled: true, confirmed: true, initiator: .cli) == nil)
        #expect(fake.calls.contains(["enable", "gui/501/dev.example.backup"]) && fake.calls.contains { $0.first == "bootstrap" && $0.last?.hasSuffix("dev.example.backup.plist") == true })
        #expect(PathUtil.exists(f.home + "/Library/LaunchAgents/dev.example.sync.plist"), "the property list stays")
        #expect(store.audit(limit: 10, kinds: [.startup]).map(\.outcome).sorted() == ["disabled", "enabled"])
    }

    @Test("Something new is announced once; what was there at the first look is not")
    func newItems() async throws {
        let (f, fake, inventory) = setUp()
        let store = try PepelStore.inMemory()
        let engine = try PepelEngine(
            paths: AppPaths(home: f.home, supportDirectory: f.root + "/support"), store: store, tools: .disabled, analyzers: [],
            processSource: FakeProcessSource(processes: []), telemetry: { SystemTelemetry() })
        await engine.setStartupInventory(inventory)
        _ = await engine.actionNotices()
        await engine.watchStartupItems(now: Date())
        #expect(await engine.actionNotices().isEmpty)
        plist(f.home + "/Library/LaunchAgents/com.sneaky.agent.plist", ["Label": "com.sneaky.agent", "Program": "/Users/me/.sneaky/run", "RunAtLoad": true])
        fake.list += "-\t0\tcom.sneaky.agent\n"
        await engine.watchStartupItems(now: Date().addingTimeInterval(3700))
        let notices = await engine.actionNotices()
        #expect(notices.count == 1 && notices[0].kind == .startup && notices[0].title.contains("run"))
        #expect(await engine.startupItems().first { $0.label == "com.sneaky.agent" }?.firstSeen != nil)
        #expect(await engine.startupItems().first { $0.label == "dev.example.sync" }?.firstSeen == nil)
    }
}

@Suite("Startup owner names")
struct StartupOwnerTests {
    @Test("A team ID prefix is dropped from a helper's name")
    func teamID() {
        #expect(StartupInventory.owner(program: "2BUA8C4S2C.com.1password.browser-helper", label: "2BUA8C4S2C.com.1password.browser-helper") == "1password browser-helper")
    }
}
