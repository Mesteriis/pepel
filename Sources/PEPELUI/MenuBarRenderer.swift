import AppKit
import PEPELEngine

/// What the menu bar item shows, read from the model in one place so it can be drawn or tested.
public struct MenuBarReading: Sendable {
    public var status: NSColor?
    public var memoryUsed: Int64
    public var memoryTotal: Int64
    public var pressure: MemoryPressureLevel
    /// Memory in use as a share of physical memory, oldest first.
    public var history: [Double]
    public var diskAvailable: Int64
    public var text: String?

    public init(status: NSColor?, memoryUsed: Int64, memoryTotal: Int64, pressure: MemoryPressureLevel, history: [Double], diskAvailable: Int64, text: String?) {
        self.status = status
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.pressure = pressure
        self.history = history
        self.diskAvailable = diskAvailable
        self.text = text
    }
}

/// Draws the whole menu bar item as one image: the glyph with its status dot, and for the
/// memory modes a graph and figures. Colours are resolved while drawing, so the image follows a
/// light or dark menu bar.
public enum MenuBarRenderer {
    static let height: CGFloat = 22
    static let graphSize = CGSize(width: 34, height: 15)

    /// Nil when the mode is drawn as the plain glyph plus the button's own title.
    public static func image(_ mode: MenuBarMode, _ r: MenuBarReading) -> NSImage? {
        switch mode {
        case .memoryAndDisk: return compose(r, graph: false, lines: nil, inline: inlineText(r))
        case .memoryGraph: return compose(r, graph: true, lines: nil, inline: Bytes.format(r.memoryUsed))
        case .memoryGraphAndDisk: return compose(r, graph: true, lines: (Bytes.format(r.memoryUsed), Bytes.format(r.diskAvailable)), inline: nil)
        default: return nil
        }
    }

    static func inlineText(_ r: MenuBarReading) -> String { "\(Bytes.format(r.memoryUsed))  ·  \(Bytes.format(r.diskAvailable))" }

    static func pressureColor(_ level: MemoryPressureLevel) -> NSColor {
        switch level {
        case .normal: NSColor(Theme.forest)
        case .elevated: NSColor(Theme.amber)
        case .critical: NSColor(Theme.danger)
        }
    }

    private static func compose(_ r: MenuBarReading, graph: Bool, lines: (String, String)?, inline: String?) -> NSImage {
        let glyphSide: CGFloat = 18, gap: CGFloat = 5
        let inlineFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        let iconSide: CGFloat = 11
        let inlineAttributes: [NSAttributedString.Key: Any] = [.font: inlineFont]
        let smallAttributes: [NSAttributedString.Key: Any] = [.font: smallFont]

        var width = glyphSide + 2
        if graph { width += gap + graphSize.width }
        var linesWidth: CGFloat = 0
        if let lines {
            linesWidth = iconSide + 2 + max((lines.0 as NSString).size(withAttributes: smallAttributes).width, (lines.1 as NSString).size(withAttributes: smallAttributes).width)
            width += gap + linesWidth
        }
        var inlineWidth: CGFloat = 0
        if let inline {
            inlineWidth = (inline as NSString).size(withAttributes: inlineAttributes).width
            width += gap + inlineWidth
        }
        width = ceil(width)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let label = NSColor.labelColor, faint = NSColor.tertiaryLabelColor
            // Glyph and status dot, as the plain icon has them.
            let glyph = AppImages.menuBar(status: r.status)
            glyph.draw(in: NSRect(x: 0, y: (height - glyphSide) / 2, width: glyphSide + 2, height: glyphSide))
            var x = glyphSide + 2 + gap

            if graph {
                let frame = NSRect(x: x, y: (height - graphSize.height) / 2, width: graphSize.width, height: graphSize.height)
                drawGraph(r, in: frame, faint: faint)
                x += graphSize.width + gap
            }
            if let lines {
                let lineHeight = smallFont.ascender - smallFont.descender
                let top = height / 2 + 0.5, bottom = height / 2 - lineHeight - 0.5
                drawSymbol("memorychip", at: NSPoint(x: x, y: top), side: iconSide, color: pressureColor(r.pressure))
                drawSymbol("internaldrive", at: NSPoint(x: x, y: bottom), side: iconSide, color: NSColor.secondaryLabelColor)
                (lines.0 as NSString).draw(at: NSPoint(x: x + iconSide + 2, y: top), withAttributes: [.font: smallFont, .foregroundColor: label])
                (lines.1 as NSString).draw(at: NSPoint(x: x + iconSide + 2, y: bottom), withAttributes: [.font: smallFont, .foregroundColor: label])
                x += linesWidth + gap
            }
            if let inline {
                let size = (inline as NSString).size(withAttributes: inlineAttributes)
                (inline as NSString).draw(at: NSPoint(x: x, y: (height - size.height) / 2), withAttributes: [.font: inlineFont, .foregroundColor: label])
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Memory in use over the last minutes, filled in the colour of the current pressure.
    private static func drawGraph(_ r: MenuBarReading, in frame: NSRect, faint: NSColor) {
        let outline = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
        faint.withAlphaComponent(0.18).setFill()
        outline.fill()
        let values = r.history.isEmpty ? [r.memoryTotal > 0 ? Double(r.memoryUsed) / Double(r.memoryTotal) : 0] : r.history
        let inner = frame.insetBy(dx: 1.5, dy: 1.5)
        let step = values.count > 1 ? inner.width / CGFloat(values.count - 1) : 0
        func point(_ index: Int) -> NSPoint {
            NSPoint(x: values.count > 1 ? inner.minX + CGFloat(index) * step : inner.maxX, y: inner.minY + inner.height * CGFloat(min(1, max(0, values[index]))))
        }
        let line = NSBezierPath()
        line.move(to: point(0))
        for index in values.indices.dropFirst() { line.line(to: point(index)) }
        if values.count == 1 { line.line(to: NSPoint(x: inner.minX, y: point(0).y)) }
        let area = line.copy() as! NSBezierPath
        area.line(to: NSPoint(x: values.count > 1 ? inner.maxX : inner.minX, y: inner.minY))
        area.line(to: NSPoint(x: values.count > 1 ? inner.minX : inner.maxX, y: inner.minY))
        area.close()
        let color = pressureColor(r.pressure)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        color.withAlphaComponent(0.35).setFill()
        area.fill()
        color.setStroke()
        line.lineWidth = 1.3
        line.lineJoinStyle = .round
        line.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawSymbol(_ name: String, at origin: NSPoint, side: CGFloat, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: side, weight: .bold).applying(.init(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let size = symbol.size
        let scale = min(side / max(size.width, 1), (side - 1) / max(size.height, 1))
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        symbol.draw(in: NSRect(x: origin.x + (side - drawn.width) / 2, y: origin.y + 1, width: drawn.width, height: drawn.height))
    }
}
