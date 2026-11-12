import Charts
import PEPELEngine
import SwiftUI

struct HistorySection: View {
    @Environment(AppModel.self) private var model
    @State private var kind: AuditKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "History", subtitle: "Recorded measurements only. Growth figures say how far back the data actually reaches.")
            summary
            journal
            growth
            chart
            log
        }
        .onAppear {
            model.refreshSecondary()
            model.refreshSummary()
            model.refreshJournal()
        }
    }

    private func figure(_ label: LocalizedStringKey, _ value: GrowthFigure?) -> some View {
        MetricTile(
            label: label, value: value.map { Bytes.formatDelta($0.deltaBytes) } ?? "—",
            detail: value.map { $0.coversWindow ? L("disk usage change") : L("only \(TimeFormat.age($0.actualSpan)) of history") } ?? L("no history yet"),
            tint: (value?.deltaBytes ?? 0) > 0 ? Theme.amber : Theme.forest)
    }

    private var growth: some View {
        HStack(spacing: 10) {
            figure("Last hour", model.growth?.hour)
            figure("Last day", model.growth?.day)
            figure("Last week", model.growth?.week)
            MetricTile(
                label: "Sudden spikes · 7 d", value: "\(model.growth?.spikes.count ?? 0)",
                detail: model.growth?.spikes.last.map { L("latest \(Bytes.formatDelta($0.deltaBytes)) \(TimeFormat.ago($0.at))") } ?? L("none recorded"))
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("Disk usage and reclaimable storage · 7 days")
            if model.telemetryHistory.count < 2 {
                Text("The trend appears once PEPEL has recorded a few samples (one every five minutes while it runs).").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            } else {
                Chart {
                    ForEach(model.telemetryHistory) { point in
                        LineMark(x: .value("Time", point.timestamp), y: .value("GB", Double(point.diskUsed) / 1e9), series: .value("Series", "Disk used"))
                            .foregroundStyle(Theme.forest).interpolationMethod(.monotone)
                    }
                    ForEach(model.telemetryHistory.filter { $0.reclaimable != nil }) { point in
                        LineMark(x: .value("Time", point.timestamp), y: .value("GB", Double(point.reclaimable ?? 0) / 1e9), series: .value("Series", "Reclaimable"))
                            .foregroundStyle(Theme.copper).interpolationMethod(.monotone)
                    }
                }
                .chartYAxisLabel("GB")
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 170)
                HStack(spacing: 12) {
                    Label("Disk used", systemImage: "circle.fill").foregroundStyle(Theme.forest)
                    Label("Reclaimable (as of each scan)", systemImage: "circle.fill").foregroundStyle(Theme.copper)
                }
                .font(.system(size: 10))
            }
        }
        .panel()
    }

    private func range(_ r: JournalDigest.Range) -> String { L("\(Bytes.format(r.min)) – \(Bytes.format(r.max)), average \(Bytes.format(r.average))") }
    private func shares(_ values: [String: Double]) -> String {
        values.sorted { $0.value > $1.value }.map { "\($0.key) \(Int(($0.value * 100).rounded()))%" }.joined(separator: ", ")
    }

    /// What the memory journal has recorded over the last week.
    private var journal: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Caption("Memory journal · 7 days")
                Spacer()
                Text("\(model.journalFiles.days) days · \(Bytes.format(model.journalFiles.bytes))").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary)
                Button("Open folder") { model.revealJournal() }.buttonStyle(QuietButtonStyle())
            }
            if let digest = model.journalDigest, digest.samples > 0 {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    GridRow { Text("Memory in use").foregroundStyle(Theme.secondary); Text(range(digest.used)) }
                    GridRow { Text("Wired").foregroundStyle(Theme.secondary); Text(range(digest.wired)) }
                    GridRow { Text("Swap").foregroundStyle(Theme.secondary); Text(range(digest.swap)) }
                    GridRow { Text("Pressure").foregroundStyle(Theme.secondary); Text(shares(digest.pressure)) }
                    GridRow {
                        Text("Agents").foregroundStyle(Theme.secondary)
                        Text("\(digest.agentSessions.min)–\(digest.agentSessions.max) sessions, \(range(digest.agentMemory)); \(shares(digest.agentStates))")
                    }
                    GridRow {
                        Text("Browsers").foregroundStyle(Theme.secondary)
                        let browsers = digest.browsers.map { "\($0.name) \(range($0.memory))" }.joined(separator: "; ")
                        Text(digest.browsers.isEmpty ? L("none seen") : L("\(browsers); idle tabs \(range(digest.idleTabMemory))"))
                    }
                }
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.text)
                ForEach(digest.owners.prefix(6)) { owner in
                    HStack(spacing: 10) {
                        Text(owner.name).font(.system(size: 12)).lineLimit(1).frame(width: 220, alignment: .leading)
                        Text("average \(Bytes.format(owner.memory.average)), peak \(Bytes.format(owner.memory.max))").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary)
                        Spacer()
                        Text(Bytes.formatDelta(owner.change)).font(.system(size: 11)).monospacedDigit().foregroundStyle(owner.change > Bytes.gb ? Theme.amber : Theme.tertiary)
                    }
                }
                Text("\(digest.samples) readings. A reading is taken every five minutes while PEPEL runs: memory, who holds it, every agent session and browser, and what PEPEL did. Names only; no command lines or paths.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(model.settings.journalEnabled ? "No readings yet. The first is written within five minutes of PEPEL starting." : "The journal is switched off in Settings.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    /// What PEPEL did over the last day, in words, with what it left for the user.
    @ViewBuilder private var summary: some View {
        if let summary = model.summary {
            VStack(alignment: .leading, spacing: 6) {
                Caption("Last 24 hours")
                Text(summary.headline).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                ForEach(summary.done, id: \.self) { line in
                    Label(line, systemImage: "circle.fill").labelStyle(BulletLabelStyle()).font(.system(size: 12)).foregroundStyle(Theme.text)
                }
                if !summary.open.isEmpty {
                    Text("Still there").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.amber).padding(.top, 4)
                    ForEach(summary.open, id: \.self) { line in
                        Label(line, systemImage: "circle.fill").labelStyle(BulletLabelStyle()).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        }
    }

    /// The kind of an audit entry, in words; the entry itself stays as recorded.
    static func auditKindTitle(_ kind: AuditKind) -> String {
        switch kind {
        case .cleanupPreview: L("preview")
        case .cleanup: L("cleanup")
        case .cleanupDenied: L("skipped")
        case .termination: L("termination")
        case .terminationDenied: L("not terminated")
        case .protection: L("protection")
        case .lease: L("lease")
        case .scan: L("scan")
        case .alert: L("alert")
        case .agent: L("agent")
        case .container: L("container")
        case .startup: L("startup")
        }
    }

    private var log: some View {
        let entries = model.audit.filter { kind == nil || $0.kind == kind }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Caption("Audit log")
                Spacer()
                Picker("Kind", selection: $kind) {
                    Text("Everything").tag(AuditKind?.none)
                    Text("Cleanup").tag(AuditKind?.some(.cleanup))
                    Text("Previews").tag(AuditKind?.some(.cleanupPreview))
                    Text("Skipped").tag(AuditKind?.some(.cleanupDenied))
                    Text("Terminations").tag(AuditKind?.some(.termination))
                    Text("Scans").tag(AuditKind?.some(.scan))
                    Text("Agents").tag(AuditKind?.some(.agent))
                }
                .labelsHidden().frame(width: 150)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if entries.isEmpty {
                Text("Nothing recorded yet.").font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(12)
            }
            LazyVStack(spacing: 0) {
                ForEach(entries.prefix(200)) { entry in
                    Divider().overlay(Theme.stroke.opacity(0.6))
                    HStack(spacing: 10) {
                        Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.tertiary).frame(width: 118, alignment: .leading)
                        Badge(text: Self.auditKindTitle(entry.kind), tint: entry.kind == .cleanup || entry.kind == .termination ? Theme.copper : Theme.secondary).frame(width: 104, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.subject).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
                            Text(entry.detail["observedChange"].map { L("\(entry.outcome) · memory \($0)") } ?? entry.outcome).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Text(entry.initiator).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                        if entry.bytes > 0 { Text(Bytes.format(entry.bytes)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.text).frame(width: 66, alignment: .trailing) }
                        if entry.outcome == "trashed", let trashed = entry.detail["trashedTo"], PathUtil.exists(trashed) {
                            Button("Restore") { model.restore(entry) }.buttonStyle(CopperButtonStyle(prominent: false))
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                }
            }
        }
        .panel(padding: 0)
    }
}

struct SettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var newRule = ""
    @State private var newRuleKind = ProtectionKind.path
    @State private var newKeep = ""
    @State private var newKeepApp = ""
    @State private var newKeepCache = ""
    @State private var newKeepEmulator = ""
    @State private var newKeepExtension = ""
    @State private var budgetKind = ""
    @State private var budgetName = ""
    @State private var budgetGB = 4
    @State private var vmLimitGiB = 8
    @State private var overrideProject = ""
    /// Groups opened by the user; everything starts folded so the page reads as a list of headings.
    @State private var expanded: Set<String> = []
    @State private var pendingPreset: SettingsPreset?

    var body: some View {
        let s = model.settings
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(title: "Settings", subtitle: "Pick a rule set, then open a group only to change what it does.")
                Spacer()
                Button(expanded.isEmpty ? "Open all" : "Fold all") {
                    withAnimation(.easeOut(duration: 0.2)) { expanded = expanded.isEmpty ? Set(Self.groupTitles) : [] }
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.copper)
            }
            startup
            presets(s)
            leaveAloneGroup(s)
            Caption("General").padding(.top, 6)
            group("Project roots", "Folders PEPEL searches for repositories. Nothing outside them, the known cache locations and DerivedData is examined.") {
                ForEach(s.projectRoots, id: \.self) { root in
                    HStack {
                        PathText(path: PathUtil.expand(root))
                        Spacer()
                        Button("Remove") { model.updateSettings { $0.projectRoots.removeAll { $0 == root } } }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
                if s.projectRoots.isEmpty { Text("No roots configured.").font(.system(size: 12)).foregroundStyle(Theme.amber) }
                HStack {
                    Button("Add folder…") { chooseFolder { path in model.updateSettings { if !$0.projectRoots.contains(path) { $0.projectRoots.append(path) } } } }.buttonStyle(QuietButtonStyle())
                    Button("Register single project…") { chooseFolder { path in model.updateSettings { if !$0.registeredProjects.contains(path) { $0.registeredProjects.append(path) } } } }.buttonStyle(QuietButtonStyle())
                    Button("Exclude folder…") { chooseFolder { path in model.updateSettings { if !$0.excludedPaths.contains(path) { $0.excludedPaths.append(path) } } } }.buttonStyle(QuietButtonStyle())
                }
                stepper(s.discoveryDepth, 1...12, label: { "Look for repositories up to \($0) folders deep" }) { v in model.updateSettings { $0.discoveryDepth = v } }
                ForEach(s.registeredProjects, id: \.self) { path in line("Registered", path) { model.updateSettings { $0.registeredProjects.removeAll { $0 == path } } } }
                ForEach(s.excludedPaths, id: \.self) { path in line("Excluded", path) { model.updateSettings { $0.excludedPaths.removeAll { $0 == path } } } }
            }

            group("Monitoring", "How much PEPEL does on its own.") {
                picker("Mode", selection: s.monitoringMode, options: [(.manual, "Manual"), (.notifyOnly, "Notify only"), (.automaticSafe, "Automatic safe cleanup")]) { value in model.updateSettings { $0.monitoringMode = value } }
                Text(modeHelp(s.monitoringMode)).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                toggle("Pause all monitoring", s.paused) { v in model.updateSettings { $0.paused = v } }
                toggle("Work less on battery", s.batteryAware) { v in model.updateSettings { $0.batteryAware = v } }
                toggle("Notifications", s.notificationsEnabled) { v in model.updateSettings { $0.notificationsEnabled = v } }
                VStack(alignment: .leading, spacing: 4) {
                    toggle("When PEPEL closes an app, ends a process or stops containers, and what that freed", s.notifyClosures) { v in model.updateSettings { $0.notifyClosures = v } }
                    toggle("What the daily disk rules removed or moved to the Trash", s.notifyCleanups) { v in model.updateSettings { $0.notifyCleanups = v } }
                    toggle("When an idle agent session is paused", s.notifyFreezes) { v in model.updateSettings { $0.notifyFreezes = v } }
                    toggle("When something new starts on its own (launch agent, daemon, login helper)", s.notifyNewStartupItems) { v in model.updateSettings { $0.notifyNewStartupItems = v } }
                }
                .padding(.leading, 20).disabled(!s.notificationsEnabled)
                HStack(spacing: 8) {
                    toggle("Keep a memory journal (a reading every five minutes)", s.journalEnabled) { v in model.updateSettings { $0.journalEnabled = v } }
                    stepper(s.journalRetentionDays, 1...365, label: { "for \($0) days" }) { v in model.updateSettings { $0.journalRetentionDays = v } }
                }
                HStack(spacing: 8) {
                    picker("Summary", selection: s.summaryFrequency, options: [(.weekly, "Once a week"), (.daily, "Every day"), (.off, "Off")]) { value in model.updateSettings { $0.summaryFrequency = value } }
                        .frame(maxWidth: 230)
                    if s.summaryFrequency == .weekly {
                        picker("on", selection: s.summaryWeekday, options: Self.weekdays) { value in model.updateSettings { $0.summaryWeekday = value } }.frame(maxWidth: 150)
                    }
                    if s.summaryFrequency != .off {
                        stepper(s.dailySummaryHour, 0...23, label: { "at \($0):00" }) { v in model.updateSettings { $0.dailySummaryHour = v } }
                    }
                }
                Text("What PEPEL gave back in memory and disk, what it removed, and what waits for your decision.").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                stepper(s.selfMemoryWarnMB, 0...16_384, step: 256, label: { $0 == 0 ? "Warn when PEPEL itself holds more than 0 MB (off)" : "Warn when PEPEL itself holds more than \($0) MB" }) { v in model.updateSettings { $0.selfMemoryWarnMB = v } }
                HStack(spacing: 8) {
                    toggle("Quiet hours", s.quietHours.enabled) { v in model.updateSettings { $0.quietHours.enabled = v } }
                    stepper(s.quietHours.startHour, 0...23, label: { "from \($0):00" }) { v in model.updateSettings { $0.quietHours.startHour = v } }
                    stepper(s.quietHours.endHour, 0...23, label: { "to \($0):00" }) { v in model.updateSettings { $0.quietHours.endHour = v } }
                }
                picker("Menu bar shows", selection: s.menuBarMode, options: [(.memoryGraphAndDisk, "Memory graph, memory and disk"), (.memoryGraph, "Memory graph"), (.memoryAndDisk, "Memory and disk"), (.reclaimable, "Reclaimable storage"), (.memoryPressure, "Memory pressure"), (.activeBuilds, "Active builds"), (.iconOnly, "Icon only")]) { value in model.updateSettings { $0.menuBarMode = value } }
            }

            group("Cleanup", "How approved items are removed.") {
                picker("Removal", selection: s.deletionMode, options: [(.automatic, "Safe: remove · Review: Trash"), (.trash, "Always Trash"), (.permanent, "Always remove permanently")]) { value in model.updateSettings { $0.deletionMode = value } }
                Text("Trashed items can be restored but free no space until the Trash is emptied. Permanent removal and tool cleanups cannot be undone.").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                stepper(s.recentWriteProtectionMinutes, 1...240, label: { "Treat artifacts written in the last \($0) min as in use" }) { v in model.updateSettings { $0.recentWriteProtectionMinutes = v } }
                stepper(Int(s.lowDiskThresholdBytes / Bytes.gb), 5...500, step: 5, label: { "Warn when disk space falls below \($0) GB" }) { v in model.updateSettings { $0.lowDiskThresholdBytes = Int64(v) * Bytes.gb } }
            }

            Caption("Daily disk rules").padding(.top, 6)
            group("Disk: Docker", "Images, stopped containers and build cache can be rebuilt or pulled again. Named volumes are never removed; anonymous ones only when you ask.") {
                toggle("Once a day, remove containers, images and build cache Docker has not used", s.dockerAutoClean) { v in model.updateSettings { $0.dockerAutoClean = v } }
                stepper(s.dockerUnusedDays, 1...365, label: { "Unused means untouched for \($0) days" }) { v in model.updateSettings { $0.dockerUnusedDays = v } }
                Text("A stopped container counts from when it stopped, an image from when it was last pulled or built, build cache from its last use. Containers of a compose project that is running, or that an agent is working in, and anything on the keep list are left alone. After removal PEPEL trims Docker's disk image so the Mac gets the space back.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }

            group("Disk: projects left untouched", "Environments, installed dependencies and build output of projects nobody works on. Source, git data and configuration are never removed.") {
                toggle("Once a day, remove those artifacts from projects left untouched", s.cleanStaleProjects) { v in model.updateSettings { $0.cleanStaleProjects = v } }
                stepper(s.staleProjectDays, 1...365, label: { "Untouched means no change for \($0) days" }) { v in model.updateSettings { $0.staleProjectDays = v } }
                Text("A project counts as touched when git's bookkeeping or one of its own files changed, or an agent session is in it. Exclude a project with a protection rule of kind Project below.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }

            group("Disk: tool caches", "Go, sccache, uv, pip, npm, Yarn, Bun, Cargo, Homebrew and browser downloads of Playwright and Puppeteer. Everything in them is fetched or rebuilt when needed.") {
                toggle("Once a day, remove cache entries that have not been used", s.trimCaches) { v in model.updateSettings { $0.trimCaches = v } }
                stepper(s.cacheUnusedDays, 1...365, label: { "Unused means not read or written for \($0) days" }) { v in model.updateSettings { $0.cacheUnusedDays = v } }
                stepper(s.cacheSizeLimitGB, 0...500, label: { "Keep each cache under \($0) GB (0 = no limit)" }) { v in model.updateSettings { $0.cacheSizeLimitGB = v } }
                Text("With a size limit, the least recently used entries of a cache that is too large go first; anything used within the last day always stays. Gradle cleans its own caches and is left to it.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }

            group("Disk: application caches", "Folders in ~/Library/Caches. An application rebuilds its cache when it needs it.") {
                toggle("Once a day, remove caches of applications that are not running and have not used them", s.cleanAppCaches) { v in model.updateSettings { $0.cleanAppCaches = v } }
                stepper(s.appCacheUnusedDays, 1...365, label: { "Unused means untouched for \($0) days" }) { v in model.updateSettings { $0.appCacheUnusedDays = v } }
                stepper(s.leftoverDays, 7...730, step: 7, label: { "List what a removed application left behind after \($0) days untouched" }) { v in model.updateSettings { $0.leftoverDays = v } }
                Text("Never remove these cache folders (some applications keep more than a cache there):").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                ForEach(s.keepAppCaches, id: \.self) { name in
                    HStack {
                        Badge(text: "keep", tint: Theme.copper)
                        Text(name).font(Theme.mono).foregroundStyle(Theme.text)
                        Spacer()
                        Button("Remove") { model.updateSettings { $0.keepAppCaches.removeAll { $0 == name } } }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
                HStack(spacing: 8) {
                    TextField("folder name in ~/Library/Caches", text: $newKeepCache).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(maxWidth: 320)
                    Button("Keep") {
                        let name = newKeepCache.trimmingCharacters(in: .whitespaces)
                        model.updateSettings { if !$0.keepAppCaches.contains(name) { $0.keepAppCaches.append(name) } }
                        newKeepCache = ""
                    }
                    .buttonStyle(QuietButtonStyle()).disabled(newKeepCache.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Caches PEPEL cannot tie to an application, and what removed applications left elsewhere in the Library, are never removed automatically. A folder holding a file named DO_NOT_CLEAN.txt (or .pepel-keep), or carrying the attribute com.avm.do-not-clean, is never cleaned by any rule, nor is anything inside it.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }

            group("Disk: Android emulators", "Virtual devices in ~/.android/avd. Deleting one removes the apps and data inside it; the system images stay, so it can be created again.") {
                toggle("Once a day, delete emulators that have not been started", s.cleanAndroidEmulators) { v in model.updateSettings { $0.cleanAndroidEmulators = v } }
                stepper(s.emulatorUnusedDays, 7...365, label: { "Not started means no start for \($0) days" }) { v in model.updateSettings { $0.emulatorUnusedDays = v } }
                toggle("Once a day, delete system images that no emulator starts from", s.cleanUnusedSystemImages) { v in model.updateSettings { $0.cleanUnusedSystemImages = v } }
                Text("Never delete these emulators:").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                ForEach(s.keepEmulators, id: \.self) { name in
                    HStack {
                        Badge(text: "keep", tint: Theme.copper)
                        Text(name).font(Theme.mono).foregroundStyle(Theme.text)
                        Spacer()
                        Button("Remove") { model.updateSettings { $0.keepEmulators.removeAll { $0 == name } } }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
                HStack(spacing: 8) {
                    TextField("emulator name, for example rune_api37_20260906", text: $newKeepEmulator).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(maxWidth: 320)
                    Button("Keep") {
                        let name = newKeepEmulator.trimmingCharacters(in: .whitespaces)
                        model.updateSettings { if !$0.keepEmulators.contains(name) { $0.keepEmulators.append(name) } }
                        newKeepEmulator = ""
                    }
                    .buttonStyle(QuietButtonStyle()).disabled(newKeepEmulator.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("A start is read from the device's own files, which the emulator writes every time it runs. A running emulator, one marked with DO_NOT_CLEAN.txt and one on this list are never deleted; each candidate is checked again right before deletion.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }

            group("Disk: Downloads and screenshots", "Screenshots and screen recordings macOS made, wherever they are saved, and anything in Downloads you have not used for a while.") {
                toggle("Once a day, take screenshots and screen recordings", s.tidyScreenshots) { v in model.updateSettings { $0.tidyScreenshots = v } }
                stepper(s.screenshotDays, 1...90, label: { "Older than \($0) days" }) { v in model.updateSettings { $0.screenshotDays = v } }
                toggle("Once a day, take downloads", s.tidyDownloads) { v in model.updateSettings { $0.tidyDownloads = v } }
                stepper(s.downloadDays, 1...365, label: { "Not used for \($0) days" }) { v in model.updateSettings { $0.downloadDays = v } }
                picker("What happens to them", selection: s.tidyAction, options: [(.trash, "Move to the Trash"), (.delete, "Remove for good")]) { value in model.updateSettings { $0.tidyAction = value } }
                Text("Never taken from Downloads (file extensions):").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                HStack(spacing: 6) {
                    ForEach(s.tidyKeepExtensions, id: \.self) { ext in
                        Button {
                            model.updateSettings { $0.tidyKeepExtensions.removeAll { $0 == ext } }
                        } label: {
                            HStack(spacing: 3) {
                                Text(".\(ext)").font(Theme.mono)
                                Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                            }
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.copper).help("Stop keeping .\(ext) files")
                    }
                }
                HStack(spacing: 8) {
                    TextField("extension, for example epub", text: $newKeepExtension).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(maxWidth: 220)
                    Button("Keep") {
                        let ext = newKeepExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
                        model.updateSettings { if !$0.tidyKeepExtensions.contains(ext) { $0.tidyKeepExtensions.append(ext) } }
                        newKeepExtension = ""
                    }
                    .buttonStyle(QuietButtonStyle()).disabled(newKeepExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).isEmpty)
                }
                Text("Also never taken: anything with a Finder tag, anything opened within the age above, and a folder marked DO_NOT_CLEAN. Unfinished downloads go after a day. Only screenshots macOS marked as such are touched on the Desktop.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }

            group("Disk: Clausona backups", "Copies Clausona makes before it switches profiles or migrates history. The live Codex and Claude history is never part of this.") {
                toggle("Once a day, remove old backups", s.cleanToolBackups) { v in model.updateSettings { $0.cleanToolBackups = v } }
                stepper(s.toolBackupsKeep, 0...20, label: { "Always keep the newest \($0) of each set" }) { v in model.updateSettings { $0.toolBackupsKeep = v } }
                stepper(s.toolBackupsDays, 0...365, label: { "Remove the rest once they are \($0) days old" }) { v in model.updateSettings { $0.toolBackupsDays = v } }
                Text("Nothing is removed while Clausona is switching profiles (its lock is held), or from a folder marked as not to be cleaned.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }

            group("Disk: temporary files", "Your temporary folder. macOS empties it only on restart.") {
                toggle("Once a day, remove temporary files that nothing has used", s.cleanTempFiles) { v in model.updateSettings { $0.cleanTempFiles = v } }
                stepper(s.tempDays, 1...365, label: { "Unused means not read or written for \($0) days" }) { v in model.updateSettings { $0.tempDays = v } }
                Text("Sockets and pipes, folders that hold one, anything macOS manages and anything a running program names or works in are left alone, whatever their age.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }

            group("Disk: logs", "Files in ~/Library/Logs. Agents' own logs are never touched.") {
                toggle("Once a day, remove old log files larger than 1 MB", s.cleanOldLogs) { v in model.updateSettings { $0.cleanOldLogs = v } }
                stepper(s.logDays, 1...365, label: { "Old means older than \($0) days" }) { v in model.updateSettings { $0.logDays = v } }
                Text("All daily disk rules run once in twenty hours, and once an hour while free space is below the low-disk threshold above.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }

            Caption("Builds, memory and processes").padding(.top, 6)
            group("Build retention", "Defaults for every project. Active and pinned builds are always kept.") {
                stepper(s.defaultRetention.keepSuccessful, 1...20, label: { "Keep the last \($0) builds" }) { v in model.updateSettings { $0.defaultRetention.keepSuccessful = v } }
                stepper(s.defaultRetention.keepFailed, 0...20, label: { "Keep the last \($0) failed builds" }) { v in model.updateSettings { $0.defaultRetention.keepFailed = v } }
                stepper(s.defaultRetention.reviewAfterHours, 1...720, step: 12, label: { "Review artifacts older than \($0) hours" }) { v in model.updateSettings { $0.defaultRetention.reviewAfterHours = v } }
                stepper(Int((s.defaultRetention.budgetBytes ?? 0) / Bytes.gb), 1...1000, step: 5, label: { "Per-project build budget \($0) GB" }) { v in model.updateSettings { $0.defaultRetention.budgetBytes = Int64(v) * Bytes.gb } }
                stepper(Int(s.globalBuildBudgetBytes / Bytes.gb), 10...2000, step: 10, label: { "Global build budget \($0) GB" }) { v in model.updateSettings { $0.globalBuildBudgetBytes = Int64(v) * Bytes.gb } }
                toggle("Treat builds retention marks obsolete as safe (allows automatic cleanup of old generations)", s.retentionCandidatesAreSafe) { v in model.updateSettings { $0.retentionCandidatesAreSafe = v } }
                toggle("Always keep the last build that succeeded", s.defaultRetention.protectLastKnownGood) { v in model.updateSettings { $0.defaultRetention.protectLastKnownGood = v } }
                toggle("Mark builds obsolete by age alone", s.defaultRetention.maxAgeDays != nil) { v in model.updateSettings { $0.defaultRetention.maxAgeDays = v ? 30 : nil } }
                if let days = s.defaultRetention.maxAgeDays {
                    stepper(days, 1...365, label: { "Obsolete after \($0) days" }) { v in model.updateSettings { $0.defaultRetention.maxAgeDays = v } }
                }
                Divider().overlay(Theme.stroke)
                Text("Different rules for one project:").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                ForEach(s.projectRetention.keys.sorted(), id: \.self) { key in
                    if let policy = s.projectRetention[key] {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(model.projectName(key) ?? (key as NSString).lastPathComponent).font(.system(size: 12, weight: .medium))
                                Spacer()
                                Button("Remove") { model.updateSettings { $0.projectRetention[key] = nil } }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            }
                            HStack(spacing: 14) {
                                stepper(policy.keepSuccessful, 1...20, label: { "Keep \($0) builds" }) { v in model.updateSettings { $0.projectRetention[key]?.keepSuccessful = v } }
                                stepper(policy.keepFailed, 0...20, label: { "and \($0) failed" }) { v in model.updateSettings { $0.projectRetention[key]?.keepFailed = v } }
                                stepper(Int((policy.budgetBytes ?? 0) / Bytes.gb), 1...1000, step: 5, label: { "Budget \($0) GB" }) { v in model.updateSettings { $0.projectRetention[key]?.budgetBytes = Int64(v) * Bytes.gb } }
                            }
                        }
                    }
                }
                let candidates = (model.storage?.builds ?? []).filter { $0.attributed && s.projectRetention[$0.id] == nil }
                if !candidates.isEmpty {
                    HStack(spacing: 8) {
                        Picker("Project", selection: $overrideProject) {
                            Text("Choose a project").tag("")
                            ForEach(candidates) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().frame(width: 240)
                        Button("Add its own rules") {
                            let key = overrideProject
                            model.updateSettings { $0.projectRetention[key] = $0.defaultRetention }
                            overrideProject = ""
                        }
                        .buttonStyle(QuietButtonStyle()).disabled(overrideProject.isEmpty)
                    }
                }
            }

            group("Free memory", "How the Free memory action can be started without opening the menu, and what it may do without asking.") {
                toggle("Open Free memory with Control-Option-Command-M from anywhere", s.freeMemoryHotkey) { v in model.updateSettings { $0.freeMemoryHotkey = v } }
                toggle("Free memory whenever the screen is locked", s.freeMemoryOnLock) { v in model.updateSettings { $0.freeMemoryOnLock = v } }
                Text("On lock, and from the button on a memory pressure notification, PEPEL runs only the steps that are preselected in the Free memory plan, and never one that would ask for a password.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                stepper(s.forecastWarnMinutes, 0...180, step: 5, label: { "Warn when memory is forecast to run short within \($0) min (0 = never)" }) { v in model.updateSettings { $0.forecastWarnMinutes = v } }
                toggle("Under memory pressure, act sooner", s.adaptToMemoryPressure) { v in model.updateSettings { $0.adaptToMemoryPressure = v } }
                Text("Halves the waiting periods of the rules below under elevated pressure and quarters them under critical pressure (never under 30 minutes for an agent session), and lets the Docker VM restart outside its night window, at most every six hours. Only affects rules that are switched on.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let permission = model.fileCachePermission {
                        Text(
                            !permission.available
                                ? "Flushing the file cache is not available here."
                                : permission.granted
                                    ? "PEPEL may flush the file cache without asking for a password."
                                    : "The first file cache flush asks for an administrator once; after that PEPEL does not ask again."
                        )
                        .font(.system(size: 12)).foregroundStyle(Theme.text)
                        Spacer()
                        if permission.granted {
                            Button("Remove permission") { model.revokeFileCachePermission() }.buttonStyle(QuietButtonStyle())
                        }
                    }
                }
                .onAppear { model.refreshFileCachePermission() }
            }

            group("Agent sessions", "What happens to a session that has gone quiet. A working session is never touched.") {
                toggle("Suspend agent sessions that have gone quiet, instead of waiting to end them", s.freezeIdleAgents) { v in model.updateSettings { $0.freezeIdleAgents = v } }
                stepper(s.freezeAfterMinutes, 5...240, step: 5, label: { "Suspend after \($0) min of quiet" }) { v in model.updateSettings { $0.freezeAfterMinutes = v } }
                stepper(s.freezePeekMinutes, 2...120, label: { "Look for waiting work every \($0) min" }) { v in model.updateSettings { $0.freezePeekMinutes = v } }
                Text("A suspended session keeps everything and continues the moment its application comes to the front. In between PEPEL wakes it briefly to see whether work arrived (a message from another device, a finished task); if so it stays awake. Sessions PEPEL cannot tie to an application, such as ones inside tmux, are never suspended automatically. Quitting or pausing PEPEL wakes everything.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                toggle("Terminate agent sessions that are asleep (no disk writes, CPU bursts, new processes or builds)", s.terminateSleepingAgents) { v in model.updateSettings { $0.terminateSleepingAgents = v } }
                stepper(s.agentSleepMinutes, 30...1440, step: 30, label: { "Call an agent session asleep after \($0) min of quiet" }) { v in model.updateSettings { $0.agentSleepMinutes = v } }
                Text("A session waiting for your reply writes nothing either, so it is treated as asleep. Sessions of Claude Code and Codex can be resumed afterwards; text typed but not sent is lost.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                stepper(s.serviceBranchIdleMinutes, 15...1440, step: 15, label: { "Inside an agent's server, call an older copy left behind after \($0) min idle" }) { v in model.updateSettings { $0.serviceBranchIdleMinutes = v } }
                Divider().overlay(Theme.stroke)
                Text("PEPEL's note in agents' global instructions (explains that containers may stop and how to take a lease):").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                ForEach(model.instructionFiles) { file in
                    HStack {
                        Badge(text: file.installed ? "installed" : "no note", tint: file.installed ? Theme.forest : Theme.tertiary)
                        Text(file.agent).font(.system(size: 12)).frame(width: 96, alignment: .leading)
                        Text(file.path).font(Theme.mono).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                    }
                }
                HStack {
                    Button("Install or update the note") { model.installInstructions() }.buttonStyle(QuietButtonStyle())
                    Button("Remove it") { model.removeInstructions() }.buttonStyle(QuietButtonStyle()).disabled(!model.instructionFiles.contains { $0.installed })
                }
                .onAppear { model.refreshInstructionFiles() }
            }

            group("Apps that stay open without windows", "Preview, TextEdit and most document apps keep running after their last window is closed. Tick the ones PEPEL should quit when no window is open.") {
                stepper(s.windowlessQuitMinutes, 0...120, label: { "Quit after \($0) min with no window, when not in front" }) { v in model.updateSettings { $0.windowlessQuitMinutes = v } }
                if model.windowlessApps.isEmpty {
                    Text("None seen yet. PEPEL notices an application running with no window and lists it here.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                ForEach(model.windowlessApps) { app in
                    HStack(spacing: 10) {
                        Toggle(isOn: Binding(get: { app.quitWhenWindowless }, set: { model.setQuitWhenWindowless(app, $0) })) {
                            HStack(spacing: 8) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 18, height: 18)
                                Text(app.name).font(.system(size: 12, weight: .medium))
                            }
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("Quit \(app.name) when it has no window")
                        if app.windowlessNow { Badge(text: "open, no window", tint: Theme.amber) } else if app.running { Badge(text: "open", tint: Theme.forest) }
                        Spacer()
                        Text(app.timesSeen > 0 ? L("seen without windows \(app.timesSeen)×, last \(app.lastSeen.map { TimeFormat.ago($0) } ?? "")") : app.known ? L("known to stay open") : "")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
                Text("A ticked app is asked to quit the normal way, never forced. It is left alone while it is in front, while it is busy with no window (playing, exporting, syncing), and when an agent session or a build runs inside it. A window that is minimised, hidden or on another Space counts as open.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .onAppear { model.refreshWindowlessApps() }

            group("Applications", "Leftovers of applications that quit, and applications that stay open unused. Quitting an application is always the ordinary request and always asks you first.") {
                toggle("Terminate what an application leaves running after it quits", s.terminateAppLeftovers) { v in model.updateSettings { $0.terminateAppLeftovers = v } }
                stepper(s.appLeftoverGraceMinutes, 1...240, label: { "Wait \($0) min after the application quit" }) { v in model.updateSettings { $0.appLeftoverGraceMinutes = v } }
                Text("Covers helpers and child processes PEPEL saw the application start, or that run from inside its bundle. System-managed components, agent sessions and container runtimes are never included.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                stepper(s.unusedApplicationHours, 1...168, label: { "List an open application as unused after \($0) h without being in front" }) { v in model.updateSettings { $0.unusedApplicationHours = v } }
                stepper(s.appUnusedDays, 7...365, label: { "Suggest removing an installed app nobody opened for \($0) days" }) { v in model.updateSettings { $0.appUnusedDays = v } }
                stepper(s.tabIdleMinutes, 5...720, step: 5, label: { "Call a browser tab idle after \($0) min without CPU use" }) { v in model.updateSettings { $0.tabIdleMinutes = v } }
                Text("Never list as unused:").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                ForEach(s.keepApplications, id: \.self) { name in
                    HStack {
                        Badge(text: "keep", tint: Theme.copper)
                        Text(name).font(.system(size: 12)).foregroundStyle(Theme.text)
                        Spacer()
                        Button("Remove") { model.updateSettings { $0.keepApplications.removeAll { $0 == name } } }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
                HStack(spacing: 8) {
                    TextField("application name, for example Telegram", text: $newKeepApp).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(maxWidth: 320)
                    Button("Keep") {
                        let name = newKeepApp.trimmingCharacters(in: .whitespaces)
                        model.updateSettings { if !$0.keepApplications.contains(name) { $0.keepApplications.append(name) } }
                        newKeepApp = ""
                    }
                    .buttonStyle(QuietButtonStyle()).disabled(newKeepApp.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            group("Memory budgets", "A limit for what one owner may hold. Exceeding it raises an alert; PEPEL never ends anything because of a budget.") {
                ForEach(s.memoryBudgets) { budget in
                    HStack {
                        Text(budget.match).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                        Text(Bytes.format(budget.bytes)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.secondary)
                        if let over = model.live?.overBudget.filter({ o in model.live?.memoryOwners.first { $0.id == o.ownerID }.map(budget.applies) ?? false }), !over.isEmpty {
                            Badge(text: "\(over.count) over", tint: Theme.amber)
                        }
                        Spacer()
                        Button("Remove") { model.updateSettings { $0.memoryBudgets.removeAll { $0.id == budget.id } } }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
                if s.memoryBudgets.isEmpty { Text("No budgets.").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
                HStack(spacing: 8) {
                    Picker("For", selection: $budgetKind) {
                        Text("An owner by name").tag("")
                        Text("Every agent session").tag("kind:agentSession")
                        Text("Every application").tag("kind:application")
                        Text("Every project").tag("kind:project")
                    }
                    .labelsHidden().frame(width: 170)
                    if budgetKind.isEmpty {
                        TextField("owner name as shown in Memory, for example Dia", text: $budgetName).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(maxWidth: 260)
                    }
                    Stepper(value: $budgetGB, in: 1...256) { Text("\(budgetGB) GB").font(.system(size: 12)).monospacedDigit() }
                    Button("Add budget") {
                        let match = budgetKind.isEmpty ? budgetName.trimmingCharacters(in: .whitespaces) : budgetKind
                        let bytes = Int64(budgetGB) * Bytes.gb
                        model.updateSettings { s in
                            s.memoryBudgets.removeAll { $0.id == match.lowercased() }
                            s.memoryBudgets.append(MemoryBudget(match: match, bytes: bytes))
                        }
                        budgetName = ""
                    }
                    .buttonStyle(QuietButtonStyle()).disabled(budgetKind.isEmpty && budgetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            group("Containers", "Containers are stopped, never removed; volumes are never touched.") {
                toggle("Stop a project's containers when no agent session has worked in it", s.stopContainersOfIdleProjects) { v in model.updateSettings { $0.stopContainersOfIdleProjects = v } }
                picker("When a project is idle", selection: s.idleContainerAction, options: [(.stop, "Stop its containers"), (.pause, "Pause them (continue when an agent returns)")]) { value in model.updateSettings { $0.idleContainerAction = value } }
                Text("Stopping releases their memory inside the VM. Pausing keeps everything and resumes by itself the moment an agent session starts in the project, but the memory stays.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                stepper(s.projectIdleGraceMinutes, 5...720, step: 5, label: { "A project is idle after \($0) min without an agent session" }) { v in model.updateSettings { $0.projectIdleGraceMinutes = v } }
                toggle("Restart the Docker VM once a day to return its memory", s.refreshContainerVMNightly) { v in model.updateSettings { $0.refreshContainerVMNightly = v } }
                stepper(s.vmRefreshHour, 0...23, label: { "Start looking for a quiet moment at \($0):00" }) { v in model.updateSettings { $0.vmRefreshHour = v } }
                stepper(Int(s.vmRefreshMinimumExcessBytes / Bytes.gb), 1...64, label: { "Only when at least \($0) GB would come back" }) { v in model.updateSettings { $0.vmRefreshMinimumExcessBytes = Int64(v) * Bytes.gb } }
                Text("All containers go down for about a minute and are started again. Skipped while an agent session is working or a kept container is running. If the Mac slept through the hour, it catches up at the next quiet moment.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                if let report = model.live?.containers, report.product.lowercased().contains("docker desktop") {
                    Divider().overlay(Theme.stroke)
                    let limit = Bytes.format(report.vmLimitBytes), used = Bytes.format(report.usedByContainersBytes), lowest = Bytes.format(report.minimumLimitBytes)
                    let usage = report.peakUsedBytes > 0
                        ? L("The VM may use up to \(limit). Containers use \(used) now, \(Bytes.format(report.peakUsedBytes)) at most in the days PEPEL has watched.")
                        : L("The VM may use up to \(limit). Containers use \(used) now.")
                    let lowestLimit = report.suggestedLimitBytes.map { L("The lowest limit PEPEL accepts is \(lowest); it suggests \(Bytes.format($0)).") }
                        ?? L("The lowest limit PEPEL accepts is \(lowest).")
                    Text(usage + " " + lowestLimit)
                        .font(.system(size: 12)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Stepper(value: $vmLimitGiB, in: 2...256) { Text("New limit: \(vmLimitGiB) GiB").font(.system(size: 12)).monospacedDigit() }
                        Button("Change limit…") { model.requestVMLimit(gib: vmLimitGiB) }.buttonStyle(QuietButtonStyle()).disabled(model.isRefreshingVM)
                        if model.isRefreshingVM { ProgressView().controlSize(.small) }
                    }
                    .onAppear { vmLimitGiB = Int((report.suggestedLimitBytes ?? report.vmLimitBytes) >> 30) }
                    Text("Only a restart gives the VM's memory back, and only a lower limit keeps it from growing again. Changing it stops Docker Desktop, writes the setting and starts Docker and the same containers.")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Leave running, whatever happens (container or compose project names; a container labelled pepel.keep=true is always kept):")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                ForEach(s.keepContainers, id: \.self) { name in
                    HStack {
                        Badge(text: "keep", tint: Theme.copper)
                        Text(name).font(Theme.mono).foregroundStyle(Theme.text)
                        Spacer()
                        Button("Remove") { model.updateSettings { $0.keepContainers.removeAll { $0 == name } } }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
                HStack(spacing: 8) {
                    TextField("container or compose project name", text: $newKeep).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(maxWidth: 320)
                    Button("Keep running") {
                        let name = newKeep.trimmingCharacters(in: .whitespaces)
                        model.updateSettings { if !$0.keepContainers.contains(name) { $0.keepContainers.append(name) } }
                        newKeep = ""
                    }
                    .buttonStyle(QuietButtonStyle()).disabled(newKeep.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog(
                model.pendingVMLimit.map { L("Change the VM memory limit to \(Bytes.format($0.newLimitBytes))?") } ?? "",
                isPresented: Binding(get: { model.pendingVMLimit != nil }, set: { if !$0 { model.pendingVMLimit = nil } }), titleVisibility: .visible
            ) {
                if model.pendingVMLimit?.verdict != .denied { Button("Change and restart Docker Desktop") { model.confirmVMLimit() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(((model.pendingVMLimit?.reasons ?? []) + (model.pendingVMLimit?.warnings ?? [])).joined(separator: "\n"))
            }

            group("Processes", "Automatic termination is off unless you enable it, and even then covers only verified, idle, orphaned build and test processes while memory pressure is elevated, and language servers whose editor has exited.") {
                toggle("Terminate verified abandoned build/test processes and orphaned language servers automatically", s.autoTerminateAbandoned) { v in model.updateSettings { $0.autoTerminateAbandoned = v } }
                stepper(s.idleMinutesBeforeAbandoned, 5...720, step: 5, label: { "Call a process idle after \($0) min without CPU activity" }) { v in model.updateSettings { $0.idleMinutesBeforeAbandoned = v } }
                stepper(s.gracefulTerminationSeconds, 2...120, label: { "Wait \($0) s for a graceful exit" }) { v in model.updateSettings { $0.gracefulTerminationSeconds = v } }
            }

            Caption("Safety").padding(.top, 6)
            group("Protection rules", "Paths, projects and services PEPEL must leave alone. Credentials, agent state, git metadata, source code and model weights are protected without any rule.") {
                ForEach(model.protections) { rule in
                    HStack(spacing: 8) {
                        Badge(text: Self.protectionKindTitle(rule.kind), tint: Theme.forest)
                        Text(rule.kind == .path || rule.kind == .pin || rule.kind == .project ? PathUtil.display(rule.value) : rule.value).font(Theme.mono).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                        if !rule.note.isEmpty { Text(rule.note).font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1) }
                        Spacer()
                        Button("Remove") { model.unprotect(rule) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
                if model.protections.isEmpty { Text("No custom rules.").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
                HStack(spacing: 8) {
                    Picker("Kind", selection: $newRuleKind) {
                        Text("Path").tag(ProtectionKind.path)
                        Text("Project").tag(ProtectionKind.project)
                        Text("Process name").tag(ProtectionKind.processName)
                        Text("Command contains").tag(ProtectionKind.command)
                        Text("Listening port").tag(ProtectionKind.port)
                    }
                    .labelsHidden().frame(width: 150)
                    TextField(newRuleKind == .port ? "8000" : newRuleKind == .processName ? "postgres" : newRuleKind == .command ? "uvicorn api:app" : "~/projects/keep-this", text: $newRule)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    Button("Add") {
                        model.protect(newRuleKind, newRule.trimmingCharacters(in: .whitespaces))
                        newRule = ""
                    }
                    .buttonStyle(QuietButtonStyle()).disabled(newRule.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            group("Permissions", "PEPEL runs with your normal user rights. It does not request Full Disk Access or Accessibility. Administrator rights are asked for once, only if you use the file cache flush.") {
                Text("Without Full Disk Access some folders cannot be read; they are reported as unreadable and counted as a lower bound. Processes of other users are not inspected. Notifications and the login item ask for approval the first time they are used.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func modeHelp(_ mode: MonitoringMode) -> String {
        switch mode {
        case .manual: L("PEPEL samples memory and processes but scans storage only when you ask.")
        case .notifyOnly: L("PEPEL scans in the background and tells you what it finds. Nothing is removed without you.")
        case .automaticSafe: L("As above, and items classified safe are removed automatically when no build, agent session or lease involves them.")
        }
    }

    /// The kind of a protection rule, in words; `rawValue` stays the stored identity.
    static func protectionKindTitle(_ kind: ProtectionKind) -> String {
        switch kind {
        case .path: L("path")
        case .pin: L("pin")
        case .project: L("project")
        case .processName: L("process name")
        case .command: L("command")
        case .port: L("port")
        }
    }

    /// `title` is a translation key and also the group's identity (its English text).
    private func group<Content: View>(_ resource: LocalizedStringResource, _ subtitle: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        let title = resource.key
        let open = expanded.contains(title)
        let state = status(title, model.settings)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { if open { expanded.remove(title) } else { expanded.insert(title) } }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(resource).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer(minLength: 8)
                    if let state { Badge(text: state.text, tint: state.on ? Theme.forest : Theme.tertiary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "expanded" : "collapsed")
            if open {
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
        .panel(padding: open ? 12 : 10)
    }

    static let weekdays: [(Int, LocalizedStringKey)] = [(2, "Monday"), (3, "Tuesday"), (4, "Wednesday"), (5, "Thursday"), (6, "Friday"), (7, "Saturday"), (1, "Sunday")]

    static let groupTitles = [
        "Leave alone", "Project roots", "Monitoring", "Cleanup", "Disk: Docker", "Disk: projects left untouched", "Disk: tool caches", "Disk: application caches", "Disk: Android emulators",
        "Disk: Downloads and screenshots", "Disk: Clausona backups", "Disk: temporary files", "Disk: logs", "Build retention", "Free memory", "Agent sessions",
        "Apps that stay open without windows", "Applications", "Memory budgets", "Containers", "Processes", "Protection rules", "Permissions",
    ]

    /// The one-line state shown on a folded group's heading.
    private func status(_ title: String, _ s: PepelSettings) -> (text: String, on: Bool)? {
        // Each badge is one whole phrase; `on()` is the text when the rule is switched on.
        func rule(_ isOn: Bool, _ on: @autoclosure () -> String) -> (String, Bool) { (isOn ? on() : L("Off"), isOn) }
        switch title {
        case "Project roots": return (L("\(s.projectRoots.count) roots"), true)
        case "Monitoring": return (s.paused ? L("Paused") : s.monitoringMode == .manual ? L("Manual") : s.monitoringMode == .notifyOnly ? L("Notify only") : L("Automatic"), !s.paused)
        case "Cleanup": return (s.deletionMode == .trash ? L("Always Trash") : s.deletionMode == .permanent ? L("Permanent") : L("Safe removed · review to Trash"), true)
        case "Disk: Docker": return rule(s.dockerAutoClean, L("On · \(s.dockerUnusedDays) days"))
        case "Disk: projects left untouched": return rule(s.cleanStaleProjects, L("On · \(s.staleProjectDays) days"))
        case "Disk: tool caches":
            return rule(s.trimCaches, s.cacheSizeLimitGB > 0 ? L("On · \(s.cacheUnusedDays) days · \(s.cacheSizeLimitGB) GB cap") : L("On · \(s.cacheUnusedDays) days"))
        case "Disk: application caches": return rule(s.cleanAppCaches, L("On · \(s.appCacheUnusedDays) days"))
        case "Disk: Android emulators":
            return rule(s.cleanAndroidEmulators, s.cleanUnusedSystemImages ? L("On · \(s.emulatorUnusedDays) days · images") : L("On · \(s.emulatorUnusedDays) days"))
        case "Disk: Downloads and screenshots":
            let text: String
            switch (s.tidyScreenshots, s.tidyDownloads) {
            case (true, true): text = L("On · screenshots \(s.screenshotDays) d · downloads \(s.downloadDays) d")
            case (true, false): text = L("On · screenshots \(s.screenshotDays) d")
            case (false, true): text = L("On · downloads \(s.downloadDays) d")
            case (false, false): text = ""
            }
            return rule(s.tidyScreenshots || s.tidyDownloads, text)
        case "Disk: Clausona backups": return rule(s.cleanToolBackups, L("On · keep \(s.toolBackupsKeep), \(s.toolBackupsDays) days"))
        case "Disk: temporary files": return rule(s.cleanTempFiles, L("On · \(s.tempDays) days"))
        case "Disk: logs": return rule(s.cleanOldLogs, L("On · \(s.logDays) days"))
        case "Agent sessions":
            return rule(s.freezeIdleAgents || s.terminateSleepingAgents, s.freezeIdleAgents ? L("On · freeze after \(s.freezeAfterMinutes) min") : L("On · end after \(s.agentSleepMinutes) min"))
        case "Apps that stay open without windows": return rule(!s.quitWhenWindowless.isEmpty, L("On · \(s.quitWhenWindowless.count) apps"))
        case "Leave alone": return ("\(s.leaveAlone.count)", true)
        case "Memory budgets": return s.memoryBudgets.isEmpty ? (L("None"), false) : ("\(s.memoryBudgets.count)", true)
        case "Containers": return rule(s.stopContainersOfIdleProjects, L("On · after \(s.projectIdleGraceMinutes) min idle"))
        case "Processes": return rule(s.autoTerminateAbandoned, L("On · abandoned only"))
        case "Free memory":
            return rule(
                s.freeMemoryHotkey || s.freeMemoryOnLock,
                s.freeMemoryHotkey && s.freeMemoryOnLock ? L("On · hotkey · on lock") : s.freeMemoryHotkey ? L("On · hotkey") : L("On · on lock"))
        case "Protection rules": return ("\(model.protections.count)", !model.protections.isEmpty)
        default: return nil
        }
    }

    /// Starting with the Mac: on top and always open, since it decides whether PEPEL runs at all.
    private var startup: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("Start PEPEL when you log in", isOn: Binding(get: { LoginItem.isEnabled || LoginItem.awaitsApproval }, set: { model.setLaunchAtLogin($0) }))
                .font(.system(size: 13, weight: .semibold)).toggleStyle(.switch).controlSize(.small)
            Spacer(minLength: 8)
            Text(model.loginItemStatus).font(.system(size: 11)).foregroundStyle(LoginItem.awaitsApproval ? Theme.amber : Theme.tertiary)
                .multilineTextAlignment(.trailing)
            if LoginItem.awaitsApproval {
                Button("Open Login Items") { LoginItem.openSettings() }.buttonStyle(QuietButtonStyle())
            }
        }
        .panel()
    }

    /// Three ready-made sets for the daily disk rules, with what a choice would change shown first.
    private func presets(_ s: PepelSettings) -> some View {
        let current = SettingsPreset.matching(s)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Rule set").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Badge(text: current?.title ?? L("Custom"), tint: current == nil ? Theme.amber : Theme.forest)
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(SettingsPreset.allCases, id: \.self) { preset in
                    Button {
                        if current != preset { pendingPreset = preset }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preset.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(current == preset ? Theme.forest : Theme.text)
                            Text(preset.summary).font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(10)
                        .background(current == preset ? Theme.forestDim.opacity(0.5) : Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(current == preset ? Theme.forest.opacity(0.7) : Theme.stroke, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(current == preset ? .isSelected : [])
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if current == nil {
                Text("Your rules are tuned by hand. Choosing a set replaces the disk rules' switches and ages; keep lists, leave-alone items and memory settings stay as they are.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .panel()
        .confirmationDialog(
            "Switch to the \(pendingPreset?.title ?? "") rule set?", isPresented: Binding(get: { pendingPreset != nil }, set: { if !$0 { pendingPreset = nil } }), titleVisibility: .visible
        ) {
            Button("Switch to \(pendingPreset?.title ?? "")") {
                if let preset = pendingPreset { model.updateSettings { preset.apply(to: &$0) } }
                pendingPreset = nil
            }
            Button("Cancel", role: .cancel) { pendingPreset = nil }
        } message: {
            let changes = pendingPreset?.changes(from: s) ?? []
            let list = changes.prefix(14).joined(separator: "\n") + (changes.count > 14 ? "\n…" : "")
            Text(changes.isEmpty ? L("Nothing changes.") : L("\(changes.count) settings change:\n\(list)"))
        }
    }

    /// Items taken out of the daily rules from the plan on the Overview.
    @ViewBuilder
    private func leaveAloneGroup(_ s: PepelSettings) -> some View {
        if !s.leaveAlone.isEmpty {
            group("Leave alone", "Chosen from the plan for the next day. The daily rules pass these by; a person can still remove them by hand.") {
                ForEach(s.leaveAlone, id: \.self) { key in
                    HStack {
                        Text(Self.leaveAloneLabel(key)).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Let the rules act again") { model.activity.forgetLeaveAlone(key) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
    }

    static func leaveAloneLabel(_ key: String) -> String {
        if key.hasPrefix("path:") { return PathUtil.display(String(key.dropFirst(5))) }
        if key.hasPrefix("cache:") { return L("Tool cache \(String(key.dropFirst(6)))") }
        if key.hasPrefix("container:") { return L("Docker container \(String(key.dropFirst(10)))") }
        if key == "docker:images" { return L("Docker images") }
        if key == "docker:buildCache" { return L("Docker build cache") }
        return key
    }

    private func line(_ label: LocalizedStringKey, _ path: String, remove: @escaping @MainActor @Sendable () -> Void) -> some View {
        HStack {
            Badge(text: label)
            PathText(path: PathUtil.expand(path))
            Spacer()
            Button("Remove", action: remove).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
    }

    private func toggle(_ title: LocalizedStringKey, _ value: Bool, set: @escaping @MainActor @Sendable (Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { value }, set: set)).font(.system(size: 12)).toggleStyle(.checkbox)
    }

    /// The label is one whole sentence with the number in it, so a translation can decline it.
    private func stepper(
        _ value: Int, _ range: ClosedRange<Int>, step: Int = 1, label: (Int) -> LocalizedStringResource, set: @escaping @MainActor @Sendable (Int) -> Void
    ) -> some View {
        Stepper(value: Binding(get: { value }, set: { set(min(range.upperBound, max(range.lowerBound, $0))) }), in: range, step: step) {
            Text(label(value)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.text)
        }
        .accessibilityValue("\(value)")
    }

    private func picker<T: Hashable & Sendable>(_ title: LocalizedStringKey, selection: T, options: [(T, LocalizedStringKey)], set: @escaping @MainActor @Sendable (T) -> Void) -> some View {
        Picker(title, selection: Binding(get: { selection }, set: set)) {
            ForEach(options.indices, id: \.self) { Text(options[$0].1).tag(options[$0].0) }
        }
        .font(.system(size: 12)).frame(maxWidth: 420)
    }

    private func chooseFolder(_ done: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose")
        if panel.runModal() == .OK, let url = panel.url { done(url.path) }
    }
}
