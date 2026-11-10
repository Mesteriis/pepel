import Foundation

public enum EngineEvent: Sendable {
    case live(LiveState)
    case scanStarted
    case scanProgress(ScanProgress)
    case storage(StorageState)
    case alerts([PepelAlert])
    case automatic(cleanup: CleanupReport?, terminations: [TerminationReport])
    case cadence(String)
}

/// The background loop. It sleeps between light samples for as long as the cadence policy says,
/// and starts a storage scan only when one is due, something changed, and no build is running.
public actor MonitorService {
    private let engine: PepelEngine
    private let watcher = ChangeWatcher()
    private var loop: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var lastFullScan: Date?
    private var wake: CheckedContinuation<Void, Never>?
    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]
    private var watchedRoots: [String] = []
    private var lastPrune = Date.distantPast

    public init(engine: PepelEngine) {
        self.engine = engine
    }

    public func events() -> AsyncStream<EngineEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.remove(id) }
            }
        }
    }

    private func remove(_ id: UUID) { continuations[id] = nil }

    private func emit(_ event: EngineEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = await self.tick()
                await self.sleep(seconds: interval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        scanTask?.cancel()
        watcher.stop()
    }

    /// Wakes the loop early (settings changed, popover opened).
    public func poke() {
        wake?.resume()
        wake = nil
    }

    private func sleep(seconds: TimeInterval) async {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            await self?.poke()
        }
        await withCheckedContinuation { continuation in wake = continuation }
        timer.cancel()
    }

    private func updateWatcher(settings: PepelSettings) async {
        let home = engine.paths.home
        var roots = settings.projectRoots.map { PathUtil.canonical($0, home: home) }
        roots += [home + "/Library/Developer/Xcode/DerivedData", home + "/Library/Caches", home + "/.cache", home + "/.cargo", home + "/.npm"]
        roots += await engine.knownProjects().map(\.id).filter { root in !roots.contains { PathUtil.isInside(root, root: $0) } }
        roots = Array(Set(roots)).sorted()
        guard roots != watchedRoots || !watcher.isWatching else { return }
        watchedRoots = roots
        watcher.watch(paths: roots)
    }

    private func tick() async -> TimeInterval {
        let settings = await engine.currentSettings()
        let live = await engine.refreshLive()
        emit(.live(live))

        var conditions = MonitorConditions()
        conditions.paused = settings.paused
        conditions.mode = settings.monitoringMode
        conditions.onBattery = live.telemetry.onBattery
        conditions.batteryAware = settings.batteryAware
        conditions.userIdleSeconds = TelemetryReader.userIdleSeconds()
        conditions.pressure = live.telemetry.pressure
        conditions.activeBuilds = live.activeBuildCount
        conditions.inQuietHours = settings.quietHours.contains(hour: Calendar.current.component(.hour, from: Date()))
        conditions.diskLow = live.telemetry.diskAvailableBytes < settings.lowDiskThresholdBytes
        conditions.sinceLastFullScan = lastFullScan.map { Date().timeIntervalSince($0) }
        conditions.changesPending = lastFullScan == nil || watcher.hasChanges || !watcher.isWatching
        let cadence = CadencePolicy.cadence(for: conditions)
        emit(.cadence(cadence.reason))

        if cadence.runFullScan, scanTask == nil {
            await updateWatcher(settings: settings)
            startScan(incremental: true)
        }
        if !settings.paused {
            let result = await engine.automaticPass()
            if result.cleanup != nil || !result.terminations.isEmpty {
                emit(.automatic(cleanup: result.cleanup, terminations: result.terminations))
                if let storage = await engine.storage { emit(.storage(storage)) }
            }
        }
        emit(.alerts(await engine.alerts()))
        if Date().timeIntervalSince(lastPrune) > 6 * 3600 {
            lastPrune = Date()
            engine.store.prune()
        }
        return cadence.lightInterval
    }

    /// Starts a scan unless one is running. A manual scan measures everything again.
    public func requestScan(incremental: Bool = false) {
        guard scanTask == nil else { return }
        startScan(incremental: incremental)
    }

    public func cancelScan() { scanTask?.cancel() }

    public var isScanning: Bool { scanTask != nil }

    private func startScan(incremental: Bool) {
        emit(.scanStarted)
        let drained = watcher.drain()
        let changes: ChangeSet? = incremental && watcher.isWatching && lastFullScan != nil
            ? ChangeSet(paths: drained.paths, everything: drained.everything) : nil
        let service = self
        scanTask = Task { [engine] in
            let state = await engine.scan(changes: changes) { progress in
                Task { await service.emit(.scanProgress(progress)) }
            }
            await service.finishScan(state)
        }
    }

    private func finishScan(_ state: StorageState) async {
        scanTask = nil
        if !state.scan.cancelled { lastFullScan = Date() }
        emit(.storage(state))
        emit(.alerts(await engine.alerts()))
    }
}
