import AppKit
import Observation
import PEPELEngine
import SwiftUI

public enum DashboardSection: String, CaseIterable, Identifiable, Sendable {
    case overview, storage, map, memory, builds, projects, agents, cleanup, history, settings

    public var id: String { rawValue }
    /// The name shown in the sidebar; `rawValue` stays the identity.
    public var title: String {
        switch self {
        case .overview: L("Overview")
        case .storage: L("Storage")
        case .map: L("Disk map")
        case .memory: L("Memory")
        case .builds: L("Builds")
        case .projects: L("Projects")
        case .agents: L("Agents")
        case .cleanup: L("Cleanup")
        case .history: L("History")
        case .settings: L("Settings")
        }
    }

    public var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .storage: "internaldrive"
        case .map: "square.grid.3x3.topleft.filled"
        case .memory: "memorychip"
        case .builds: "hammer"
        case .projects: "folder"
        case .agents: "sparkles"
        case .cleanup: "flame"
        case .history: "chart.xyaxis.line"
        case .settings: "gearshape"
        }
    }
}

public enum HealthLevel: Sendable {
    case healthy, attention, critical
}

/// UI state. All work happens in the engine; this object only mirrors results onto the main actor.
@MainActor
@Observable
public final class AppModel {
    public let engine: PepelEngine
    let monitor: MonitorService
    private var apiServer: LocalAPIServer?
    private var notified = Set<String>()

    public var live: LiveState?
    public var storage: StorageState?
    public var growth: GrowthState?
    public var alerts: [PepelAlert] = []
    public var settings = PepelSettings()
    public var scanProgress: ScanProgress?
    public var isScanning = false
    public var cadence = ""
    public var section: DashboardSection = .overview

    public var audit: [AuditEntry] = []
    public var telemetryHistory: [TelemetryPoint] = []
    public var protections: [ProtectionRule] = []
    public var leases: [ResourceLease] = []

    public var plan: CleanupPlan?
    public var isPlanning = false
    public var isCleaning = false
    public var cleanupReport: CleanupReport?
    public var pendingTermination: TerminationDecision?
    public var terminationReport: TerminationReport?
    public var message: String?
    /// Set while macOS is not showing PEPEL's menu bar item; explains why and what to do.
    public var menuBarNotice: String?
    private var menuBarNoticePosted = false
    public var apiStatus = L("Not started")
    public var loginItemStatus = LoginItem.statusText

    /// What the rules will do next, what they did, and what PEPEL itself costs.
    public let activity: ActivityModel

    public init(engine: PepelEngine) {
        self.engine = engine
        self.monitor = MonitorService(engine: engine)
        self.activity = ActivityModel(engine: engine)
    }

    /// A heavy job's name in words. The names themselves stay English: they are stored and the
    /// command-line tool prints them.
    static func heavyTaskTitle(_ name: String) -> String {
        switch name {
        case "Disk map": L("Disk map")
        case "Large files search": L("Large files search")
        case "Storage scan": L("Storage scan")
        case "Cache measuring": L("Cache measuring")
        case "Folder measuring": L("Folder measuring")
        case "Plan for the next day": L("Plan for the next day")
        default: name
        }
    }

    /// Heavy jobs running in this app right now, by name.
    var heavyTasks: [String] {
        var tasks: [String] = []
        if isMeasuringDiskMap { tasks.append("Disk map") }
        if isFindingLargeFiles { tasks.append("Large files search") }
        if isScanning { tasks.append("Storage scan") }
        if isMeasuringCaches { tasks.append("Cache measuring") }
        if isMeasuringAppData || isMeasuringOther { tasks.append("Folder measuring") }
        if activity.isPlanning { tasks.append("Plan for the next day") }
        return tasks
    }

    public static func make() -> AppModel {
        let environment = ProcessInfo.processInfo.environment
        let paths = AppPaths(home: environment["PEPEL_HOME"] ?? NSHomeDirectory(), supportDirectory: environment["PEPEL_SUPPORT_DIR"])
        do {
            return AppModel(engine: try PepelEngine(paths: paths))
        } catch {
            // Keep the app usable without persistence rather than failing to launch.
            let fallback = try! PepelEngine(paths: paths, store: try! PepelStore.inMemory())
            let model = AppModel(engine: fallback)
            model.message = L("PEPEL could not open its database (\(String(describing: error))). Running without history.")
            return model
        }
    }

    // MARK: Lifecycle

    /// PID of the application in front, kept current from the main thread and read by the engine.
    private final class Frontmost: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: Int32?
        func set(_ value: Int32?) { lock.lock(); pid = value; lock.unlock() }
        func get() -> Int32? { lock.lock(); defer { lock.unlock() }; return pid }
    }
    private let frontmost = Frontmost()
    private var activationObserver: NSObjectProtocol?

    /// Keeps the engine informed about which application is in front, and wakes suspended
    /// sessions the moment their application is activated.
    private func watchFrontmostApplication() {
        frontmost.set(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        let frontmost = frontmost, engine = engine
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            frontmost.set(pid)
            engine.applicationActivated(pid: pid)
            if let path = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL?.path { engine.noteActivation(bundlePath: path) }
        }
    }

    /// Wakes everything PEPEL suspended; called when the app quits so nothing stays stopped.
    public func wakeEverything(reason: String) { engine.thawAll(reason: reason) }

    public func freeze(_ session: AgentSession) {
        Task {
            if let decision = await engine.freeze(session.root, confirmed: true, initiator: .user), decision.verdict == .denied {
                message = L("Not suspended: \(decision.reasons.joined(separator: " "))")
            }
            live = await engine.live
        }
    }

    public func thaw(_ session: AgentSession) {
        engine.thaw(session.root, reason: "you asked")
        Task { live = await engine.refreshLive() }
    }

    public func start() {
        // Whatever a previous PEPEL left suspended (a crash, a forced quit) is woken first.
        engine.thawAll(reason: "PEPEL started")
        watchFrontmostApplication()
        watchScreenLock()
        Notifier.configure { [weak self] in self?.freeMemoryNow(trigger: "the button on a memory pressure notification") }
        Task {
            let frontmost = frontmost
            await engine.setFrontmostProvider { frontmost.get() }
            await engine.setJournaling(true)
            settings = await engine.currentSettings()
            storage = await engine.storage
            refreshSecondary()
            let stream = await monitor.events()
            await monitor.start()
            startAgentAPI()
            for await event in stream { handle(event) }
        }
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .live(let state):
            withAnimation(.easeOut(duration: 0.25)) { live = state }
            recordMemory(state.telemetry)
            // Settings changed from the command line show up in the interface too.
            Task {
                let current = await engine.currentSettings()
                if current != settings { settings = current }
            }
        case .scanStarted:
            isScanning = true
            scanProgress = ScanProgress(phase: L("Starting"))
        case .scanProgress(let progress):
            scanProgress = progress
        case .storage(let state):
            withAnimation(.easeOut(duration: 0.3)) { storage = state }
            isScanning = false
            scanProgress = nil
            refreshSecondary()
        case .alerts(let current):
            alerts = current
            notify(current)
            postSummaryIfDue()
            postActionNotices()
            activity.refreshSelf(heavyTasks: heavyTasks, limitMB: settings.selfMemoryWarnMB, notify: settings.notificationsEnabled)
        case .automatic:
            postActionNotices()
            refreshSecondary()
        case .cadence(let reason):
            cadence = reason
        }
    }

    /// What PEPEL did on its own since the last time: closed, ended, stopped, removed, and what that freed.
    private func postActionNotices() {
        Task {
            let notices = await engine.actionNotices()
            let s = settings
            guard s.notificationsEnabled, !s.quietHours.contains(hour: Calendar.current.component(.hour, from: Date())) else { return }
            for notice in notices {
                switch notice.kind {
                case .closure: guard s.notifyClosures else { continue }
                case .cleanup: guard s.notifyCleanups else { continue }
                case .freeze: guard s.notifyFreezes else { continue }
                }
                Notifier.post(id: notice.id, title: notice.title, body: notice.body)
            }
        }
    }

    private func notify(_ alerts: [PepelAlert]) {
        let current = Set(alerts.map(\.id))
        notified.formIntersection(current)
        guard settings.notificationsEnabled, !settings.paused,
            !settings.quietHours.contains(hour: Calendar.current.component(.hour, from: Date()))
        else { return }
        for alert in alerts where alert.severity != .info && notified.insert(alert.id).inserted {
            // A memory pressure notification carries a button that frees memory right away.
            Notifier.post(id: alert.id, title: alert.title, body: alert.message, category: alert.id.hasPrefix("memory-") && !alert.id.hasPrefix("memory-budget-") ? Notifier.memoryCategory : nil)
        }
    }

    /// Frees memory on a standing instruction (the notification button, the screen locking) and
    /// says what came of it.
    public func freeMemoryNow(trigger: String) {
        guard !isReclaiming else { return }
        isReclaiming = true
        Task {
            let report = await engine.reclaimOnStandingInstruction(trigger: trigger)
            isReclaiming = false
            reclaimReport = report ?? reclaimReport
            live = await engine.live
            refreshSecondary()
            if let report, settings.notificationsEnabled {
                let done = report.results.map { "\($0.title.lowercased()): \($0.done)" }.joined(separator: ", ")
                Notifier.post(
                    id: "free-\(Int(report.finishedAt.timeIntervalSince1970))", title: L("Memory freed"),
                    body: L("Memory used \(Bytes.format(report.before.memoryUsedBytes)) → \(Bytes.format(report.after.memoryUsedBytes)), free \(Bytes.format(report.before.freeBytes)) → \(Bytes.format(report.after.freeBytes)). \(done)."))
            }
        }
    }

    private var lockObserver: NSObjectProtocol?

    /// When the screen locks nobody is looking: a good moment, if the user asked for it.
    private func watchScreenLock() {
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.settings.freeMemoryOnLock, !self.settings.paused else { return }
                self.freeMemoryNow(trigger: "the screen was locked")
            }
        }
    }

    private func startAgentAPI() {
        do {
            try engine.paths.ensureSupportDirectory()
            let token = try APIToken.loadOrCreate(at: engine.paths.token)
            let server = LocalAPIServer(socketPath: engine.paths.socket, token: token, service: engine.makeAgentService())
            try server.start()
            apiServer = server
            apiStatus = L("Listening")
        } catch {
            apiStatus = L("Unavailable: \(String(describing: error))")
        }
    }

    /// History, rules and leases: cheap reads that change rarely.
    public func refreshSecondary() {
        let store = engine.store
        Task {
            growth = engine.growth()
            audit = store.audit(limit: 300)
            telemetryHistory = store.telemetryHistory(since: Date().addingTimeInterval(-7 * 86_400))
            protections = store.protections()
            leases = store.leases()
            activity.refreshRestore()
        }
    }

    // MARK: Menu bar item visibility

    /// Called by the app shell with whether macOS currently gives the menu bar item a place.
    ///
    /// On macOS 27 menu bar managers hide other apps' items through a system allow-list that is
    /// built when the manager collapses. An app started while the manager is collapsed is not on
    /// that list, so its item stays hidden until the manager is expanded and collapsed once more.
    /// PEPEL cannot change that list; it can only notice and say what to do.
    public func menuBarItem(placed: Bool) {
        guard !placed else {
            menuBarNotice = nil
            menuBarNoticePosted = false
            return
        }
        let managers = ["com.dwarvesv.minimalbar": "Hidden Bar", "com.jordanbaird.Ice": "Ice", "com.surteesstudios.Bartender": "Bartender", "com.stonerl.Thaw": "Thaw"]
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier.flatMap { managers[$0] } }.first
        let installed = Bundle.main.bundlePath.hasPrefix("/Applications/")
        if let running, !installed {
            menuBarNotice = L("macOS is not showing PEPEL's menu bar icon. On macOS 27, \(running) hides apps that do not run from /Applications: install PEPEL there (Scripts/install.sh, or drag PEPEL.app into Applications), then expand \(running) and collapse it again. Opening PEPEL.app again shows this window.")
        } else if let running {
            menuBarNotice = L("macOS is not showing PEPEL's menu bar icon. \(running) hides every app that was not running when it last collapsed: expand \(running) and collapse it again, and the icon appears to the right of its arrow. Until then, opening PEPEL.app again shows this window.")
        } else {
            menuBarNotice = L("macOS is not showing PEPEL's menu bar icon. Check System Settings › Menu Bar › Allow in the Menu Bar, and whether the menu bar has room for it. Opening PEPEL.app again shows this window.")
        }
        guard !menuBarNoticePosted else { return }
        menuBarNoticePosted = true
        Notifier.post(
            id: "menubar-hidden", title: L("PEPEL's menu bar icon is hidden"),
            body: running.map { L("Expand \($0) and collapse it again to bring the icon back.") } ?? L("Check System Settings › Menu Bar."))
    }

    // MARK: Menu bar graph

    /// Memory in use as a share of physical memory, one reading per live update, newest last.
    public private(set) var memoryHistory: [Double] = []
    static let memoryHistoryLength = 48

    private func recordMemory(_ t: SystemTelemetry) {
        guard t.memoryTotalBytes > 0 else { return }
        memoryHistory.append(Double(t.memoryUsedBytes) / Double(t.memoryTotalBytes))
        if memoryHistory.count > Self.memoryHistoryLength { memoryHistory.removeFirst(memoryHistory.count - Self.memoryHistoryLength) }
    }

    /// Everything the menu bar item draws, read at once.
    public var menuBarReading: MenuBarReading {
        let t = live?.telemetry
        return MenuBarReading(
            status: menuBarStatus, memoryUsed: t?.memoryUsedBytes ?? 0, memoryTotal: t?.memoryTotalBytes ?? 0, pressure: t?.pressure ?? .normal,
            history: memoryHistory, diskAvailable: t?.diskAvailableBytes ?? 0, text: menuBarText)
    }

    public var menuBarStatus: NSColor {
        if settings.paused { return .systemGray }
        switch health {
        case .healthy: return NSColor(Theme.forest)
        case .attention: return NSColor(Theme.amber)
        case .critical: return NSColor(Theme.danger)
        }
    }

    // MARK: Derived

    public var health: HealthLevel {
        if alerts.contains(where: { $0.severity == .critical }) { return .critical }
        if alerts.contains(where: { $0.severity == .warning }) || !(live?.abandoned.isEmpty ?? true) { return .attention }
        return .healthy
    }

    public var healthSentence: String {
        if settings.paused { return L("Monitoring is paused.") }
        switch health {
        case .critical: return alerts.first { $0.severity == .critical }?.title ?? L("Needs attention now.")
        case .attention:
            let count = live?.abandoned.count ?? 0
            return alerts.first { $0.severity == .warning }?.title ?? L("\(count) processes look abandoned.")
        case .healthy: return L("Workstation is healthy.")
        }
    }

    public var reclaimableText: String {
        guard let storage else { return "—" }
        return Bytes.format(storage.reclaimableBytes)
    }

    public var menuBarText: String? {
        switch settings.menuBarMode {
        case .iconOnly: return nil
        case .reclaimable: return storage == nil ? nil : reclaimableText
        case .memoryPressure: return live.map { $0.telemetry.pressure == .normal ? L("OK") : $0.telemetry.pressure == .elevated ? L(LocalizedStringResource("pressure.elevated", defaultValue: "Elevated")) : L(LocalizedStringResource("pressure.critical", defaultValue: "Critical")) }
        case .activeBuilds: return live.map { "\($0.activeBuildCount)" }
        // Drawn into the image by MenuBarRenderer.
        case .memoryAndDisk, .memoryGraph, .memoryGraphAndDisk: return nil
        }
    }

    public func item(_ id: String) -> StorageItem? { storage?.items.first { $0.id == id } }

    public func projectName(_ projectID: String?) -> String? {
        guard let projectID else { return nil }
        return storage?.projects.first { $0.id == projectID }?.name ?? (projectID as NSString).lastPathComponent
    }

    // MARK: Actions

    public func scanNow() {
        Task { await monitor.requestScan(incremental: false) }
    }

    public func cancelScan() {
        Task { await monitor.cancelScan() }
    }

    public func updateSettings(_ mutate: @escaping @Sendable (inout PepelSettings) -> Void) {
        Task {
            do {
                settings = try await engine.update(mutate)
                await engine.reevaluateStorage()
                storage = await engine.storage
                await monitor.poke()
            } catch {
                message = L("Settings could not be saved: \(String(describing: error))")
            }
        }
    }

    public func togglePause() {
        updateSettings { $0.paused.toggle() }
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        if let problem = LoginItem.set(enabled) { message = problem }
        loginItemStatus = LoginItem.statusText
        let registered = LoginItem.isEnabled
        updateSettings { $0.launchAtLogin = registered }
    }

    public func prepareCleanup() {
        guard !isPlanning else { return }
        isPlanning = true
        cleanupReport = nil
        Task {
            plan = await engine.cleanupPlan(initiator: .user)
            isPlanning = false
        }
    }

    public func runCleanup(selected: Set<String>, dryRun: Bool) {
        guard var plan, !isCleaning else { return }
        plan.decisions = plan.decisions.filter { selected.contains($0.id) }
        isCleaning = true
        Task {
            cleanupReport = await engine.executeCleanup(plan, confirmed: selected, dryRun: dryRun)
            isCleaning = false
            if !dryRun {
                storage = await engine.storage
                self.plan = await engine.cleanupPlan(initiator: .user)
            }
            refreshSecondary()
        }
    }

    public func requestTermination(_ assessment: ProcessAssessment) {
        Task {
            pendingTermination = await engine.terminationDecision(assessment.process.identity, initiator: .user)
            if pendingTermination == nil { message = L("That process has already exited.") }
        }
    }

    public func confirmTermination(force: Bool) {
        guard let decision = pendingTermination else { return }
        pendingTermination = nil
        Task {
            switch await engine.terminate(decision.target.process.identity, confirmed: true, force: force, initiator: .user) {
            case .completed(let report): terminationReport = report
            case .denied(let d), .needsConfirmation(let d): message = L("Not terminated: \(d.reasons.joined(separator: " "))")
            case .notFound: message = L("That process has already exited.")
            }
            live = await engine.live
            refreshSecondary()
        }
    }

    public func protect(_ kind: ProtectionKind, _ value: String, note: String = "") {
        Task {
            do {
                _ = try await engine.protect(kind, value: value, note: note)
                await engine.reevaluateStorage()
                storage = await engine.storage
                refreshSecondary()
            } catch {
                message = L("Could not add the protection: \(String(describing: error))")
            }
        }
    }

    public func unprotect(_ rule: ProtectionRule) {
        Task {
            try? await engine.unprotect(id: rule.id)
            await engine.reevaluateStorage()
            storage = await engine.storage
            refreshSecondary()
        }
    }

    public func setPinned(_ path: String, _ pinned: Bool) {
        Task {
            try? await engine.setPinned(path, pinned)
            await engine.reevaluateStorage()
            storage = await engine.storage
            refreshSecondary()
        }
    }

    public func restore(_ entry: AuditEntry) {
        guard let trashed = entry.detail["trashedTo"], let original = entry.detail["path"] else { return }
        message = engine.restore(trashedPath: trashed, originalPath: original).map { L("Could not restore: \($0)") } ?? L("Restored \(PathUtil.display(original)).")
        refreshSecondary()
    }

    // MARK: Free memory

    public var reclaimPlan: ReclaimPlan?
    public var reclaimSelection: Set<String> = []
    public var reclaimReport: ReclaimReport?
    public var isReclaiming = false

    public func prepareReclaim() {
        reclaimReport = nil
        Task {
            let plan = await engine.reclaimPlan()
            reclaimSelection = plan.defaultSelection
            reclaimPlan = plan
        }
    }

    public func cancelReclaim() { reclaimPlan = nil }

    /// Nil until it has been read.
    public var fileCachePermission: (available: Bool, granted: Bool)?

    public func refreshFileCachePermission() {
        Task { fileCachePermission = await engine.fileCachePermission() }
    }

    public func revokeFileCachePermission() {
        Task {
            if case .failed(let reason) = await engine.revokeFileCachePermission(initiator: .user) { message = L("Not removed: \(reason)") }
            fileCachePermission = await engine.fileCachePermission()
        }
    }

    public func confirmReclaim() {
        let selection = reclaimSelection
        reclaimPlan = nil
        guard !selection.isEmpty else { return }
        isReclaiming = true
        Task {
            reclaimReport = await engine.reclaim(selection, initiator: .user)
            isReclaiming = false
            live = await engine.live
            refreshSecondary()
        }
    }

    // MARK: Inside agent servers

    public func endStaleBranches() {
        Task {
            var ended = 0
            let stale = live?.staleBranches ?? []
            for item in stale {
                if case .completed(let report) = await engine.terminate(item.process.identity, confirmed: true, force: false, initiator: .user), report.exited { ended += 1 }
            }
            message = L("Ended \(ended) of \(stale.count) old copies inside agent servers.")
            live = await engine.live
            refreshSecondary()
        }
    }

    public func unloadIdleTabs() {
        Task {
            var done = 0
            let idle = live?.idleTabs ?? []
            for item in idle {
                if case .completed(let report) = await engine.terminate(item.process.identity, confirmed: true, force: false, initiator: .user), report.exited { done += 1 }
            }
            message = L("Unloaded \(done) of \(idle.count) idle browser tab processes.")
            live = await engine.live
            refreshSecondary()
        }
    }

    // MARK: Disk map

    /// Where the map starts. The whole disk by default.
    public var diskMapRoot = "/"
    public var diskMapPath = "/"
    /// Measured folders by path. A folder that is not here yet is measured when it is opened.
    public var diskMapLevels: [String: DiskLevel] = [:]
    var diskMapFacts: [String: DiskTileFacts] = [:]
    public var isMeasuringDiskMap = false
    /// Whether folders macOS guards are read too. Reading them makes macOS ask for access.
    public var diskMapReadsGuarded = UserDefaults.standard.bool(forKey: "PEPELDiskMapReadsGuarded") {
        didSet { UserDefaults.standard.set(diskMapReadsGuarded, forKey: "PEPELDiskMapReadsGuarded") }
    }
    private var diskMapTask: Task<Void, Never>?
    /// Counts measurements, so a stopped one cannot overwrite the state of the one that replaced it.
    private var diskMapRun = 0
    private static let diskMapKey = "diskmap.levels"

    public var diskMapLevel: DiskLevel? { diskMapLevels[diskMapPath] }

    /// The name of the disk, for the first crumb.
    public var diskName: String {
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? L("This Mac")
    }

    /// The folder on screen with, at the top of the disk, one more tile for the space the disk
    /// reports as used but that no folder PEPEL may read accounts for.
    public var diskMapDisplayLevel: DiskLevel? {
        guard var level = diskMapLevel else { return nil }
        if level.path == "/", level.pending == 0, let t = live?.telemetry, t.diskTotalBytes > 0 {
            let rest = (t.diskTotalBytes - t.diskFreeBytes) - level.bytes
            if rest > max(Bytes.gb, level.bytes / 100) {
                level.nodes.append(DiskNode(path: "/", name: L("Not measured"), kind: .unmeasured, bytes: rest))
            }
        }
        return level
    }

    /// First time the section is shown: what was measured last time, or a fresh measurement.
    public func openDiskMapIfNeeded() {
        guard diskMapLevels.isEmpty, !isMeasuringDiskMap else { return }
        if let saved = engine.store.loadCodable([String: DiskLevel].self, key: Self.diskMapKey), saved[diskMapRoot] != nil {
            diskMapLevels = saved
            refreshDiskMapFacts()
        } else {
            measureDiskMap(diskMapRoot)
        }
    }

    public func setDiskMapRoot(_ path: String) {
        diskMapRoot = path == "/" ? "/" : PathUtil.canonical(path)
        showDiskMap(diskMapRoot)
    }

    private func isInsideDiskMapRoot(_ path: String) -> Bool {
        path == diskMapRoot || diskMapRoot == "/" || path.hasPrefix(diskMapRoot + "/")
    }

    /// Shows a folder: at once when it has been measured, otherwise measuring what is in it.
    public func showDiskMap(_ path: String) {
        let target = path.isEmpty ? "/" : path
        guard isInsideDiskMapRoot(target) else { return }
        diskMapPath = target
        if diskMapLevels[target]?.complete == true { refreshDiskMapFacts() } else { measureDiskMap(target) }
    }

    public func cancelDiskMap() {
        diskMapTask?.cancel()
        isMeasuringDiskMap = false
    }

    /// Measures the folders directly inside `path`, one by one; tiles appear as each finishes.
    public func measureDiskMap(_ path: String) {
        diskMapTask?.cancel()
        isMeasuringDiskMap = true
        diskMapRun += 1
        let run = diskMapRun
        let scanner = DiskMapScanner(home: engine.paths.home)
        let guarded = diskMapReadsGuarded
        // Utility priority: a map of the whole disk must not make the Mac sluggish.
        diskMapTask = Task.detached(priority: .utility) { [weak self] in
            let levels = await scanner.measure(path, includeGuarded: guarded) { level in
                Task { @MainActor in self?.adoptDiskMap([level], run: run, finished: false) }
            }
            await self?.adoptDiskMap(levels, run: run, finished: true)
        }
    }

    private func adoptDiskMap(_ levels: [DiskLevel], run: Int, finished: Bool) {
        guard run == diskMapRun else { return }
        // An earlier, complete measurement of a folder is not replaced by a partial one of the same folder's contents.
        for level in levels where finished || level.path == diskMapPath || diskMapLevels[level.path] == nil { diskMapLevels[level.path] = level }
        refreshDiskMapFacts()
        guard finished else { return }
        isMeasuringDiskMap = false
        // The largest folders are kept, so the map opens at once next time.
        let kept = diskMapLevels.values.filter(\.complete).sorted { $0.bytes > $1.bytes }.prefix(600)
        try? engine.store.saveCodable(Dictionary(uniqueKeysWithValues: kept.map { ($0.path, $0) }), key: Self.diskMapKey)
    }

    /// What PEPEL knows about each tile of the folder on screen.
    func refreshDiskMapFacts() {
        guard let level = diskMapLevel else { return }
        let items = (storage?.items ?? []).filter { !$0.hasPseudoPath }
        let home = engine.paths.home
        var facts: [String: DiskTileFacts] = [:]
        // The folder on screen and, for the tiles drawn inside its folders, one level below.
        let nodes = level.nodes + level.nodes.filter { $0.kind == .folder }.flatMap { diskMapLevels[$0.path]?.nodes.prefix(60) ?? [] }
        for node in nodes where node.kind == .folder || node.kind == .file {
            var fact = DiskTileFacts()
            for item in items {
                if item.path == node.path || item.path.hasPrefix(node.path + "/") {
                    if item.safety != .protected { fact.reclaimable += item.reclaimableBytes }
                } else if node.path.hasPrefix(item.path + "/") {
                    // The tile lies inside something PEPEL knows as a whole.
                    if item.safety == .protected { fact.kept = true } else { fact.reclaimable = node.bytes }
                }
                if item.path == node.path, item.safety == .protected { fact.kept = true }
            }
            if PathUtil.keepMarker(at: node.path, stopAt: home) != nil { fact.kept = true }
            facts[node.id] = fact
        }
        diskMapFacts = facts
    }

    // MARK: Other places, logs and the disk forecast

    public var otherPlaces: [OtherPlace]?
    public var oldLogs: (bytes: Int64, count: Int) = (0, 0)
    public var diskForecast: DiskForecast?
    public var isMeasuringOther = false

    public func measureOtherPlaces() {
        guard !isMeasuringOther else { return }
        isMeasuringOther = true
        let days = settings.logDays
        diskForecast = engine.diskForecast()
        measureTemp()
        Task {
            androidEmulators = await engine.androidEmulators()
            systemImages = await engine.androidSystemImages()
            toolBackups = await engine.toolBackups(keep: settings.toolBackupsKeep, days: settings.toolBackupsDays)
        }
        Task {
            otherPlaces = await engine.otherPlaces()
            oldLogs = await engine.oldLogs(days: days)
            isMeasuringOther = false
        }
    }

    public var tempEntries: [TempEntry]?
    public var androidEmulators: [AndroidEmulator] = []
    public var systemImages: [AndroidSystemImage] = []
    public var toolBackups: [ToolBackup] = []

    public func cleanToolBackups() {
        Task {
            let result = await engine.cleanToolBackups(confirmed: true, initiator: .user)
            message = result.denial.map { L("Not done: \($0)") } ?? ([L("Removed \(result.removed) backups; free space grew by \(Bytes.format(result.bytes)), less than their size when they shared blocks with the live files.")] + result.skipped).joined(separator: " ")
            toolBackups = await engine.toolBackups(keep: settings.toolBackupsKeep, days: settings.toolBackupsDays)
        }
    }

    public func deleteUnusedSystemImages() {
        Task {
            var deleted = 0
            for image in systemImages where image.usedBy.isEmpty {
                if await engine.deleteSystemImage(image.id, confirmed: true, initiator: .user) == nil { deleted += 1 }
            }
            message = L("Deleted \(deleted) unused system images.")
            systemImages = await engine.androidSystemImages()
        }
    }
    public var largeFiles: LargeFilesReport?
    public var isFindingLargeFiles = false

    public func findLargeFiles() {
        guard !isFindingLargeFiles else { return }
        isFindingLargeFiles = true
        let guarded = diskMapReadsGuarded
        Task {
            largeFiles = await engine.largeFiles(includeGuarded: guarded)
            isFindingLargeFiles = false
        }
    }

    public func deleteAndroidEmulators(_ names: [String]) {
        Task {
            var deleted = 0
            var notes: [String] = []
            for name in names {
                if let refusal = await engine.deleteAndroidEmulator(name, confirmed: true, initiator: .user) { notes.append("\(name): \(refusal)") } else { deleted += 1 }
            }
            message = ([L("Deleted \(deleted) emulators.")] + notes).joined(separator: " ")
            androidEmulators = await engine.androidEmulators()
            measureOtherPlaces()
        }
    }

    public func measureTemp() {
        Task { tempEntries = await engine.tempEntries() }
    }

    public func cleanTemp() {
        Task {
            let result = await engine.cleanTemp(confirmed: true, initiator: .user)
            message = result.denial.map { L("Not done: \($0)") } ?? L("Removed \(result.removed) temporary entries, \(Bytes.format(result.bytes)).")
            measureTemp()
        }
    }

    public func removeOldLogs() {
        Task {
            let result = await engine.removeOldLogs(confirmed: true, initiator: .user)
            message = result.denial.map { L("Not done: \($0)") } ?? L("Removed \(result.removed) log files, \(Bytes.format(result.bytes)).")
            measureOtherPlaces()
        }
    }

    // MARK: Application caches and leftovers

    public var appCaches: [ApplicationData]?
    public var appLeftovers: [ApplicationData] = []
    public var isMeasuringAppData = false

    public func measureApplicationData() {
        guard !isMeasuringAppData else { return }
        isMeasuringAppData = true
        Task {
            let data = await engine.applicationData()
            appCaches = data.caches
            appLeftovers = data.leftovers
            isMeasuringAppData = false
        }
    }

    public func cleanApplicationCaches(includeUnknown: Bool) {
        isMeasuringAppData = true
        Task {
            let result = await engine.cleanApplicationCaches(includeUnknown: includeUnknown, confirmed: true, initiator: .user)
            isMeasuringAppData = false
            message = result.denial.map { L("Not done: \($0)") } ?? result.report.map { L("Removed \($0.removed.count) caches, \(Bytes.format($0.bytes)).") }
            measureApplicationData()
            refreshSecondary()
        }
    }

    public func trashLeftovers() {
        isMeasuringAppData = true
        Task {
            let result = await engine.trashApplicationLeftovers(confirmed: true, initiator: .user)
            isMeasuringAppData = false
            message = result.denial.map { L("Not done: \($0)") } ?? result.report.map { L("Moved \($0.removed.count) folders (\(Bytes.format($0.bytes))) to the Trash.") }
            measureApplicationData()
        }
    }

    // MARK: Tool caches

    public var managedCaches: [ManagedCache]?
    public var isMeasuringCaches = false
    public var isTrimmingCaches = false

    public func measureCaches() {
        guard !isMeasuringCaches else { return }
        isMeasuringCaches = true
        let days = settings.cacheUnusedDays
        Task {
            managedCaches = await engine.managedCaches(days: days)
            isMeasuringCaches = false
        }
    }

    public func trimCaches() {
        isTrimmingCaches = true
        Task {
            let result = await engine.trimCaches(confirmed: true, initiator: .user)
            isTrimmingCaches = false
            message = result.denial.map { L("Not done: \($0)") }
                ?? result.report.map { $0.steps.isEmpty ? L("Nothing to remove.") : L("Removed \(Bytes.format($0.bytes)) from \($0.steps.count) caches. Disk available \(Bytes.format($0.diskAvailableBefore)) → \(Bytes.format($0.diskAvailableAfter)).") }
            measureCaches()
            refreshSecondary()
        }
    }

    // MARK: Downloads and screenshots

    public var tidyItems: [TidyItem]?
    public var isTidying = false

    public func measureTidy() {
        Task { tidyItems = await engine.tidyItems() }
    }

    public func runTidy() {
        isTidying = true
        Task {
            let result = await engine.runTidy(screenshots: true, downloads: true, confirmed: true, initiator: .user)
            isTidying = false
            message = result.denial.map { L("Not done: \($0)") } ?? (settings.tidyAction == .trash ? L("Moved to the Trash: \(result.removed) items, \(Bytes.format(result.bytes)).") : L("Removed: \(result.removed) items, \(Bytes.format(result.bytes))."))
            measureTidy()
        }
    }

    // MARK: Applications open without windows

    public var windowlessApps: [WindowlessApp] = []

    public func refreshWindowlessApps() {
        Task { windowlessApps = await engine.windowlessApps() }
    }

    public func setQuitWhenWindowless(_ app: WindowlessApp, _ on: Bool) {
        Task {
            try? await engine.setQuitWhenWindowless(app.bundleID, on)
            settings = await engine.currentSettings()
            windowlessApps = await engine.windowlessApps()
        }
    }

    // MARK: Large ignored folders

    public var ignoredFolders: [IgnoredFolder]?
    public var isFindingIgnored = false

    public func findIgnoredFolders() {
        guard !isFindingIgnored else { return }
        isFindingIgnored = true
        Task {
            ignoredFolders = await engine.ignoredFolders()
            isFindingIgnored = false
        }
    }

    public func trashIgnoredFolder(_ folder: IgnoredFolder) {
        Task {
            if let refusal = await engine.trashIgnoredFolder(folder.path, confirmed: true, initiator: .user) {
                message = L("Not moved: \(refusal)")
            } else {
                message = L("\(folder.projectName) · \((folder.path as NSString).lastPathComponent) moved to the Trash (\(Bytes.format(folder.bytes))).")
                ignoredFolders?.removeAll { $0.id == folder.id }
            }
        }
    }

    // MARK: Untouched projects

    public var staleProjects: [StaleProject] = []
    public var isCleaningStale = false

    public func refreshStaleProjects() {
        Task { staleProjects = await engine.staleProjects() }
    }

    public func cleanStaleProjects() {
        isCleaningStale = true
        Task {
            let report = await engine.cleanStaleProjects(confirmed: true, initiator: .user)
            isCleaningStale = false
            message = report.map { L("Removed \($0.succeededCount) of \($0.outcomes.count) items. Disk available \(Bytes.format($0.diskAvailableBefore)) → \(Bytes.format($0.diskAvailableAfter)).") } ?? L("Nothing to remove.")
            scanNow()
            refreshSecondary()
        }
    }

    // MARK: Docker on disk

    public var dockerDisk: DockerDiskReport?
    public var dockerPlan: DockerCleanupPlan?
    public var dockerCleanReport: DockerCleanupReport?
    public var isReadingDocker = false
    public var isCleaningDocker = false

    public func refreshDocker() {
        guard !isReadingDocker, !isCleaningDocker else { return }
        isReadingDocker = true
        Task {
            if let result = await engine.dockerCleanupPlan() {
                dockerDisk = result.report
                dockerPlan = result.plan
            } else {
                dockerDisk = nil
                dockerPlan = nil
            }
            isReadingDocker = false
        }
    }

    public var namedVolumes: [NamedVolumeReport]?

    public func refreshNamedVolumes() {
        Task { namedVolumes = await engine.namedVolumes() }
    }

    public func cleanDocker(_ kinds: Set<DockerCleanKind>) {
        isCleaningDocker = true
        Task {
            let result = await engine.cleanDocker(kinds: kinds, confirmed: true, initiator: .user)
            isCleaningDocker = false
            dockerCleanReport = result.report
            if let denial = result.denial { message = L("Not done: \(denial)") }
            refreshDocker()
            refreshSecondary()
        }
    }

    public func compactDocker() {
        isCleaningDocker = true
        let engine = engine
        Task {
            let outcome = await Task.detached(priority: .utility) { engine.dockerDiskCompact() }.value
            isCleaningDocker = false
            message = outcome.done ? L("Trimmed: \(outcome.note)") : L("Not trimmed: \(outcome.note)")
            refreshDocker()
        }
    }

    // MARK: Memory journal

    public var journalDigest: JournalDigest?
    public var journalFiles: (days: Int, bytes: Int64) = (0, 0)
    public var journalPath: String { engine.journal.directory }

    public func refreshJournal(days: Double = 7) {
        let engine = engine
        Task {
            let result = await Task.detached(priority: .utility) { (engine.journalDigest(days: days), engine.journal.files()) }.value
            journalDigest = result.0
            journalFiles = (result.1.count, result.1.reduce(0) { $0 + $1.bytes })
        }
    }

    public func revealJournal() {
        try? FileManager.default.createDirectory(atPath: journalPath, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: journalPath))
    }

    // MARK: Daily summary

    public var summary: DailySummary?
    private var lastSummaryAt: Date? = {
        let stored = UserDefaults.standard.double(forKey: "PEPELLastSummaryAt")
        return stored > 0 ? Date(timeIntervalSince1970: stored) : Date()
    }()

    public func refreshSummary() {
        let hours = settings.summaryFrequency == .daily ? 24.0 : 24 * 7
        Task { summary = await engine.summary(hours: hours) }
    }

    /// Once a day or once a week, at the chosen time or the first time PEPEL runs after it.
    private func postSummaryIfDue() {
        let now = Date(), frequency = settings.summaryFrequency
        guard settings.notificationsEnabled,
            frequency.isDue(lastPosted: lastSummaryAt, now: now, weekday: settings.summaryWeekday, hour: settings.dailySummaryHour)
        else { return }
        lastSummaryAt = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "PEPELLastSummaryAt")
        Task {
            let result = await engine.summary(hours: frequency.hours)
            summary = result
            let waiting = result.open.prefix(2).joined(separator: " ")
            let open = result.open.isEmpty ? "" : " " + L("Waiting for you: \(waiting)")
            Notifier.post(
                id: "summary-\(Int(now.timeIntervalSince1970))", title: frequency == .weekly ? L("PEPEL, this week") : L("PEPEL, last 24 hours"),
                body: result.headline + " " + result.done.prefix(3).joined(separator: " ") + open)
        }
    }

    // MARK: Docker VM memory limit

    public var pendingVMLimit: VMLimitDecision?

    public func requestVMLimit(gib: Int) {
        Task { pendingVMLimit = await engine.vmLimitDecision(Int64(gib) << 30, initiator: .user) }
    }

    public func confirmVMLimit() {
        guard let pending = pendingVMLimit else { return }
        pendingVMLimit = nil
        isRefreshingVM = true
        Task {
            let result = await engine.setContainerVMLimit(pending.newLimitBytes, confirmed: true, initiator: .user)
            isRefreshingVM = false
            vmRefreshReport = result?.report ?? vmRefreshReport
            message = result?.report.map { $0.steps.joined(separator: " ") } ?? L("The limit was not changed.")
            live = await engine.live
            refreshSecondary()
        }
    }

    // MARK: Agents' instruction files

    public struct InstructionFile: Identifiable, Sendable {
        public var agent: String
        public var path: String
        public var installed: Bool
        public var id: String { path }
    }

    public var instructionFiles: [InstructionFile] = []

    public func refreshInstructionFiles() {
        instructionFiles = AgentInstructions.status(home: engine.paths.home).map {
            InstructionFile(agent: $0.0.agent.displayName, path: PathUtil.display($0.0.path, home: engine.paths.home), installed: $0.1)
        }
    }

    public func installInstructions() {
        _ = AgentInstructions.install(home: engine.paths.home, settings: settings, backupDirectory: engine.paths.supportDirectory + "/instruction-backups")
        refreshInstructionFiles()
    }

    public func removeInstructions() {
        _ = AgentInstructions.remove(home: engine.paths.home)
        refreshInstructionFiles()
    }

    // MARK: Applications

    public var pendingApplication: ApplicationDecision?

    public func requestApplication(_ action: ApplicationAction, bundlePath: String) {
        Task { pendingApplication = await engine.applicationDecision(action, bundlePath: bundlePath, initiator: .user) }
    }

    public func confirmApplication() {
        guard let pending = pendingApplication else { return }
        pendingApplication = nil
        Task {
            message = await engine.performApplication(pending.action, bundlePath: pending.bundlePath, confirmed: true, initiator: .user).map {
                $0.quit ? $0.note + " " + L("Charged \(Bytes.format($0.footprintBefore)) before, \(Bytes.format($0.footprintAfter)) after.") : $0.note
            }
            live = await engine.live
            refreshSecondary()
        }
    }

    public func shutdownSimulator(_ simulator: BootedSimulator) {
        Task {
            message = await engine.shutdownSimulator(udid: simulator.udid, initiator: .user).note
            live = await engine.live
        }
    }

    // MARK: Containers

    public var pendingVMRefresh: VMRefreshDecision?
    public var vmRefreshReport: VMRefreshReport?
    public var isRefreshingVM = false

    public func requestVMRefresh() {
        Task { pendingVMRefresh = await engine.vmRefreshDecision(initiator: .user)?.decision }
    }

    public func confirmVMRefresh() {
        pendingVMRefresh = nil
        isRefreshingVM = true
        Task {
            vmRefreshReport = await engine.refreshContainerVM(confirmed: true, initiator: .user)?.report
            isRefreshingVM = false
            live = await engine.live
            refreshSecondary()
        }
    }

    public func pauseContainers(_ group: ContainerGroup) {
        Task {
            if let result = await engine.stopContainers(groupID: group.id, confirmed: true, initiator: .user, action: .pause) {
                message = result.report.map { L("Paused \($0.stopped.count) containers of \($0.groupName). They continue when an agent session starts in the project, or with Resume.") }
                    ?? L("Not paused: \(result.decision.reasons.joined(separator: " "))")
            }
            live = await engine.refreshLive()
        }
    }

    public func resumeContainers(_ group: ContainerGroup) {
        Task {
            let resumed = await engine.resumeContainers(groupID: group.id, reason: "you asked")
            message = L("Resumed \(resumed.count) containers of \(group.name).")
            live = await engine.refreshLive()
        }
    }

    public func stopContainers(_ group: ContainerGroup) {
        Task {
            if let result = await engine.stopContainers(groupID: group.id, confirmed: true, initiator: .user) {
                message = result.report.map { report in
                    let failed = report.failed.joined(separator: ", ")
                    return ([L("Stopped \(report.stopped.count) containers of \(report.groupName).")] + (report.failed.isEmpty ? [] : [L("Not stopped: \(failed).")])).joined(separator: " ")
                }
                    ?? L("Not stopped: \(result.decision.reasons.joined(separator: " "))")
            }
            live = await engine.refreshLive()
            refreshSecondary()
        }
    }

    public func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    public func open(_ section: DashboardSection) {
        self.section = section
        if section == .cleanup { prepareCleanup() }
    }
}
