import AppKit
import Observation
import PEPELEngine
import SwiftUI

public enum DashboardSection: String, CaseIterable, Identifiable, Sendable {
    case overview, storage, map, memory, builds, projects, agents, cleanup, history, settings

    public var id: String { rawValue }
    public var title: String { self == .map ? "Disk map" : rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

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
    public var apiStatus = "Not started"
    public var loginItemStatus = LoginItem.statusText

    public init(engine: PepelEngine) {
        self.engine = engine
        self.monitor = MonitorService(engine: engine)
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
            model.message = "PEPEL could not open its database (\(error)). Running without history."
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
                message = "Not suspended: \(decision.reasons.joined(separator: " "))"
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
            // Settings changed from the command line show up in the interface too.
            Task {
                let current = await engine.currentSettings()
                if current != settings { settings = current }
            }
        case .scanStarted:
            isScanning = true
            scanProgress = ScanProgress(phase: "Starting")
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
            postDailySummaryIfDue()
        case .automatic(let cleanup, let terminations):
            if let cleanup, cleanup.succeededCount > 0 {
                Notifier.post(
                    id: "auto-cleanup-\(Int(cleanup.finishedAt.timeIntervalSince1970))", title: "Safe cleanup finished",
                    body: "\(cleanup.succeededCount) item\(cleanup.succeededCount == 1 ? "" : "s") cleaned, up to \(Bytes.format(cleanup.estimatedBytes)).")
            }
            for report in terminations where report.exited {
                Notifier.post(
                    id: "auto-term-\(report.target.pid)", title: "PEPEL terminated \(report.name)",
                    body: "PID \(report.target.pid) had been idle past its threshold. It held \(Bytes.format(report.footprintBefore)) with its child processes.")
            }
            refreshSecondary()
        case .cadence(let reason):
            cadence = reason
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
                    id: "free-\(Int(report.finishedAt.timeIntervalSince1970))", title: "Memory freed",
                    body: "Memory used \(Bytes.format(report.before.memoryUsedBytes)) → \(Bytes.format(report.after.memoryUsedBytes)), free \(Bytes.format(report.before.freeBytes)) → \(Bytes.format(report.after.freeBytes)). \(done).")
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
            apiStatus = "Listening"
        } catch {
            apiStatus = "Unavailable: \(error)"
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
            menuBarNotice = "macOS is not showing PEPEL's menu bar icon. On macOS 27, \(running) hides apps that do not run from /Applications: install PEPEL there (Scripts/install.sh, or drag PEPEL.app into Applications), then expand \(running) and collapse it again. Opening PEPEL.app again shows this window."
        } else if let running {
            menuBarNotice = "macOS is not showing PEPEL's menu bar icon. \(running) hides every app that was not running when it last collapsed: expand \(running) and collapse it again, and the icon appears to the right of its arrow. Until then, opening PEPEL.app again shows this window."
        } else {
            menuBarNotice = "macOS is not showing PEPEL's menu bar icon. Check System Settings › Menu Bar › Allow in the Menu Bar, and whether the menu bar has room for it. Opening PEPEL.app again shows this window."
        }
        guard !menuBarNoticePosted else { return }
        menuBarNoticePosted = true
        Notifier.post(
            id: "menubar-hidden", title: "PEPEL's menu bar icon is hidden",
            body: running.map { "Expand \($0) and collapse it again to bring the icon back." } ?? "Check System Settings › Menu Bar.")
    }

    // MARK: Derived

    public var health: HealthLevel {
        if alerts.contains(where: { $0.severity == .critical }) { return .critical }
        if alerts.contains(where: { $0.severity == .warning }) || !(live?.abandoned.isEmpty ?? true) { return .attention }
        return .healthy
    }

    public var healthSentence: String {
        if settings.paused { return "Monitoring is paused." }
        switch health {
        case .critical: return alerts.first { $0.severity == .critical }?.title ?? "Needs attention now."
        case .attention:
            let count = live?.abandoned.count ?? 0
            return alerts.first { $0.severity == .warning }?.title ?? (count == 1 ? "One process looks abandoned." : "\(count) processes look abandoned.")
        case .healthy: return "Workstation is healthy."
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
        case .memoryPressure: return live.map { $0.telemetry.pressure == .normal ? "OK" : $0.telemetry.pressure.rawValue.capitalized }
        case .activeBuilds: return live.map { "\($0.activeBuildCount)" }
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
                message = "Settings could not be saved: \(error)"
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
            if pendingTermination == nil { message = "That process has already exited." }
        }
    }

    public func confirmTermination(force: Bool) {
        guard let decision = pendingTermination else { return }
        pendingTermination = nil
        Task {
            switch await engine.terminate(decision.target.process.identity, confirmed: true, force: force, initiator: .user) {
            case .completed(let report): terminationReport = report
            case .denied(let d), .needsConfirmation(let d): message = "Not terminated: \(d.reasons.joined(separator: " "))"
            case .notFound: message = "That process has already exited."
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
                message = "Could not add the protection: \(error)"
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
        message = engine.restore(trashedPath: trashed, originalPath: original).map { "Could not restore: \($0)" } ?? "Restored \(PathUtil.display(original))."
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
            if case .failed(let reason) = await engine.revokeFileCachePermission(initiator: .user) { message = "Not removed: \(reason)" }
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
            message = "Ended \(ended) of \(stale.count) old copies inside agent servers."
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
            message = "Unloaded \(done) of \(idle.count) idle browser tab processes."
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
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "This Mac"
    }

    /// The folder on screen with, at the top of the disk, one more tile for the space the disk
    /// reports as used but that no folder PEPEL may read accounts for.
    public var diskMapDisplayLevel: DiskLevel? {
        guard var level = diskMapLevel else { return nil }
        if level.path == "/", level.pending == 0, let t = live?.telemetry, t.diskTotalBytes > 0 {
            let rest = (t.diskTotalBytes - t.diskFreeBytes) - level.bytes
            if rest > max(Bytes.gb, level.bytes / 100) {
                level.nodes.append(DiskNode(path: "/", name: "Not measured", kind: .unmeasured, bytes: rest))
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
        diskMapTask = Task.detached(priority: .userInitiated) { [weak self] in
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
            otherPlaces = await engine.otherPlaces()
            oldLogs = await engine.oldLogs(days: days)
            isMeasuringOther = false
        }
    }

    public var tempEntries: [TempEntry]?

    public func measureTemp() {
        Task { tempEntries = await engine.tempEntries() }
    }

    public func cleanTemp() {
        Task {
            let result = await engine.cleanTemp(confirmed: true, initiator: .user)
            message = result.denial.map { "Not done: \($0)" } ?? "Removed \(result.removed) temporary entries, \(Bytes.format(result.bytes))."
            measureTemp()
        }
    }

    public func removeOldLogs() {
        Task {
            let result = await engine.removeOldLogs(confirmed: true, initiator: .user)
            message = result.denial.map { "Not done: \($0)" } ?? "Removed \(result.removed) log files, \(Bytes.format(result.bytes))."
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
            message = result.denial.map { "Not done: \($0)" } ?? result.report.map { "Removed \($0.removed.count) caches, \(Bytes.format($0.bytes))." }
            measureApplicationData()
            refreshSecondary()
        }
    }

    public func trashLeftovers() {
        isMeasuringAppData = true
        Task {
            let result = await engine.trashApplicationLeftovers(confirmed: true, initiator: .user)
            isMeasuringAppData = false
            message = result.denial.map { "Not done: \($0)" } ?? result.report.map { "Moved \($0.removed.count) folders (\(Bytes.format($0.bytes))) to the Trash." }
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
            message = result.denial.map { "Not done: \($0)" }
                ?? result.report.map { $0.steps.isEmpty ? "Nothing to remove." : "Removed \(Bytes.format($0.bytes)) from \($0.steps.count) caches. Disk available \(Bytes.format($0.diskAvailableBefore)) → \(Bytes.format($0.diskAvailableAfter))." }
            measureCaches()
            refreshSecondary()
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
            message = report.map { "Removed \($0.succeededCount) of \($0.outcomes.count) items. Disk available \(Bytes.format($0.diskAvailableBefore)) → \(Bytes.format($0.diskAvailableAfter))." } ?? "Nothing to remove."
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

    public func cleanDocker(_ kinds: Set<DockerCleanKind>) {
        isCleaningDocker = true
        Task {
            let result = await engine.cleanDocker(kinds: kinds, confirmed: true, initiator: .user)
            isCleaningDocker = false
            dockerCleanReport = result.report
            if let denial = result.denial { message = "Not done: \(denial)" }
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
            message = outcome.done ? "Trimmed: \(outcome.note)" : "Not trimmed: \(outcome.note)"
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
    private var lastSummaryDay = UserDefaults.standard.integer(forKey: "PEPELLastSummaryDay")

    public func refreshSummary() {
        Task { summary = await engine.summary() }
    }

    /// Once a day, at the chosen hour or the first time PEPEL runs after it.
    private func postDailySummaryIfDue() {
        let calendar = Calendar.current, now = Date()
        let day = calendar.ordinality(of: .day, in: .era, for: now) ?? 0
        guard settings.dailySummary, settings.notificationsEnabled, day != lastSummaryDay, calendar.component(.hour, from: now) >= settings.dailySummaryHour else { return }
        lastSummaryDay = day
        UserDefaults.standard.set(day, forKey: "PEPELLastSummaryDay")
        Task {
            let result = await engine.summary()
            summary = result
            let open = result.open.isEmpty ? "" : " Still there: " + result.open.prefix(2).joined(separator: " ")
            Notifier.post(id: "summary-\(day)", title: "PEPEL, last 24 hours", body: result.headline + " " + result.done.prefix(3).joined(separator: " ") + open)
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
            message = result?.report.map { $0.steps.joined(separator: " ") } ?? "The limit was not changed."
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
                $0.quit ? "\($0.note) Charged \(Bytes.format($0.footprintBefore)) before, \(Bytes.format($0.footprintAfter)) after." : $0.note
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
                message = result.report.map { "Paused \($0.stopped.count) container\($0.stopped.count == 1 ? "" : "s") of \($0.groupName). They continue when an agent session starts in the project, or with Resume." }
                    ?? "Not paused: \(result.decision.reasons.joined(separator: " "))"
            }
            live = await engine.refreshLive()
        }
    }

    public func resumeContainers(_ group: ContainerGroup) {
        Task {
            let resumed = await engine.resumeContainers(groupID: group.id, reason: "you asked")
            message = "Resumed \(resumed.count) container\(resumed.count == 1 ? "" : "s") of \(group.name)."
            live = await engine.refreshLive()
        }
    }

    public func stopContainers(_ group: ContainerGroup) {
        Task {
            if let result = await engine.stopContainers(groupID: group.id, confirmed: true, initiator: .user) {
                message = result.report.map { "Stopped \($0.stopped.count) container\($0.stopped.count == 1 ? "" : "s") of \($0.groupName)." + ($0.failed.isEmpty ? "" : " Not stopped: \($0.failed.joined(separator: ", ")).") }
                    ?? "Not stopped: \(result.decision.reasons.joined(separator: " "))"
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
