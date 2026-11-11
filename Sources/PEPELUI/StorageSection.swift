import PEPELEngine
import SwiftUI

struct StorageSection: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var filter: SafetyClass?
    @State private var expanded: String?
    @State private var confirmDocker = false
    @State private var confirmVolumes = false

    private func matches(_ item: StorageItem) -> Bool {
        if let filter, item.safety != filter { return false }
        guard !search.isEmpty else { return true }
        let needle = search.lowercased()
        return item.title.lowercased().contains(needle) || item.path.lowercased().contains(needle)
            || item.category.displayName.lowercased().contains(needle)
            || (model.projectName(item.projectID)?.lowercased().contains(needle) ?? false)
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
                    Text("disk image \(Bytes.format(report.diskImageBytes))").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Theme.secondary)
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
                    dockerRow("Volumes no container mounts", report.volumes.count, report.volumeBytes, plan.volumes.count, plan.bytes(.volumes), tint: Theme.amber)
                }
                ForEach(plan.skipped, id: \.self) { line in
                    Text(line).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
                HStack(spacing: 8) {
                    Button("Remove unused containers, images and cache · \(Bytes.format(plan.reproducibleBytes))…") { confirmDocker = true }
                        .buttonStyle(CopperButtonStyle(prominent: false)).disabled(plan.reproducibleBytes == 0 || model.isCleaningDocker)
                    Button("Remove \(plan.volumes.count) volumes · \(Bytes.format(plan.bytes(.volumes)))…") { confirmVolumes = true }
                        .buttonStyle(QuietButtonStyle()).disabled(plan.volumes.isEmpty || model.isCleaningDocker)
                    Button("Trim disk image") { model.compactDocker() }.buttonStyle(QuietButtonStyle()).disabled(model.isCleaningDocker)
                        .help("Hands blocks Docker no longer uses back to the Mac. Nothing is removed.")
                }
                if let done = model.dockerCleanReport {
                    Text("Last cleanup: " + done.steps.map { "\($0.kind.title.lowercased()) \($0.removed) of \($0.attempted)" }.joined(separator: ", ")
                        + ". Disk image \(Bytes.format(done.diskImageBefore)) → \(Bytes.format(done.diskImageAfter)).")
                        .font(.system(size: 11)).foregroundStyle(Theme.forest).fixedSize(horizontal: false, vertical: true)
                }
                Text("Containers, images and build cache can be rebuilt or pulled again, so they can also be removed automatically once a day (Settings). Volumes hold data and are only ever removed from here. Nothing is removed with force: Docker refuses what is in use.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            } else if !model.isReadingDocker {
                Text("Docker did not answer, or is not installed.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        .panel()
        .onAppear { if model.dockerDisk == nil { model.refreshDocker() } }
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
            Text("Volumes hold data such as databases and uploads. No container mounts these and they are older than \(days) days, but removing them cannot be undone and rebuilding does not bring them back.")
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
            docker
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "Projects", subtitle: "Repositories found under your project roots. Worktrees of one repository are grouped; artifact sizes cover only what PEPEL recognises as generated.")
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
