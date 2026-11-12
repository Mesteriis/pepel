import AppKit
import Observation
import PEPELEngine
import SwiftUI

/// The Startup section's state: what macOS starts on its own, and switching agents off and on.
@MainActor
@Observable
public final class StartupModel {
    let engine: PepelEngine

    public var items: [StartupItem]?
    public var isLoading = false
    /// The item waiting for the person to confirm switching it off or on.
    public var pending: StartupItem?
    public var message: String?

    init(engine: PepelEngine) { self.engine = engine }

    /// Seen for the first time within the last week.
    public var newCount: Int {
        let week = Date().addingTimeInterval(-7 * 86_400)
        return items?.filter { ($0.firstSeen ?? .distantPast) > week }.count ?? 0
    }

    public func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            let fresh = await engine.startupItems()
            withAnimation(.easeOut(duration: 0.2)) { items = fresh }
            isLoading = false
        }
    }

    public func confirm() {
        guard let item = pending else { return }
        pending = nil
        let enable = item.disabled
        Task {
            if let problem = await engine.setStartupItem(item.label, enabled: enable, confirmed: true, initiator: .user) {
                message = L("\(item.owner): \(problem)")
            } else {
                message = enable ? L("\(item.owner) is switched on again.") : L("\(item.owner) is switched off: it stopped and will not start at login.")
            }
            isLoading = false
            refresh()
        }
    }

    public func reveal(_ item: StartupItem) {
        guard let path = item.plistPath ?? item.program else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
