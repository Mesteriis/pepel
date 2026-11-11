import Observation
import PEPELEngine
import SwiftUI

/// The plan for the next day, the restore center and PEPEL watching itself. Kept apart from
/// `AppModel`, which mirrors everything else.
@MainActor
@Observable
public final class ActivityModel {
    let engine: PepelEngine

    public var plan: ActionPlan?
    public var isPlanning = false
    public var restore: RestoreCenter?
    public var selfUsage: SelfUsage?
    public var selfWarning: String?
    public var message: String?
    private var warnedAt = Date.distantPast

    init(engine: PepelEngine) { self.engine = engine }

    // MARK: Plan

    public func refreshPlan() {
        guard !isPlanning else { return }
        isPlanning = true
        Task {
            let result = await engine.actionPlan()
            withAnimation(.easeOut(duration: 0.2)) { plan = result }
            isPlanning = false
        }
    }

    /// Takes the item out of the plan for good: the rule will pass it by until it is put back.
    public func leaveAlone(_ action: RuleAction) {
        Task {
            _ = try? await engine.setLeftAlone([action.id], true)
            withAnimation(.easeOut(duration: 0.2)) { plan?.actions.removeAll { $0.id == action.id } }
            message = L("\(action.title) will be left alone. Settings › Leave alone lists it.")
        }
    }

    public func forgetLeaveAlone(_ id: String) {
        Task {
            _ = try? await engine.setLeftAlone([id], false)
            refreshPlan()
        }
    }

    // MARK: Restore center

    public func refreshRestore() {
        let engine = engine
        Task.detached(priority: .utility) {
            let center = engine.restoreCenter()
            await MainActor.run { self.restore = center }
        }
    }

    public func restore(_ record: TrashRecord) {
        if let problem = engine.restoreTrashed(id: record.id) {
            message = L("Could not put \(record.name) back: \(problem)")
        } else {
            message = L("\(record.name) is back in \(PathUtil.display((record.originalPath as NSString).deletingLastPathComponent)).")
        }
        refreshRestore()
    }

    // MARK: PEPEL itself

    func refreshSelf(heavyTasks: [String], limitMB: Int, notify: Bool) {
        engine.setHeavyTasks(heavyTasks)
        Task {
            let usage = await engine.selfUsage()
            selfUsage = usage
            selfWarning = usage.warning(memoryLimitMB: limitMB)
            // Said once an hour at most; the sidebar shows it all along.
            if let warning = selfWarning, notify, Date().timeIntervalSince(warnedAt) > 3600 {
                warnedAt = Date()
                Notifier.post(id: "pepel-self", title: L("PEPEL is in the way"), body: warning)
            }
        }
    }
}
