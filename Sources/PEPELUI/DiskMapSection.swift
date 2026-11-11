import AppKit
import PEPELEngine
import SwiftUI

/// What PEPEL knows about one tile, which decides its colour.
struct DiskTileFacts: Sendable {
    /// Bytes inside the tile that PEPEL could clean.
    var reclaimable: Int64 = 0
    /// Marked by the user as not to be cleaned, or protected by PEPEL's own rules.
    var kept = false
}

/// The disk map: every folder as a tile whose area is its size on disk. Clicking a folder
/// opens it. Colour says what PEPEL knows: copper is what it could clean, green is what is kept.
struct DiskMapSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: DiskNode?
    /// Where on the map the folder being opened sits, so the new view grows out of it.
    @State private var zoomAnchor = UnitPoint.center
    /// True while going back up, so the view settles from slightly larger instead.
    @State private var goingUp = false

    /// Quick and decelerating: felt, not watched.
    static let motion = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.32)

    /// Opens a folder with the map growing out of the tile that was clicked.
    private func open(_ path: String, from rect: CGRect?, in size: CGSize) {
        if let rect, size.width > 0, size.height > 0 {
            zoomAnchor = UnitPoint(x: rect.midX / size.width, y: rect.midY / size.height)
        } else {
            zoomAnchor = .center
        }
        goingUp = rect == nil
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Self.motion) { model.showDiskMap(path) }
    }

    /// Tiles smaller than this share of the folder are shown together as one.
    private static let smallest = 0.004
    private static let mapHeight: CGFloat = 540

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(
                title: "Disk map",
                subtitle: "The whole disk as tiles: each is a folder or a file, and its area is its size. Click a folder to open it. Folders are measured one by one and appear as they finish.")
            navigation
            summary
            map
            detail
        }
        .onAppear { model.openDiskMapIfNeeded() }
    }

    // MARK: Where we are

    private var crumbs: [(name: String, path: String)] {
        let root = model.diskMapRoot
        var result = [(name: root == "/" ? model.diskName : PathUtil.display(root), path: root)]
        let prefix = root == "/" ? "/" : root + "/"
        guard model.diskMapPath != root, model.diskMapPath.hasPrefix(prefix) else { return result }
        var current = root == "/" ? "" : root
        for part in model.diskMapPath.dropFirst(prefix.count).split(separator: "/") {
            current += "/" + part
            result.append((String(part), current))
        }
        return result
    }

    private var navigation: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Whole disk") { model.setDiskMapRoot("/") }
                Button("Home folder") { model.setDiskMapRoot(NSHomeDirectory()) }
                ForEach(model.settings.projectRoots, id: \.self) { root in
                    Button(PathUtil.display(PathUtil.expand(root))) { model.setDiskMapRoot(PathUtil.expand(root)) }
                }
                Button("Applications") { model.setDiskMapRoot("/Applications") }
                Divider()
                Button("Choose a folder…") { chooseFolder() }
                Divider()
                Toggle("Read folders macOS guards (Documents, Downloads, Photos…)", isOn: Binding(get: { model.diskMapReadsGuarded }, set: { model.diskMapReadsGuarded = $0; model.measureDiskMap(model.diskMapPath) }))
            } label: {
                Image(systemName: "folder").font(.system(size: 11))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Choose which folder the map starts from.")
            .accessibilityLabel("Starting folder")

            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.tertiary) }
                let last = index == crumbs.count - 1
                Button(crumb.name) { open(crumb.path, from: nil, in: .zero) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: last ? .semibold : .regular))
                    .foregroundStyle(last ? Theme.text : Theme.secondary).lineLimit(1).disabled(last)
            }
            Spacer(minLength: 8)
            if model.diskMapPath != model.diskMapRoot {
                Button {
                    open(crumbs.dropLast().last?.path ?? model.diskMapRoot, from: nil, in: .zero)
                } label: {
                    Label("Up", systemImage: "arrow.up")
                }
                .buttonStyle(QuietButtonStyle()).keyboardShortcut(.upArrow, modifiers: .command)
                .help("Back to the folder above (⌘↑).")
            }
            if model.isMeasuringDiskMap {
                Button("Stop") { model.cancelDiskMap() }.buttonStyle(QuietButtonStyle())
            } else {
                Button {
                    model.measureDiskMap(model.diskMapPath)
                } label: {
                    Label("Measure again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(QuietButtonStyle())
            }
        }
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            if let level = model.diskMapLevel {
                Text(Bytes.format(headline(level))).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: headline(level))
                Text(caption(level)).font(.system(size: 12)).foregroundStyle(level.complete || level.pending > 0 ? Theme.secondary : Theme.amber)
            } else {
                Text("—").font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            legend("PEPEL can clean", Theme.copper.opacity(0.6))
            legend("Kept", Theme.forestDim)
            legend("Everything else", Theme.raised)
        }
    }

    /// At the top of the disk the figure is what the disk itself reports as used; elsewhere, what was measured.
    private func headline(_ level: DiskLevel) -> Int64 {
        if level.path == "/", let t = model.live?.telemetry, t.diskTotalBytes > 0 { return t.diskTotalBytes - t.diskFreeBytes }
        return level.bytes
    }

    private func caption(_ level: DiskLevel) -> String {
        var parts: [String] = []
        if level.path == "/", let t = model.live?.telemetry, t.diskTotalBytes > 0 {
            parts.append(L("used of \(Bytes.format(t.diskTotalBytes)) · \(Bytes.format(t.diskAvailableBytes)) available"))
        }
        if level.pending > 0 {
            parts.append(L("measuring, \(level.pending) folders left · \(Bytes.format(level.bytes)) so far"))
        } else {
            let ago = TimeFormat.ago(level.measuredAt)
            parts.append(
                level.complete
                    ? L("\(level.nodes.count) items · measured \(ago)")
                    : L("\(level.nodes.count) items · measured \(ago) · stopped early, sizes are partial"))
        }
        return parts.joined(separator: " · ")
    }

    private func legend(_ text: LocalizedStringKey, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 10, height: 10)
                .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
            Text(text).font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
    }

    // MARK: The map

    /// The nodes to draw: everything large enough, and the rest as one tile.
    static func tiles(_ level: DiskLevel, smallest: Double = DiskMapSection.smallest) -> [DiskNode] {
        let total = max(1, level.bytes)
        var shown = level.nodes.filter { $0.kind == .restricted || Double($0.bytes) / Double(total) >= smallest }
        let rest = level.nodes.filter { $0.kind != .restricted && Double($0.bytes) / Double(total) < smallest && $0.bytes > 0 }
        if !rest.isEmpty {
            shown.append(DiskNode(path: level.path, name: L("\(rest.count) smaller items"), kind: .smallFiles, bytes: rest.reduce(0) { $0 + $1.bytes }, fileCount: rest.reduce(0) { $0 + $1.fileCount }))
        }
        return shown.sorted { $0.bytes > $1.bytes }
    }

    @ViewBuilder private var map: some View {
        if let level = model.diskMapDisplayLevel, !level.nodes.isEmpty {
            let nodes = Self.tiles(level)
            // A folder that was not read has no size; it gets a small fixed share so it can be seen and opened.
            let floor = Double(max(1, level.bytes)) * 0.012
            let weights = nodes.map { $0.kind == .restricted ? floor : Double($0.bytes) }
            GeometryReader { geometry in
                let rects = Treemap.layout(weights, in: CGRect(origin: .zero, size: geometry.size))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                        let rect = rects[index]
                        if rect.width >= 3, rect.height >= 3 {
                            DiskTile(
                                node: node, facts: model.diskMapFacts, inside: node.kind == .folder ? model.diskMapLevels[node.path] : nil, size: rect.size,
                                hoveredID: hovered?.id, open: { open($0, from: rect, in: geometry.size) }, reveal: { model.reveal($0) }, hover: { hovered = $0 })
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY)
                                // A folder that has just been measured fades in; the others slide and resize to make room.
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94)))
                        }
                    }
                }
                .animation(reduceMotion ? .easeOut(duration: 0.15) : Self.motion, value: nodes.map { "\($0.id):\($0.bytes)" })
                // Opening a folder: the new map grows out of the tile that was clicked; going back, it settles from slightly larger.
                .id(level.path)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .asymmetric(insertion: .scale(scale: goingUp ? 1.05 : 0.9, anchor: goingUp ? .center : zoomAnchor).combined(with: .opacity), removal: .opacity))
            }
            .frame(height: Self.mapHeight)
            .overlay(alignment: .bottomLeading) {
                if model.isMeasuringDiskMap { measuring.padding(10) }
            }
        } else if model.isMeasuringDiskMap {
            measuring
            .frame(maxWidth: .infinity).frame(height: Self.mapHeight).panel(padding: 0)
        } else {
            EmptyState(symbol: "square.grid.2x2", title: "Nothing to show", message: "This folder is empty, or it could not be read.")
                .frame(maxWidth: .infinity).frame(height: Self.mapHeight).panel(padding: 0)
        }
    }

    private var measuring: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(model.diskMapLevel.map { $0.pending > 0 ? L("Measuring folder by folder: \($0.pending) left") : L("Measuring") } ?? L("Measuring"))
                .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
    }

    // MARK: What is under the pointer

    @ViewBuilder private var detail: some View {
        if let node = hovered, let level = model.diskMapLevel {
            let facts = model.diskMapFacts[node.id] ?? DiskTileFacts()
            HStack(spacing: 12) {
                Image(systemName: node.kind == .file ? "doc" : node.kind == .restricted ? "lock" : node.kind == .unmeasured ? "questionmark.square.dashed" : node.kind == .smallFiles ? "square.stack.3d.up" : "folder")
                    .foregroundStyle(Theme.secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    if node.kind != .smallFiles, node.kind != .unmeasured { PathText(path: node.path) }
                }
                Spacer()
                Text(explanation(node, facts)).font(.system(size: 11)).foregroundStyle(facts.reclaimable > 0 ? Theme.copper : Theme.secondary)
                    .lineLimit(2).multilineTextAlignment(.trailing)
                if node.kind != .restricted {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Bytes.format(node.bytes)).font(.system(size: 14, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text)
                        let share = String(format: "%.1f%%", Double(node.bytes) / Double(max(1, level.bytes)) * 100)
                        Text(node.fileCount > 1 ? L("\(share) of this folder · \(node.fileCount) files") : L("\(share) of this folder"))
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.tertiary)
                    }
                }
            }
            .panel(padding: 10)
        } else {
            Text("Point at a tile to see what it is. Folders macOS guards, such as Documents and Photos, are not read until you open them.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).frame(maxWidth: .infinity, alignment: .leading).panel(padding: 10)
        }
    }

    private func explanation(_ node: DiskNode, _ facts: DiskTileFacts) -> String {
        if node.kind == .restricted { return L("Not read: macOS guards this folder. Open it to measure it; macOS may ask for access.") }
        if node.kind == .unmeasured { return L("Used according to the disk, but in no folder PEPEL may read: system data, other users, guarded folders, snapshots and swap.") }
        if facts.kept { return L("Kept: marked as not to be cleaned, or protected by PEPEL's rules.") }
        if facts.reclaimable > 0 { return L("PEPEL can clean \(Bytes.format(min(facts.reclaimable, node.bytes))) of this.") }
        if node.unreadable > 0 { return L("\(node.unreadable) entries inside could not be read; the size is a lower bound.") }
        return node.kind == .smallFiles ? L("Files and folders too small to draw on their own.") : ""
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.setDiskMapRoot(url.path) }
    }
}

/// One tile of the map. A folder large enough to hold them shows what is inside it as smaller
/// tiles, so the first look already says where the space went; each of those opens on a click too.
private struct DiskTile: View {
    let node: DiskNode
    let facts: [String: DiskTileFacts]
    /// The folder's own contents, when they were measured in the same walk.
    let inside: DiskLevel?
    let size: CGSize
    let hoveredID: String?
    let open: (String) -> Void
    let reveal: (String) -> Void
    let hover: (DiskNode?) -> Void

    private static let header: CGFloat = 24
    private var showsInside: Bool { inside.map { !$0.nodes.isEmpty } == true && size.width >= 150 && size.height >= 110 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsInside, let inside {
                // The folder is a tray one step below its contents; the contents are the tiles.
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.surface)
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(hoveredID == node.id ? Theme.text.opacity(0.55) : Theme.stroke, lineWidth: 1)
                Leaf(node: node, fact: facts[node.id] ?? DiskTileFacts(), size: CGSize(width: size.width - 2, height: Self.header), hovered: false, bare: true, open: open, reveal: reveal, hover: hover)
                    .frame(width: size.width - 2, height: Self.header)
                let area = CGSize(width: size.width - 10, height: size.height - Self.header - 6)
                let nodes = DiskMapSection.tiles(inside, smallest: 0.006)
                let floor = Double(max(1, inside.bytes)) * 0.012
                let rects = Treemap.layout(nodes.map { $0.kind == .restricted ? floor : Double($0.bytes) }, in: CGRect(origin: .zero, size: area))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(nodes.enumerated()), id: \.element.id) { index, child in
                        let rect = rects[index]
                        if rect.width >= 3, rect.height >= 3 {
                            Leaf(node: child, fact: facts[child.id] ?? DiskTileFacts(), size: rect.size, hovered: hoveredID == child.id, bare: false, open: open, reveal: reveal, hover: hover)
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY)
                        }
                    }
                }
                .frame(width: area.width, height: area.height, alignment: .topLeading)
                .offset(x: 5, y: Self.header)
            } else {
                Leaf(node: node, fact: facts[node.id] ?? DiskTileFacts(), size: size, hovered: hoveredID == node.id, bare: false, open: open, reveal: reveal, hover: hover)
            }
        }
        // One point of the page shows through on every side: tiles are separated by space, not by lines.
        .padding(1)
    }
}

/// A single rectangle: a real button, so it has focus, a keyboard action and an accessibility label.
private struct Leaf: View {
    let node: DiskNode
    let fact: DiskTileFacts
    let size: CGSize
    let hovered: Bool
    /// A folder's title strip: the name and size without a rectangle of its own.
    let bare: Bool
    let open: (String) -> Void
    let reveal: (String) -> Void
    let hover: (DiskNode?) -> Void

    /// How much of the tile PEPEL could clean, as a share.
    private var cleanable: Double { node.bytes > 0 ? min(1, Double(fact.reclaimable) / Double(node.bytes)) : 0 }

    private var fill: Color {
        if node.kind == .restricted || node.kind == .unmeasured { return Theme.background }
        if fact.kept { return Theme.forestDim }
        // Copper in proportion to what could be cleaned: a folder with a little of it stays neutral.
        if cleanable >= 0.02 { return Theme.copper.opacity(0.10 + 0.5 * cleanable) }
        return node.kind == .smallFiles ? Theme.raised.opacity(0.55) : Theme.raised
    }

    var body: some View {
        Button {
            if node.canOpen { open(node.path) }
        } label: {
            ZStack(alignment: .topLeading) {
                if !bare {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.raised)
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(fill)
                    if node.kind == .restricted || node.kind == .unmeasured {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.text.opacity(hovered && node.canOpen ? 0.05 : 0))
                    RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.text.opacity(hovered ? 0.55 : 0), lineWidth: 1)
                }
                if bare {
                    HStack(spacing: 6) {
                        Text(node.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                        Text(Bytes.format(node.bytes)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary).lineLimit(1)
                        if cleanable >= 0.02, size.width >= 260 {
                            Text("\(Bytes.format(min(fact.reclaimable, node.bytes))) can be cleaned").font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.copper).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).frame(height: size.height)
                } else if size.width >= 54, size.height >= 22 {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            if node.kind == .restricted { Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(Theme.tertiary) }
                            Text(node.name).font(.system(size: size.width >= 200 && size.height >= 90 ? 13 : 11, weight: .medium))
                                .foregroundStyle(node.kind == .restricted || node.kind == .smallFiles || node.kind == .unmeasured ? Theme.secondary : Theme.text).lineLimit(1).truncationMode(.middle)
                        }
                        if size.height >= 38 {
                            Text(node.kind == .restricted ? L("not read") : Bytes.format(node.bytes)).font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(cleanable >= 0.02 && !fact.kept ? Theme.text.opacity(0.85) : Theme.secondary)
                        }
                        if size.width >= 150, size.height >= 76, node.fileCount > 1 {
                            Text("\(node.fileCount) files").font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.tertiary)
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                }
            }
            .padding(bare ? 0 : 1)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: hovered)
        }
        .buttonStyle(TilePress(enabled: node.canOpen))
        .onHover { inside in hover(inside ? node : nil) }
        .contextMenu {
            if node.canOpen { Button("Open") { open(node.path) } }
            if node.kind != .smallFiles, node.kind != .unmeasured {
                Button("Show in Finder") { reveal(node.path) }
                Button("Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.path, forType: .string)
                }
            }
        }
        .accessibilityLabel("\(node.name), \(node.kind == .restricted ? L("not read") : Bytes.format(node.bytes))")
        .accessibilityHint(node.canOpen ? "Opens this folder." : "")
    }
}

/// A folder tile gives a little under the pointer when pressed, confirming the click before it opens.
private struct TilePress: ButtonStyle {
    let enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(enabled && configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
