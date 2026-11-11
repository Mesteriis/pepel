import AppKit
import Observation
import PEPELEngine
import SwiftUI

public enum DashboardSection: String, CaseIterable, Identifiable, Sendable {
    case overview, storage, memory, builds, projects, agents, cleanup, history, settings

    public var id: String { rawValue }
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    public var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .storage: "internaldrive"
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
        Task {
            let frontmost = frontmost
            await engine.setFrontmostProvider { frontmost.get() }
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
            Notifier.post(id: alert.id, title: alert.title, body: alert.message)
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

    public var fileCachePermission: (available: Bool, granted: Bool) = (false, false)

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
