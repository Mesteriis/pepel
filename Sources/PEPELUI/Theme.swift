import AppKit
import PEPELEngine
import SwiftUI

/// PEPEL's palette: graphite and forest-green surfaces, copper and ember for action, muted green
/// for health. Red is reserved for conditions that are actually dangerous.
public enum Theme {
    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        func make(_ hex: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? make(dark) : make(light)
        })
    }

    public static let background = dynamic(dark: 0x0E1311, light: 0xF3F4EF)
    public static let sidebar = dynamic(dark: 0x121916, light: 0xE9ECE5)
    public static let surface = dynamic(dark: 0x171F1B, light: 0xFFFFFF)
    public static let raised = dynamic(dark: 0x1F2924, light: 0xECEFE8)
    public static let stroke = dynamic(dark: 0x2A3630, light: 0xD6DBD1)
    public static let text = dynamic(dark: 0xE8ECE7, light: 0x1A211D)
    public static let secondary = dynamic(dark: 0x96A39B, light: 0x56635B)
    public static let tertiary = dynamic(dark: 0x66736B, light: 0x8A958D)
    public static let forest = dynamic(dark: 0x74B391, light: 0x2F7D57)
    public static let forestDim = dynamic(dark: 0x2B4739, light: 0xCFE5D8)
    public static let copper = dynamic(dark: 0xD38D55, light: 0xAE662E)
    public static let ember = dynamic(dark: 0xEC6A32, light: 0xCB4D1B)
    public static let amber = dynamic(dark: 0xE2AC4F, light: 0xA9770F)
    public static let danger = dynamic(dark: 0xE5534B, light: 0xC2302A)

    public static func color(for safety: SafetyClass) -> Color {
        switch safety {
        case .safe: forest
        case .review: copper
        case .protected: tertiary
        }
    }

    public static func color(for pressure: MemoryPressureLevel) -> Color {
        switch pressure {
        case .normal: forest
        case .elevated: amber
        case .critical: danger
        }
    }

    public static func color(for severity: AlertSeverity) -> Color {
        switch severity {
        case .info: secondary
        case .warning: amber
        case .critical: danger
        }
    }

    public static let mono = Font.system(size: 11, design: .monospaced)

    /// Display words for enums whose `rawValue` is their stored identity.
    public static func title(for safety: SafetyClass) -> String {
        switch safety {
        case .safe: L("safe")
        case .review: L("review")
        case .protected: L("protected")
        }
    }

    public static func title(for pressure: MemoryPressureLevel) -> String {
        switch pressure {
        case .normal: L(LocalizedStringResource("pressure.normal", defaultValue: "Normal"))
        case .elevated: L(LocalizedStringResource("pressure.elevated", defaultValue: "Elevated"))
        case .critical: L(LocalizedStringResource("pressure.critical", defaultValue: "Critical"))
        }
    }

    public static func title(for confidence: Confidence) -> String {
        switch confidence {
        case .unknown: L("unknown")
        case .probable: L("probable")
        case .verified: L("verified")
        }
    }

    public static func title(for lifecycle: LifecycleClass) -> String {
        switch lifecycle {
        case .agentSession: L("agent session")
        case .activeBuildOrTest: L("active build or test")
        case .activeDevService: L("active dev service")
        case .backgroundService: L("background service")
        case .abandonedSubprocess: L("abandoned subprocess")
        case .suspiciousOrphan: L("suspicious orphan")
        case .unknown: L("unknown")
        }
    }

    public static func title(for status: BuildStatus) -> String {
        switch status {
        case .succeeded: L("succeeded")
        case .failed: L("failed")
        case .running: L("running")
        case .unknown: L("unknown")
        }
    }
}

extension View {
    func panel(padding: CGFloat = 12) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

/// Literals passed to these primitives are translation keys (as with `Text`); a `String` built
/// elsewhere is shown as it is, so it must already be localized (`L(...)`).
struct SectionTitle: View {
    let title: Text
    var subtitle: Text?

    init(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
    }

    @_disfavoredOverload
    init(title: LocalizedStringKey, subtitle: String?) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text(verbatim: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title.font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
            if let subtitle {
                subtitle.font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct Caption: View {
    let text: Text
    init(_ key: LocalizedStringKey) { text = Text(key) }
    @_disfavoredOverload init(_ text: String) { self.text = Text(verbatim: text) }

    var body: some View {
        text.textCase(.uppercase).font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(Theme.tertiary)
            .lineLimit(1).minimumScaleFactor(0.75)
    }
}

struct MetricTile: View {
    let label: LocalizedStringKey
    /// A figure, shown as it is.
    let value: String
    /// Already localized (`L(...)`).
    var detail: String?
    var tint: Color = Theme.text
    var fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Caption(label)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7).contentTransition(.numericText())
            if let fraction { Meter(fraction: fraction, tint: tint == Theme.text ? Theme.forest : tint) }
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .panel(padding: 11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label) + Text(verbatim: ": \(value)\(detail.map { ", \($0)" } ?? "")"))
    }
}

struct Meter: View {
    let fraction: Double
    var tint: Color = Theme.forest
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.raised)
                Capsule().fill(tint).frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.35), value: fraction)
        .accessibilityHidden(true)
    }
}

struct Badge: View {
    let text: Text
    var tint: Color = Theme.secondary

    init(text: LocalizedStringKey, tint: Color = Theme.secondary) {
        self.text = Text(text)
        self.tint = tint
    }

    @_disfavoredOverload
    init(text: String, tint: Color = Theme.secondary) {
        self.text = Text(verbatim: text)
        self.tint = tint
    }

    var body: some View {
        text.font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .lineLimit(1).fixedSize()
    }
}

struct ConfidenceBadge: View {
    let confidence: Confidence

    var body: some View {
        Badge(
            text: Theme.title(for: confidence),
            tint: confidence == .verified ? Theme.forest : confidence == .probable ? Theme.amber : Theme.tertiary
        )
        .help(
            confidence == .verified
                ? "Direct process, filesystem or metadata evidence."
                : confidence == .probable ? "Strong heuristic evidence, not proof." : "Not enough information.")
    }
}

struct EmptyState: View {
    let symbol: String
    let title: Text
    let message: Text

    init(symbol: String, title: LocalizedStringKey, message: LocalizedStringKey) {
        self.symbol = symbol
        self.title = Text(title)
        self.message = Text(message)
    }

    @_disfavoredOverload
    init(symbol: String, title: String, message: String) {
        self.symbol = symbol
        self.title = Text(verbatim: title)
        self.message = Text(verbatim: message)
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(Theme.tertiary)
            title.font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            message.font(.system(size: 12)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
        .accessibilityElement(children: .combine)
    }
}

/// Copper is the colour of cleanup: the one action PEPEL exists to make safe.
struct CopperButtonStyle: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : Theme.copper)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(
                prominent ? AnyShapeStyle(Theme.copper) : AnyShapeStyle(Theme.copper.opacity(0.13)),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.raised.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
            .opacity(enabled ? 1 : 0.4)
    }
}

struct PathText: View {
    let path: String

    var body: some View {
        Text(PathUtil.display(path)).font(Theme.mono).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle)
            .help(path).textSelection(.enabled)
    }
}

enum AppImages {
    /// The glyph from the app bundle; a system symbol when running outside a bundle.
    static func glyph(_ name: String, fallbackSymbol: String, pointSize: CGFloat) -> NSImage {
        if let image = Bundle.main.image(forResource: name) {
            image.size = NSSize(width: pointSize, height: pointSize)
            return image
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize * 0.8, weight: .semibold)
        return NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: "PEPEL")?.withSymbolConfiguration(configuration) ?? NSImage()
    }

    /// Menu bar image: the glyph with a small status dot, drawn in colour so health reads at a glance.
    static func menuBar(status: NSColor?) -> NSImage {
        let side: CGFloat = 18
        let glyph = glyph("MenuBarIcon", fallbackSymbol: "flame.fill", pointSize: side)
        let image = NSImage(size: NSSize(width: side + 2, height: side), flipped: false) { _ in
            glyph.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            if let status {
                let dot = NSRect(x: side - 5, y: 0, width: 7, height: 7)
                NSColor.black.withAlphaComponent(0.55).setFill()
                NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
                status.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
