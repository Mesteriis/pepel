import Darwin
import Foundation

/// Suspending quiet agent sessions.
///
/// A suspended tree gets no CPU at all, so its pages are never touched again and are the first
/// macOS compresses and swaps out when memory is wanted. Nothing is lost. Three things wake a
/// tree: its application coming to the front, a short periodic peek that finds work waiting, and
/// PEPEL stopping (quit, pause, the rule being switched off). The list of what is suspended lives
/// in the store, so a PEPEL that starts after a crash wakes what the previous one left.
extension PepelEngine {
    static let frozenKey = "frozen.trees"
    static let wokenKey = "frozen.woken"

    /// When each session was last woken. A session that was just woken, because someone came
    /// back to it or because work arrived, is left alone for a full quiet period.
    nonisolated func wokenAt() -> [String: Date] { store.loadCodable([String: Date].self, key: Self.wokenKey) ?? [:] }
    nonisolated static func wokenID(_ root: ProcessIdentity) -> String { "\(root.pid):\(root.startTime)" }
    /// A peek lasts at least this long before PEPEL decides.
    static let peekSeconds: TimeInterval = 20
    /// Share of one core over the peek that counts as "work was waiting".
    static let peekBusyFraction = 0.05

    public nonisolated func frozenTrees() -> [FrozenTree] { store.loadCodable([FrozenTree].self, key: Self.frozenKey) ?? [] }
    nonisolated func saveFrozen(_ trees: [FrozenTree]) { try? store.saveCodable(trees, key: Self.frozenKey) }

    /// Tells the engine how to find the application in front. Without it nothing is suspended automatically.
    public func setFrontmostProvider(_ provider: @escaping @Sendable () -> Int32?) { frontmostPID = provider }

    /// The outermost application bundle among a process's ancestors.
    static func ownerApp(of root: ProcessSnapshot, tree: ProcessTree) -> ProcessSnapshot? {
        tree.ancestors(of: root).last { $0.executablePath?.contains(".app/Contents/MacOS/") ?? false }
    }

    nonisolated func signal(_ sig: Int32, _ identities: [ProcessIdentity]) -> Int {
        var delivered = 0
        // Only the very process that was assessed: a reused PID is somebody else.
        for identity in identities where processSource.identity(of: identity.pid) == identity {
            if processSource.send(sig, to: identity.pid) { delivered += 1 }
        }
        return delivered
    }

    public func freezeDecision(_ root: ProcessIdentity, initiator: Initiator) async -> (decision: FreezeDecision, members: [ProcessSnapshot], owner: ProcessSnapshot?)? {
        let liveState = await refreshLive()
        let tree = ProcessTree(lastProcesses)
        guard let session = liveState.agentSessions.first(where: { $0.root == root }), let rootProcess = tree.process(root) else { return nil }
        let members = [rootProcess] + tree.descendants(of: rootProcess)
        let owner = Self.ownerApp(of: rootProcess, tree: tree)
        let own = processSource.snapshot().first { $0.pid == getpid() }
        let ancestors = Set(own.map { tree.ancestors(of: $0).map(\.pid) } ?? [])
        let decision = policy.evaluateFreeze(
            session, members: members, ownerAppPID: owner?.pid, frontmostPID: frontmostPID(), initiator: initiator, settings: effectiveSettings,
            ownAncestors: ancestors)
        return (decision, members, owner)
    }

    /// Suspends one agent session with everything it started, if policy allows it.
    @discardableResult
    public func freeze(_ root: ProcessIdentity, confirmed: Bool, initiator: Initiator) async -> FreezeDecision? {
        guard let (decision, members, owner) = await freezeDecision(root, initiator: initiator) else { return nil }
        guard let approved = policy.approveFreeze(decision, members: members.map(\.identity), confirmed: confirmed, initiator: initiator) else { return decision }
        let now = Date()
        // Children first, so a parent never sees a child stop while it is still running itself.
        _ = signal(SIGSTOP, approved.members.reversed())
        var trees = frozenTrees().filter { $0.root != root }
        trees.append(
            FrozenTree(
                root: root, members: approved.members, name: "\(decision.session.kind.displayName) · \(decision.session.projectID.map { ($0 as NSString).lastPathComponent } ?? "no project")",
                frozenAt: now, initiator: initiator.rawValue, ownerAppPID: owner?.pid, ownerAppName: owner?.name,
                nextPeek: now.addingTimeInterval(TimeInterval(settings.freezePeekMinutes) * 60),
                footprintBytes: members.reduce(0) { $0 + $1.footprintBytes }, residentBytesAtFreeze: members.reduce(0) { $0 + $1.residentBytes }))
        saveFrozen(trees)
        store.appendAudit(
            AuditEntry(
                kind: .termination, initiator: initiator.rawValue, subject: "\(decision.session.kind.displayName) (PID \(root.pid))", outcome: "suspended",
                detail: ["processes": "\(approved.members.count)", "inRAM": Bytes.format(members.reduce(0) { $0 + $1.residentBytes }), "wakes": owner.map { "when \($0.name) comes to the front" } ?? "by hand"]))
        await refreshLive()
        return decision
    }

    /// Wakes one suspended tree. Returns false when it was not suspended.
    @discardableResult
    public nonisolated func thaw(_ root: ProcessIdentity, reason: String, now: Date = Date()) -> Bool {
        var trees = frozenTrees()
        guard let index = trees.firstIndex(where: { $0.root == root }) else { return false }
        let tree = trees.remove(at: index)
        saveFrozen(trees)
        _ = signal(SIGCONT, tree.members)
        var woken = wokenAt().filter { now.timeIntervalSince($0.value) < 86_400 }
        woken[Self.wokenID(root)] = now
        try? store.saveCodable(woken, key: Self.wokenKey)
        store.appendAudit(
            AuditEntry(
                kind: .termination, initiator: "engine", subject: "\(tree.name) (PID \(root.pid))", outcome: "woken",
                detail: ["reason": reason, "suspendedFor": TimeFormat.age(Date().timeIntervalSince(tree.frozenAt))]))
        return true
    }

    /// Wakes everything; safe to call from anywhere, also while the app is quitting.
    @discardableResult
    public nonisolated func thawAll(reason: String, onlyAutomatic: Bool = false) -> Int {
        let trees = frozenTrees().filter { !onlyAutomatic || $0.initiator == Initiator.automatic.rawValue }
        for tree in trees { thaw(tree.root, reason: reason) }
        return trees.count
    }

    static let lastFrontKey = "apps.lastFront"

    /// When each application (by PID) was last in front, as the app saw it come forward.
    nonisolated func lastFront() -> [Int32: Date] {
        let stored = store.loadCodable([String: Date].self, key: Self.lastFrontKey) ?? [:]
        return Dictionary(stored.compactMap { key, value in Int32(key).map { ($0, value) } }, uniquingKeysWith: { a, _ in a })
    }

    /// The application with this PID came to the front: wake what lives in it, right away.
    public nonisolated func applicationActivated(pid: Int32) {
        var stored = store.loadCodable([String: Date].self, key: Self.lastFrontKey) ?? [:]
        stored[String(pid)] = Date()
        // Applications that quit long ago fall out after a day.
        stored = stored.filter { Date().timeIntervalSince($0.value) < 86_400 }
        try? store.saveCodable(stored, key: Self.lastFrontKey)
        for tree in frozenTrees() where tree.ownerAppPID == pid { thaw(tree.root, reason: "\(tree.ownerAppName ?? "its application") came to the front") }
    }

    /// One pass of the suspension rule: wake, peek, and suspend what has gone quiet.
    func freezePass(now: Date = Date()) async {
        var trees = frozenTrees()
        guard !trees.isEmpty || settings.freezeIdleAgents else { return }
        if settings.paused || !settings.freezeIdleAgents {
            // The rule is off: nothing it suspended stays suspended.
            thawAll(reason: settings.paused ? "PEPEL is paused" : "suspending is switched off", onlyAutomatic: true)
            if settings.paused || trees.allSatisfy({ $0.initiator == Initiator.automatic.rawValue }) { return }
            trees = frozenTrees()
        }
        let processes = lastProcesses
        let tree = ProcessTree(processes)
        let front = frontmostPID()

        for frozen in trees {
            guard let root = tree.process(frozen.root) else {
                // The session is gone (ended by its application or by hand); wake what is left of it.
                thaw(frozen.root, reason: "the session ended", now: now)
                continue
            }
            if let owner = frozen.ownerAppPID, owner == front {
                thaw(frozen.root, reason: "\(frozen.ownerAppName ?? "its application") is in front", now: now)
                continue
            }
            let members = [root] + tree.descendants(of: root)
            let cpu = members.reduce(UInt64(0)) { $0 + $1.cpuTimeNs }
            var updated = frozen
            if let started = frozen.peekStarted {
                let elapsed = now.timeIntervalSince(started)
                guard elapsed >= Self.peekSeconds else { continue }
                let used = Double(cpu &- frozen.peekCPUNs) / 1e9
                if cpu >= frozen.peekCPUNs, used >= elapsed * Self.peekBusyFraction {
                    thaw(frozen.root, reason: String(format: "work was waiting: it used %.1f s of CPU in a %d s peek", used, Int(elapsed)), now: now)
                    continue
                }
                // Nothing was waiting. Whatever the tree started meanwhile is suspended with it.
                updated.members = members.map(\.identity)
                _ = signal(SIGSTOP, updated.members.reversed())
                updated.peekStarted = nil
                updated.nextPeek = now.addingTimeInterval(TimeInterval(settings.freezePeekMinutes) * 60)
            } else if now >= frozen.nextPeek {
                _ = signal(SIGCONT, frozen.members)
                updated.peekStarted = now
                updated.peekCPUNs = cpu
            } else {
                continue
            }
            var current = frozenTrees()
            if let index = current.firstIndex(where: { $0.root == frozen.root }) {
                current[index] = updated
                saveFrozen(current)
            }
        }

        guard settings.freezeIdleAgents, let live else { return }
        // With memory to spare a suspended session saves nothing: its pages stay in RAM until macOS
        // needs them, and waking it again (as soon as its application comes forward) is pure churn.
        if settings.freezeOnlyUnderPressure, live.telemetry.pressure == .normal, live.forecast == nil { return }
        let suspended = Set(frozenTrees().map(\.root))
        let woken = wokenAt()
        let threshold = TimeInterval(effectiveSettings.freezeAfterMinutes) * 60
        let processTree = ProcessTree(processSource.snapshot())
        let fronted = lastFront(), inFront = frontmostPID()
        for session in live.agentSessions where !session.isService && session.hostApp == nil && session.state != .working && !suspended.contains(session.root) {
            if let last = woken[Self.wokenID(session.root)], now.timeIntervalSince(last) < threshold { continue }
            // A session whose application was in front lately is likely to be looked at again soon.
            if let root = processTree.process(session.root), let owner = Self.ownerApp(of: root, tree: processTree) {
                if owner.pid == inFront { continue }
                if let last = fronted[owner.pid], now.timeIntervalSince(last) < threshold { continue }
            }
            // Cheap check first; `freeze` decides again on a fresh sample.
            let quiet = session.quietSince.map { now.timeIntervalSince($0) } ?? 0
            guard quiet >= threshold else { continue }
            _ = await freeze(session.root, confirmed: false, initiator: .automatic)
        }
    }
}
