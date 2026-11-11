import PEPELEngine
import SwiftUI

struct StorageSection: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var filter: SafetyClass?
    @State private var expanded: String?
    @State private var confirmDocker = false
    @State private var confirmVolumes = false
    @State private var confirmCaches = false
    @State private var confirmAppCaches = false
    @State private var confirmUnknownCaches = false
    @State private var confirmLeftovers = false
    @State private var confirmLogs = false
    @State private var confirmTemp = false
    @State private var chosenEmulators = Set<String>()
    @State private var confirmEmulators = false
    @State private var confirmImages = false
    @State private var confirmBackups = false
    @State private var confirmTidy = false

    private func matches(_ item: StorageItem) -> Bool {
        if let filter, item.safety != filter { return false }
        guard !search.isEmpty else { return true }
        let needle = search.lowercased()
        return item.title.lowercased().contains(needle) || item.path.lowercased().contains(needle)
            || item.category.displayName.lowercased().contains(needle)
            || (model.projectName(item.projectID)?.lowercased().contains(needle) ?? false)
    }

    /// Old screenshots and downloads.
    @ViewBuilder private var tidy: some View {
        let s = model.settings
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Caption("Downloads and screenshots")
                Spacer()
                if model.isTidying { ProgressView().controlSize(.small) }
                if let items = model.tidyItems {
                    let going = items.filter { $0.keptBecause == nil }
                    Button("\(s.tidyAction == .trash ? "Move to Trash" : "Remove") \(going.count) · \(Bytes.format(going.reduce(0) { $0 + $1.bytes }))…") { confirmTidy = true }
                        .buttonStyle(CopperButtonStyle(prominent: false)).disabled(going.isEmpty || model.isTidying)
                }
            }
            if let items = model.tidyItems {
                let going = items.filter { $0.keptBecause == nil }
                let shots = going.filter { $0.kind == .screenshot }
                Text("\(shots.count) screenshots and recordings older than \(s.screenshotDays) day\(s.screenshotDays == 1 ? "" : "s") · \(going.count - shots.count) downloads unused for \(s.downloadDays) days or unfinished · \(items.count - going.count) kept")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                ForEach(going.prefix(8)) { item in
                    HStack(spacing: 10) {
                        Badge(text: item.kind == .screenshot ? "screenshot" : item.kind == .partial ? "unfinished" : "download", tint: Theme.tertiary)
                        Text(item.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("used \(TimeFormat.ago(item.lastUse))").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary)
                        Text(Bytes.format(item.bytes)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 70, alignment: .trailing)
                    }
                }
                if going.count > 8 { Text("and \(going.count - 8) more").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
            }
            Text("Screenshots are recognised by the mark macOS puts on them, never by name, and nothing else on the Desktop is touched. Kept in Downloads: \(s.tidyKeepExtensions.joined(separator: ", ")), anything with a Finder tag, and anything opened recently.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .panel()
        .onAppear { if model.tidyItems == nil { model.measureTidy() } }
        .confirmationDialog("Tidy Downloads and screenshots?", isPresented: $confirmTidy, titleVisibility: .visible) {
            Button(s.tidyAction == .trash ? "Move to Trash" : "Remove for good", role: s.tidyAction == .delete ? .destructive : nil) { model.runTidy() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(s.tidyAction == .trash ? "They can be taken back from the Trash until it is emptied." : "They are removed for good and cannot be taken back.")
        }
    }

    /// What Docker keeps on disk, and what has been unused long enough to go.
    @ViewBuilder private var docker: some View {
        let days = model.settings.dockerUnusedDays
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Caption("Docker on disk")
                Spacer()
                if model.isReadingDocker || model.isCleaningDocker { ProgressView().controlSize(.small) }
                if let report = model.dockerDisk {
                    Text("disk image \(Bytes.format(report.diskImageBytes))" + (report.diskImageLimitBytes > 0 ? " of up to \(Bytes.format(report.diskImageLimitBytes))" : ""))
                        .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Theme.secondary)
                        .help("Docker's disk image grows up to its limit and shrinks only when trimmed. Lowering the limit in Docker Desktop deletes the disk image with every image, container and volume in it, so PEPEL leaves it alone.")
                }
                Button("Read again") { model.refreshDocker() }.buttonStyle(QuietButtonStyle()).disabled(model.isReadingDocker || model.isCleaningDocker)
            }
            if let report = model.dockerDisk, let plan = model.dockerPlan {
                let stopped = report.containers.filter { !$0.isRunning }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text("has").gridColumnAlignment(.trailing)
                        Text("size").gridColumnAlignment(.trailing)
                        Text("unused \(days)+ days").gridColumnAlignment(.trailing)
                        Text("would free").gridColumnAlignment(.trailing)
                    }
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    dockerRow("Stopped containers", stopped.count, stopped.reduce(0) { $0 + $1.sizeBytes }, plan.containers.count, plan.bytes(.containers))
                    dockerRow("Images", report.images.count, report.imageBytes, plan.images.count, plan.bytes(.images))
                    dockerRow("Build cache", report.buildCache.count, report.buildCacheBytes, plan.buildCacheEntries, plan.bytes(.buildCache))
                    dockerRow("Anonymous volumes nothing mounts", report.volumes.count, report.volumeBytes, plan.volumes.count, plan.bytes(.volumes), tint: Theme.amber)
                }
                ForEach(plan.skipped, id: \.self) { line in
                    Text(line).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
                if let volumes = model.namedVolumes, !volumes.isEmpty {
                    let gone = volumes.filter { $0.projectState == .gone }
                    DisclosureGroup {
                        ForEach(volumes) { volume in
                            HStack(spacing: 10) {
                                Text(volume.name).font(Theme.mono).lineLimit(1).truncationMode(.middle)
                                if volume.projectState == .gone { Badge(text: "project folder gone", tint: Theme.amber) }
                                Spacer()
                                Text(volume.createdAt.map { "created \(TimeFormat.ago($0))" } ?? "").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                Text(Bytes.format(volume.bytes)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 70, alignment: .trailing)
                            }
                            .help(volume.projectFolder.map { "Project \(volume.project ?? ""): \($0)" } ?? "No compose project recorded.")
                        }
                        Text("PEPEL never removes named volumes: they hold data rebuilding does not bring back. Remove one yourself with docker volume rm.")
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    } label: {
                        Text("\(volumes.count) named volumes no container mounts · \(Bytes.format(volumes.reduce(0) { $0 + $1.bytes }))" + (gone.isEmpty ? "" : " · \(gone.count) from projects whose folder is gone"))
                            .font(.system(size: 12))
                    }
                }
                HStack(spacing: 8) {
                    Button("Remove unused containers, images and cache · \(Bytes.format(plan.reproducibleBytes))…") { confirmDocker = true }
                        .buttonStyle(CopperButtonStyle(prominent: false)).disabled(plan.reproducibleBytes == 0 || model.isCleaningDocker)
                    Button("Remove \(plan.volumes.count) anonymous volumes · \(Bytes.format(plan.bytes(.volumes)))…") { confirmVolumes = true }
                        .buttonStyle(QuietButtonStyle()).disabled(plan.volumes.isEmpty || model.isCleaningDocker)
                    Button("Trim disk image") { model.compactDocker() }.buttonStyle(QuietButtonStyle()).disabled(model.isCleaningDocker)
                        .help("Hands blocks Docker no longer uses back to the Mac. Nothing is removed.")
                }
                if let done = model.dockerCleanReport {
                    Text("Last cleanup: " + done.steps.map { "\($0.kind.title.lowercased()) \($0.removed) of \($0.attempted)" }.joined(separator: ", ")
                        + ". Disk image \(Bytes.format(done.diskImageBefore)) → \(Bytes.format(done.diskImageAfter)).")
                        .font(.system(size: 11)).foregroundStyle(Theme.forest).fixedSize(horizontal: false, vertical: true)
                }
                Text("Containers, images and build cache can be rebuilt or pulled again, so they can also be removed automatically once a day (Settings). Named volumes are never removed; anonymous ones nothing mounts only from here. Nothing is removed with force: Docker refuses what is in use.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            } else if !model.isReadingDocker {
                Text("Docker did not answer, or is not installed.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        .panel()
        .onAppear {
            if model.dockerDisk == nil { model.refreshDocker() }
            if model.namedVolumes == nil { model.refreshNamedVolumes() }
        }
        .confirmationDialog("Remove what Docker has not used for \(days) days?", isPresented: $confirmDocker, titleVisibility: .visible) {
            Button("Remove containers, images and build cache") { model.cleanDocker([.containers, .images, .buildCache, .networks]) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stopped containers, images no container uses, build cache and unused networks. Everything can be rebuilt or pulled again. Volumes are not touched.")
        }
        .confirmationDialog("Remove \(model.dockerPlan?.volumes.count ?? 0) volumes?", isPresented: $confirmVolumes, titleVisibility: .visible) {
            Button("Remove volumes", role: .destructive) { model.cleanDocker([.volumes]) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only anonymous volumes that no container mounts and that are older than \(days) days: what removed containers left behind. Named volumes are never removed by PEPEL. This cannot be undone.")
        }
    }

    /// Tool caches and how much of each has not been used for the configured time.
    @ViewBuilder private var caches: some View {
        let days = model.settings.cacheUnusedDays
        let limit = model.settings.cacheSizeLimitGB
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Caption("Tool caches")
                Spacer()
                if model.isMeasuringCaches || model.isTrimmingCaches { ProgressView().controlSize(.small) }
                Button(model.managedCaches == nil ? "Measure" : "Measure again") { model.measureCaches() }.buttonStyle(QuietButtonStyle()).disabled(model.isMeasuringCaches || model.isTrimmingCaches)
                if let caches = model.managedCaches {
                    let stale = caches.reduce(Int64(0)) { $0 + $1.staleBytes }
                    let over = limit > 0 ? caches.reduce(Int64(0)) { $0 + max(0, $1.totalBytes - $1.staleBytes - Int64(limit) * Bytes.gb) } : 0
                    Button("Remove unused · \(Bytes.format(stale + over))…") { confirmCaches = true }
                        .buttonStyle(CopperButtonStyle(prominent: false)).disabled(stale + over == 0 || model.isTrimmingCaches)
                }
            }
            if let caches = model.managedCaches {
                ForEach(caches) { cache in
                    HStack(spacing: 10) {
                        Text(cache.title).font(.system(size: 12, weight: .medium)).frame(width: 180, alignment: .leading).lineLimit(1)
                        PathText(path: cache.path)
                        Spacer()
                        Text(cache.staleBytes > 0 ? "\(Bytes.format(cache.staleBytes)) unused \(days)+ days" : "all used recently").font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(cache.staleBytes > 0 ? Theme.copper : Theme.tertiary)
                        Text(Bytes.format(cache.totalBytes)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 70, alignment: .trailing)
                            .foregroundStyle(limit > 0 && cache.totalBytes > Int64(limit) * Bytes.gb ? Theme.amber : Theme.text)
                    }
                    .help(cache.note)
                }
            } else {
                Text("Measuring walks every cache and takes some seconds; nothing is removed.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            Text("Only entries nobody has read or written for \(days) days are removed" + (limit > 0 ? ", and then the least recently used ones until each cache is under \(limit) GB" : "") + "; the rest stays warm. Everything here is downloaded or rebuilt when it is needed again.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .panel()
        .confirmationDialog("Remove unused entries from tool caches?", isPresented: $confirmCaches, titleVisibility: .visible) {
            Button("Remove") { model.trimCaches() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Entries unused for \(days) days" + (limit > 0 ? ", and the least recently used ones above \(limit) GB per cache," : "") + " are removed. The next build or install that needs one of them fetches or rebuilds it.")
        }
    }

    /// Application caches by owner and last use, and what removed applications left behind.
    @ViewBuilder private var applicationData: some View {
        let days = model.settings.appCacheUnusedDays
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Caption("Application caches")
                Spacer()
                if model.isMeasuringAppData { ProgressView().controlSize(.small) }
                Button(model.appCaches == nil ? "Measure" : "Measure again") { model.measureApplicationData() }.buttonStyle(QuietButtonStyle()).disabled(model.isMeasuringAppData)
            }
            if let caches = model.appCaches {
                let kept = Set(model.settings.keepAppCaches.map { $0.lowercased() })
                let known = caches.filter { ($0.owner == .installed || $0.owner == .removed) && $0.unused(days: days) && !kept.contains($0.name.lowercased()) }
                let unknown = caches.filter { $0.owner == .unknown && $0.unused(days: days) && !kept.contains($0.name.lowercased()) }
                ForEach(caches.prefix(12)) { cache in
                    HStack(spacing: 10) {
                        Badge(
                            text: cache.owner == .running ? "running" : cache.owner == .installed ? "installed" : cache.owner == .removed ? "removed" : "unknown",
                            tint: cache.owner == .running ? Theme.forest : cache.owner == .removed ? Theme.amber : Theme.tertiary)
                        Text(cache.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(cache.lastUse.map { "used \(TimeFormat.ago($0))" } ?? "").font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(cache.unused(days: days) && cache.owner != .running ? Theme.copper : Theme.tertiary)
                        Text(Bytes.format(cache.bytes)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 70, alignment: .trailing)
                    }
                }
                if caches.count > 12 { Text("and \(caches.count - 12) smaller ones").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
                HStack(spacing: 8) {
                    Button("Remove \(known.count) unused \(days)+ days · \(Bytes.format(known.reduce(0) { $0 + $1.bytes }))…") { confirmAppCaches = true }
                        .buttonStyle(CopperButtonStyle(prominent: false)).disabled(known.isEmpty || model.isMeasuringAppData)
                    Button("Also \(unknown.count) of unknown owner · \(Bytes.format(unknown.reduce(0) { $0 + $1.bytes }))…") { confirmUnknownCaches = true }
                        .buttonStyle(QuietButtonStyle()).disabled(unknown.isEmpty || model.isMeasuringAppData)
                    if !model.appLeftovers.isEmpty {
                        Button("Trash \(model.appLeftovers.count) leftovers of removed applications · \(Bytes.format(model.appLeftovers.reduce(0) { $0 + $1.bytes }))…") { confirmLeftovers = true }
                            .buttonStyle(QuietButtonStyle()).disabled(model.isMeasuringAppData)
                    }
                }
                Text("A cache is removed only when its application is not running and nothing in it was used for \(days) days. \"Unknown\" are folders PEPEL cannot tie to an application, often command-line tools. What a removed application left elsewhere in the Library may hold documents, so it only ever goes to the Trash.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Measuring walks ~/Library/Caches and takes some seconds; nothing is removed.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        .panel()
        .confirmationDialog("Remove unused application caches?", isPresented: $confirmAppCaches, titleVisibility: .visible) {
            Button("Remove") { model.cleanApplicationCaches(includeUnknown: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Caches of applications that are not running, or no longer installed, and that have not been used for \(days) days. An application rebuilds its cache when it needs it.")
        }
        .confirmationDialog("Remove caches of unknown owner too?", isPresented: $confirmUnknownCaches, titleVisibility: .visible) {
            Button("Remove") { model.cleanApplicationCaches(includeUnknown: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These folders in ~/Library/Caches are not named after an installed application. They are caches by location, unused for \(days) days, but PEPEL cannot say whose they are.")
        }
        .confirmationDialog("Move leftovers of removed applications to the Trash?", isPresented: $confirmLeftovers, titleVisibility: .visible) {
            Button("Move to Trash") { model.trashLeftovers() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Folders named after applications that are no longer installed, untouched for \(model.settings.leftoverDays) days. They can be taken back from the Trash.")
        }
    }

    /// Other large places (shown, not cleaned), old logs, and when the disk would fill.
    @ViewBuilder private var other: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Caption("Other large places")
                Spacer()
                if model.isMeasuringOther { ProgressView().controlSize(.small) }
                Button(model.otherPlaces == nil ? "Measure" : "Measure again") { model.measureOtherPlaces() }.buttonStyle(QuietButtonStyle()).disabled(model.isMeasuringOther)
                if model.oldLogs.count > 0 {
                    Button("Remove \(model.oldLogs.count) old log files · \(Bytes.format(model.oldLogs.bytes))…") { confirmLogs = true }.buttonStyle(CopperButtonStyle(prominent: false))
                }
            }
            if let forecast = model.diskForecast {
                Text(forecast.sentence()).font(.system(size: 12)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
            }
            if let entries = model.tempEntries {
                let removable = entries.filter { $0.keptBecause == nil }
                HStack(spacing: 10) {
                    Text("Temporary folder").font(.system(size: 12, weight: .medium)).frame(width: 300, alignment: .leading)
                    Text("\(entries.count) entries · \(removable.count) unused \(model.settings.tempDays)+ days").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary)
                    Spacer()
                    if !removable.isEmpty {
                        Button("Remove unused · \(Bytes.format(removable.reduce(0) { $0 + $1.bytes }))…") { confirmTemp = true }.buttonStyle(QuietButtonStyle())
                    }
                    Text(Bytes.format(entries.reduce(0) { $0 + $1.bytes })).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 70, alignment: .trailing)
                }
                .help(entries.prefix(6).map { "\(Bytes.format($0.bytes))  \($0.name)  \($0.keptBecause ?? "would go")" }.joined(separator: "\n"))
                .confirmationDialog("Remove unused temporary files?", isPresented: $confirmTemp, titleVisibility: .visible) {
                    Button("Remove") { model.cleanTemp() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Entries in your temporary folder that nothing has read or written for \(model.settings.tempDays) days. Sockets and pipes, anything macOS manages, and anything a running program uses are left alone.")
                }
            }
            if !model.toolBackups.isEmpty {
                let doomed = model.toolBackups.filter { !$0.kept }
                HStack(spacing: 10) {
                    Text("Clausona backups").font(.system(size: 12, weight: .semibold))
                    Text("\(model.toolBackups.count) · \(Bytes.format(model.toolBackups.reduce(0) { $0 + $1.bytes })) · keeping the newest \(model.settings.toolBackupsKeep) of each set and anything under \(model.settings.toolBackupsDays) days")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary).lineLimit(1)
                    Spacer()
                    if !doomed.isEmpty {
                        Button("Remove \(doomed.count) · \(Bytes.format(doomed.reduce(0) { $0 + $1.bytes }))…") { confirmBackups = true }.buttonStyle(QuietButtonStyle())
                    }
                }
                .help(model.toolBackups.map { "\(Bytes.format($0.bytes))  \($0.set)  \(TimeFormat.ago($0.createdAt))  \($0.kept ? "kept" : "would go")" }.joined(separator: "\n"))
                .confirmationDialog("Remove \(doomed.count) Clausona backups?", isPresented: $confirmBackups, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) { model.cleanToolBackups() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Copies Clausona made before switching profiles or migrating history. The live Codex and Claude history is not touched; what goes is the ability to roll back to those moments.")
                }
                Divider().overlay(Theme.stroke)
            }
            if !model.androidEmulators.isEmpty {
                let chosen = model.androidEmulators.filter { chosenEmulators.contains($0.name) }
                HStack {
                    Text("Android emulators").font(.system(size: 12, weight: .semibold))
                    Text("\(model.androidEmulators.count) · \(Bytes.format(model.androidEmulators.reduce(0) { $0 + $1.bytes }))").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("Choose unused 30+ days") {
                        chosenEmulators = Set(model.androidEmulators.filter { !$0.running && ($0.lastUse.map { Date().timeIntervalSince($0) > 30 * 86_400 } ?? false) }.map(\.name))
                    }
                    .buttonStyle(QuietButtonStyle())
                    Button("Delete \(chosen.count) · \(Bytes.format(chosen.reduce(0) { $0 + $1.bytes }))…") { confirmEmulators = true }
                        .buttonStyle(CopperButtonStyle(prominent: false)).disabled(chosen.isEmpty)
                }
                ForEach(model.androidEmulators) { emulator in
                    HStack(spacing: 10) {
                        Toggle(isOn: Binding(get: { chosenEmulators.contains(emulator.name) }, set: { on in if on { chosenEmulators.insert(emulator.name) } else { chosenEmulators.remove(emulator.name) } })) {
                            Text(emulator.name).font(.system(size: 12)).lineLimit(1)
                        }
                        .toggleStyle(.checkbox).disabled(emulator.running)
                        if emulator.running { Badge(text: "running", tint: Theme.forest) }
                        let kept = model.settings.keepEmulators.contains { $0.caseInsensitiveCompare(emulator.name) == .orderedSame }
                        if kept { Badge(text: "kept", tint: Theme.copper) }
                        Spacer()
                        Button(kept ? "Unkeep" : "Keep") {
                            model.updateSettings { s in
                                if kept { s.keepEmulators.removeAll { $0.caseInsensitiveCompare(emulator.name) == .orderedSame } } else { s.keepEmulators.append(emulator.name) }
                            }
                        }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        .help(kept ? "Let the daily rule delete it when it is unused long enough." : "The daily rule never deletes it.")
                        Text(emulator.lastUse.map { "used \(TimeFormat.ago($0))" } ?? "").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary)
                        Text(Bytes.format(emulator.bytes)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 70, alignment: .trailing)
                    }
                }
                let unusedImages = model.systemImages.filter { $0.usedBy.isEmpty }
                HStack(spacing: 10) {
                    Text("System images").font(.system(size: 12, weight: .semibold))
                    Text("\(model.systemImages.count) · \(Bytes.format(model.systemImages.reduce(0) { $0 + $1.bytes })) · \(unusedImages.count) not used by any emulator")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary)
                    Spacer()
                    if !unusedImages.isEmpty {
                        Button("Delete unused · \(Bytes.format(unusedImages.reduce(0) { $0 + $1.bytes }))…") { confirmImages = true }.buttonStyle(QuietButtonStyle())
                    }
                }
                .help(model.systemImages.map { "\(Bytes.format($0.bytes))  \($0.id)  \($0.usedBy.isEmpty ? "no emulator" : $0.usedBy.joined(separator: ", "))" }.joined(separator: "\n"))
                .confirmationDialog("Delete system images no emulator uses?", isPresented: $confirmImages, titleVisibility: .visible) {
                    Button("Delete") { model.deleteUnusedSystemImages() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(unusedImages.map(\.id).joined(separator: "\n") + "\n\nAndroid Studio or sdkmanager downloads one again when a new emulator needs it.")
                }
                Divider().overlay(Theme.stroke)
            }
            if let places = model.otherPlaces {
                ForEach(places.filter { !$0.path.contains("/.android/avd/") }.prefix(14)) { place in
                    HStack(spacing: 10) {
                        Text(place.title).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(width: 300, alignment: .leading)
                        if place.kept { Badge(text: "kept", tint: Theme.forest) }
                        Spacer()
                        Text(place.lastUse.map { "used \(TimeFormat.ago($0))" } ?? "").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary)
                        Text(Bytes.format(place.bytes)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 70, alignment: .trailing)
                    }
                    .help(place.note + "\n" + place.path)
                }
                Text("Emulators, language versions, device support and tool data. PEPEL shows them with their last use and does not remove them: each has its own way of being managed, named in the tooltip.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Measuring walks these folders and takes some seconds; nothing is removed.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        .panel()
        .confirmationDialog("Delete \(chosenEmulators.count) Android emulator\(chosenEmulators.count == 1 ? "" : "s")?", isPresented: $confirmEmulators, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.deleteAndroidEmulators(Array(chosenEmulators))
                chosenEmulators = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They are deleted as Android Studio's Device Manager does it, not moved to the Trash. Apps and data installed inside them are lost; the system images stay, so a device can be created again.")
        }
        .confirmationDialog("Remove old log files?", isPresented: $confirmLogs, titleVisibility: .visible) {
            Button("Remove") { model.removeOldLogs() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files in ~/Library/Logs older than \(model.settings.logDays) days and larger than 1 MB. Agents' own logs are not touched.")
        }
    }

    /// Large files not opened for a long time, and identical copies. A report: PEPEL removes none of them.
    @ViewBuilder private var files: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Caption("Large old files and copies")
                Spacer()
                if model.isFindingLargeFiles { ProgressView().controlSize(.small) }
                Button(model.largeFiles == nil ? "Find" : "Find again") { model.findLargeFiles() }.buttonStyle(QuietButtonStyle()).disabled(model.isFindingLargeFiles)
            }
            if let report = model.largeFiles {
                Text("Not opened for 90+ days, 500 MB or more: \(report.old.count) files, \(Bytes.format(report.oldBytes)).").font(.system(size: 12, weight: .medium))
                ForEach(report.old.prefix(10)) { file in fileRow(file) }
                Text("Identical copies, 100 MB or more: \(report.duplicates.count) groups, up to \(Bytes.format(report.duplicateBytes)) in the extra copies.").font(.system(size: 12, weight: .medium)).padding(.top, 6)
                ForEach(Array(report.duplicates.prefix(6).enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Bytes.format(group[0].bytes)) × \(group.count)").font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.secondary)
                        ForEach(group) { file in fileRow(file) }
                    }
                }
            } else {
                Text("Walks your home folder, leaving out Library, caches and agents' folders. Takes a few minutes; nothing is removed.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            Text("A report only: PEPEL removes none of these. Copies Finder made on the same disk may be clones that share their space.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .panel()
    }

    private func fileRow(_ file: LargeFile) -> some View {
        HStack(spacing: 10) {
            PathText(path: file.path)
            Spacer()
            Text("opened \(TimeFormat.ago(file.lastUse))").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary)
            Text(Bytes.format(file.bytes)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 70, alignment: .trailing)
            Button {
                model.reveal(file.path)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain).foregroundStyle(Theme.secondary).help("Show in Finder").accessibilityLabel("Show in Finder")
        }
    }

    private func dockerRow(_ title: String, _ count: Int, _ bytes: Int64, _ candidates: Int, _ free: Int64, tint: Color = Theme.copper) -> some View {
        GridRow {
            Text(title).foregroundStyle(Theme.text)
            Text("\(count)").foregroundStyle(Theme.secondary)
            Text(Bytes.format(bytes)).foregroundStyle(Theme.secondary)
            Text("\(candidates)").foregroundStyle(candidates > 0 ? Theme.text : Theme.tertiary)
            Text(Bytes.format(free)).foregroundStyle(free > 0 ? tint : Theme.tertiary)
        }
        .font(.system(size: 12)).monospacedDigit()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(
                title: "Storage",
                subtitle: "Developer artifacts found on this Mac. Sizes are blocks allocated on disk; where files are hard-linked, cloned or unreadable the figure is an upper bound, marked ≤.")
            tidy
            docker
            caches
            applicationData
            other
            files
            if let storage = model.storage {
                breakdown(storage)
                controls(storage)
                let items = storage.items.filter(matches)
                if items.isEmpty {
                    EmptyState(symbol: "magnifyingglass", title: "Nothing matches", message: "No artifact matches the current filter.")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(items.prefix(400)) { item in
                            StorageRow(item: item, inUse: storage.inUse[item.id], expanded: expanded == item.id) {
                                withAnimation(.easeOut(duration: 0.18)) { expanded = expanded == item.id ? nil : item.id }
                            }
                            Divider().overlay(Theme.stroke.opacity(0.6))
                        }
                    }
                    .panel(padding: 0)
                    if items.count > 400 {
                        Text("Showing the 400 largest of \(items.count). Narrow the search to see the rest.").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    }
                }
                ForEach(storage.scan.issues, id: \.self) { issue in
                    Label(issue.message, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            } else {
                EmptyState(
                    symbol: "internaldrive", title: model.isScanning ? "Scanning…" : "No scan yet",
                    message: "A scan measures build output, caches and dependencies. It only reads; nothing is removed.")
            }
        }
    }

    private func breakdown(_ storage: StorageState) -> some View {
        var totals: [ArtifactCategory: Int64] = [:]
        for item in storage.items { totals[item.category, default: 0] += item.occupiedBytes }
        let sorted = totals.sorted { $0.value > $1.value }.filter { $0.value > 0 }
        let total = max(1, sorted.reduce(Int64(0)) { $0 + $1.value })
        let palette: [Color] = [Theme.copper, Theme.forest, Theme.amber, Theme.ember, Theme.secondary, Theme.forestDim, Theme.tertiary]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                summary("Safe", storage.safeBytes, Theme.forest)
                summary("Review", storage.reviewBytes, Theme.copper)
                summary("Protected", storage.scan.bytes(.protected), Theme.tertiary)
                Spacer()
                Text("\(storage.items.count) artifacts · \(storage.projects.count) projects").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(Array(sorted.enumerated()), id: \.element.key) { index, entry in
                        Rectangle().fill(palette[index % palette.count])
                            .frame(width: max(2, proxy.size.width * CGFloat(entry.value) / CGFloat(total)))
                            .help("\(entry.key.displayName): \(Bytes.format(entry.value))")
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            HStack(spacing: 12) {
                ForEach(Array(sorted.prefix(6).enumerated()), id: \.element.key) { index, entry in
                    HStack(spacing: 4) {
                        Circle().fill(palette[index % palette.count]).frame(width: 6, height: 6)
                        Text("\(entry.key.displayName) \(Bytes.format(entry.value))").font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                }
            }
        }
        .panel()
    }

    private func summary(_ label: String, _ bytes: Int64, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Caption(label)
            Text(Bytes.format(bytes)).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    private func controls(_ storage: StorageState) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary).font(.system(size: 11))
                TextField("Filter by name, path, category or project", text: $search).textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke))
            Picker("Class", selection: $filter) {
                Text("All").tag(SafetyClass?.none)
                ForEach(SafetyClass.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(SafetyClass?.some($0)) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 260)
        }
    }
}

private struct StorageRow: View {
    @Environment(AppModel.self) private var model
    let item: StorageItem
    let inUse: String?
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Text((item.size?.isApproximate ?? false ? "≤ " : "") + Bytes.format(item.reclaimableBytes))
                        .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(Theme.text).frame(width: 78, alignment: .trailing)
                    Badge(text: item.safety.rawValue, tint: Theme.color(for: item.safety)).frame(width: 66, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(item.title).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
                            if inUse != nil { Badge(text: "in use", tint: Theme.amber) }
                        }
                        PathText(path: item.path)
                    }
                    Spacer(minLength: 6)
                    Text(item.category.displayName).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                    Text(item.lastModified.map { TimeFormat.ago($0) } ?? "").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.tertiary)
                        .frame(width: 84, alignment: .trailing)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.tertiary).rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 12).padding(.vertical, 7).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.title), \(Bytes.format(item.reclaimableBytes)), \(item.safety.rawValue)\(inUse == nil ? "" : ", in use")")
            if expanded { detail }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.explanation).font(.system(size: 12)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            Label(item.safetyReason, systemImage: item.safety == .protected ? "lock.fill" : "checkmark.shield").font(.system(size: 11)).foregroundStyle(Theme.color(for: item.safety))
            if let inUse { Label(inUse, systemImage: "bolt.fill").font(.system(size: 11)).foregroundStyle(Theme.amber) }
            HStack(spacing: 14) {
                if let name = model.projectName(item.projectID) {
                    HStack(spacing: 4) {
                        Text("Project \(name)").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        ConfidenceBadge(confidence: item.projectConfidence)
                    }
                } else if !item.hasPseudoPath {
                    Text("Not associated with a project").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
                if let size = item.size {
                    Text("\(size.fileCount) files · \(Bytes.format(size.logicalBytes)) logical · \(Bytes.format(size.allocatedBytes)) allocated")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    if size.inaccessibleCount > 0 { Text("\(size.inaccessibleCount) unreadable entries").font(.system(size: 11)).foregroundStyle(Theme.amber) }
                }
            }
            if !item.hasPseudoPath {
                HStack(spacing: 8) {
                    Button("Show in Finder") { model.reveal(item.path) }.buttonStyle(QuietButtonStyle())
                    if item.safety != .protected {
                        Button("Never clean this") { model.protect(.path, item.path, note: "Protected from the Storage view") }.buttonStyle(QuietButtonStyle())
                    }
                }
            }
        }
        .padding(.leading, 100).padding(.trailing, 12).padding(.bottom, 10)
        .transition(.opacity)
    }
}

struct ProjectsSection: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var confirmStale = false
    @State private var trashing: IgnoredFolder?

    /// Large folders git ignores that PEPEL does not recognise as build output.
    @ViewBuilder private var ignored: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Caption("Large folders git ignores")
                Spacer()
                if model.isFindingIgnored { ProgressView().controlSize(.small) }
                Button(model.ignoredFolders == nil ? "Find" : "Find again") { model.findIgnoredFolders() }.buttonStyle(QuietButtonStyle()).disabled(model.isFindingIgnored)
            }
            if let folders = model.ignoredFolders {
                if folders.isEmpty { Text("None of 500 MB or more.").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
                ForEach(folders.prefix(12)) { folder in
                    HStack(spacing: 10) {
                        Text(folder.projectName).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(width: 160, alignment: .leading)
                        if folder.looksLikeData { Badge(text: "looks like data", tint: Theme.amber) }
                        PathText(path: folder.path)
                        Spacer()
                        Text(folder.lastUse.map { "changed \(TimeFormat.ago($0))" } ?? "").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary)
                        Text(Bytes.format(folder.bytes)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 70, alignment: .trailing)
                        Button("Move to Trash…") { trashing = folder }.buttonStyle(QuietButtonStyle())
                    }
                }
            } else {
                Text("Asks git which folders each project ignores and measures the ones PEPEL does not already know: scratch data, local state, downloads.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("These may be data rather than output, so PEPEL never removes them on its own and only ever moves one to the Trash. Linked worktrees are left out.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .panel()
        .confirmationDialog(
            trashing.map { "Move \(($0.path as NSString).lastPathComponent) of \($0.projectName) to the Trash?" } ?? "",
            isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }), titleVisibility: .visible
        ) {
            Button("Move to Trash") { if let folder = trashing { model.trashIgnoredFolder(folder) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(trashing.map { ($0.looksLikeData ? "Its name suggests it holds data (a database, dumps, backups or configuration). " : "") + "\(Bytes.format($0.bytes)). It can be taken back from the Trash; the space is freed when the Trash is emptied." } ?? "")
        }
    }

    /// Projects nobody has touched for the configured time, with what can be removed from them.
    @ViewBuilder private var stale: some View {
        let days = model.settings.staleProjectDays
        let total = model.staleProjects.reduce(Int64(0)) { $0 + $1.bytes }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Caption("Untouched for \(days)+ days")
                Spacer()
                if model.isCleaningStale { ProgressView().controlSize(.small) }
                if !model.staleProjects.isEmpty {
                    Button("Remove artifacts of \(model.staleProjects.count) projects · \(Bytes.format(total))…") { confirmStale = true }
                        .buttonStyle(CopperButtonStyle(prominent: false)).disabled(model.isCleaningStale)
                }
            }
            if model.staleProjects.isEmpty {
                Text("No project with removable artifacts has been left untouched that long.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            ForEach(model.staleProjects.prefix(8)) { project in
                HStack(spacing: 10) {
                    Text(project.name).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(width: 200, alignment: .leading)
                    PathText(path: project.id)
                    Spacer()
                    Text("touched \(TimeFormat.ago(project.lastActivity))").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    Text(Bytes.format(project.bytes)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 70, alignment: .trailing)
                }
            }
            if model.staleProjects.count > 8 { Text("and \(model.staleProjects.count - 8) more").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
            Text("Environments, installed dependencies and build output only: what installing or building again recreates. Source, git data and configuration are never part of it. \"Touched\" is the newest of git's own bookkeeping and the project's files.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .panel()
        .onAppear { model.refreshStaleProjects() }
        .confirmationDialog("Remove artifacts of \(model.staleProjects.count) untouched projects?", isPresented: $confirmStale, titleVisibility: .visible) {
            Button("Remove \(Bytes.format(total))") { model.cleanStaleProjects() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Virtual environments, node_modules and build output are removed. Opening a project again means installing its dependencies again. Anything in use, recently written, pinned or excluded stays.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "Projects", subtitle: "Repositories found under your project roots. Worktrees of one repository are grouped; artifact sizes cover only what PEPEL recognises as generated.")
            stale
            ignored
            if let usage = model.storage?.projectUsage, !usage.isEmpty {
                TextField("Filter projects", text: $search).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(maxWidth: 280)
                let rows = usage.filter { search.isEmpty || $0.name.lowercased().contains(search.lowercased()) }
                LazyVStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Caption("Project").frame(maxWidth: .infinity, alignment: .leading)
                        Caption("Artifacts").frame(width: 80, alignment: .trailing)
                        Caption("Reclaimable").frame(width: 86, alignment: .trailing)
                        Caption("Growth").frame(width: 80, alignment: .trailing)
                        Caption("Processes").frame(width: 70, alignment: .trailing)
                        Caption("Agents").frame(width: 54, alignment: .trailing)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    Divider().overlay(Theme.stroke)
                    ForEach(rows.prefix(300)) { project in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(project.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                                    ForEach(project.kinds.filter { $0 != .git }.prefix(4), id: \.self) { Badge(text: $0.rawValue) }
                                    if project.roots.count > 1 { Badge(text: "\(project.roots.count) worktrees", tint: Theme.forest) }
                                }
                                HStack(spacing: 6) {
                                    if !project.branches.isEmpty {
                                        Label(project.branches.prefix(3).joined(separator: ", "), systemImage: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1)
                                    }
                                    PathText(path: project.roots.first ?? project.id)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Bytes.format(project.artifactBytes)).frame(width: 80, alignment: .trailing)
                            Text(Bytes.format(project.reclaimableBytes)).foregroundStyle(project.reclaimableBytes > 0 ? Theme.copper : Theme.tertiary).frame(width: 86, alignment: .trailing)
                            Text(project.growth.map { Bytes.formatDelta($0.deltaBytes) } ?? "—").foregroundStyle(Theme.secondary).frame(width: 80, alignment: .trailing)
                                .help(project.growth.map { "Over the last \(TimeFormat.age($0.actualSpan))" } ?? "Needs two scans")
                            Text(project.processCount > 0 ? "\(project.processCount)" : "—").foregroundStyle(Theme.secondary).frame(width: 70, alignment: .trailing)
                            Text(project.agentCount > 0 ? "\(project.agentCount)" : "—").foregroundStyle(project.agentCount > 0 ? Theme.forest : Theme.secondary).frame(width: 54, alignment: .trailing)
                        }
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.text)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        Divider().overlay(Theme.stroke.opacity(0.6))
                    }
                }
                .panel(padding: 0)
            } else {
                EmptyState(
                    symbol: "folder", title: "No projects found",
                    message: model.settings.projectRoots.isEmpty
                        ? "No project roots are configured. Add the folders that hold your repositories in Settings."
                        : "Nothing recognisable was found under \(model.settings.projectRoots.joined(separator: ", ")). Run a scan or adjust the roots in Settings.")
            }
        }
    }
}
