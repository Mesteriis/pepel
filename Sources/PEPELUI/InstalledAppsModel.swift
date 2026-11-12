import AppKit
import Observation
import PEPELEngine
import SwiftUI

/// The Apps section's state: installed applications, how much they are used, and removing them.
@MainActor
@Observable
public final class InstalledAppsModel {
    let engine: PepelEngine

    public var apps: [InstalledApp]?
    public var isLoading = false
    public var pending: InstalledApp?
    public var message: String?

    init(engine: PepelEngine) { self.engine = engine }

    public var suggested: [InstalledApp] { apps?.filter(\.isSuggested) ?? [] }

    public func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            let fresh = await engine.installedApps()
            withAnimation(.easeOut(duration: 0.2)) { apps = fresh }
            isLoading = false
        }
    }

    public func uninstall(_ app: InstalledApp, withData: Bool) {
        pending = nil
        Task {
            let result = await engine.uninstallApp(app.path, includeData: withData, confirmed: true, initiator: .user)
            if let denial = result.denial {
                message = L("\(app.name): \(denial)")
            } else {
                message = L("\(app.name) is in the Trash (\(Bytes.format(result.bytes))). It can be put back from the Overview until the Trash is emptied.")
                withAnimation(.easeOut(duration: 0.2)) { apps?.removeAll { $0.path == app.path } }
            }
        }
    }

    public func keep(_ app: InstalledApp, model: AppModel) {
        model.updateSettings { s in if !s.keepApplications.contains(where: { $0.lowercased() == app.bundleID.lowercased() }) { s.keepApplications.append(app.bundleID) } }
        if let index = apps?.firstIndex(where: { $0.path == app.path }) { apps?[index].keptBecause = L("It is on the keep list.") }
    }

    public func reveal(_ app: InstalledApp) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }

    public func icon(_ app: InstalledApp) -> NSImage { NSWorkspace.shared.icon(forFile: app.path) }
}
