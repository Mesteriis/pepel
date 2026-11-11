import Foundation

/// How strongly an association (process → project, artifact → project, …) is supported by evidence.
/// Heuristic guesses are never presented as facts: every association carries one of these.
public enum Confidence: String, Codable, Sendable, CaseIterable, Comparable {
    /// Insufficient information.
    case unknown
    /// Strong heuristic evidence.
    case probable
    /// Direct process, filesystem, or metadata evidence.
    case verified

    private var rank: Int {
        switch self {
        case .unknown: 0
        case .probable: 1
        case .verified: 2
        }
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rank < rhs.rank }
}

/// Cleanup safety classification. The default for anything unclear is `.protected`.
public enum SafetyClass: String, Codable, Sendable, CaseIterable {
    /// Verified disposable data with no identified active dependency.
    case safe
    /// Reproducible or recoverable data whose removal may require rebuilding, downloading, or restarting tools.
    case review
    /// Potentially important data or data with unclear ownership. Never deleted by PEPEL.
    case protected
}

public enum Bytes {
    public static let kb: Int64 = 1_000
    public static let mb: Int64 = 1_000_000
    public static let gb: Int64 = 1_000_000_000

    /// Decimal units, matching Finder and Disk Utility.
    public static func format(_ value: Int64) -> String {
        let sign = value < 0 ? "-" : ""
        var x = Double(value.magnitude)
        let units = localizedUnits
        var i = 0
        while x >= 1000, i < units.count - 1 {
            x /= 1000
            i += 1
        }
        let number: String
        if i == 0 {
            number = String(Int(x))
        } else if x >= 100 {
            number = String(format: "%.0f", x)
        } else if x >= 10 {
            number = String(format: "%.1f", x)
        } else {
            number = String(format: "%.2f", x)
        }
        let separator = decimalSeparator == "." ? number : number.replacingOccurrences(of: ".", with: decimalSeparator)
        return "\(sign)\(separator) \(units[i])"
    }

    /// Units and the decimal separator in the app's language ("ГБ", "," in Russian); read once,
    /// since macOS applies a language change on the next launch.
    static let localizedUnits = [
        L(LocalizedStringResource("unit.B", defaultValue: "B")), L(LocalizedStringResource("unit.KB", defaultValue: "KB")),
        L(LocalizedStringResource("unit.MB", defaultValue: "MB")), L(LocalizedStringResource("unit.GB", defaultValue: "GB")),
        L(LocalizedStringResource("unit.TB", defaultValue: "TB")), L(LocalizedStringResource("unit.PB", defaultValue: "PB")),
    ]
    static let decimalSeparator = L(LocalizedStringResource("number.decimalSeparator", defaultValue: "."))

    /// Signed variant for growth figures ("+3.2 GB").
    public static func formatDelta(_ value: Int64) -> String {
        value > 0 ? "+" + format(value) : format(value)
    }
}

public enum TimeFormat {
    public static func age(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        if s < 60 { return L("\(s)s") }
        if s < 3600 { return L("\(s / 60)m") }
        if s < 86_400 { return L("\(s / 3600)h \(s % 3600 / 60)m") }
        return L("\(s / 86_400)d \(s % 86_400 / 3600)h")
    }

    public static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return L("unknown") }
        let age = age(now.timeIntervalSince(date))
        return L("\(age) ago")
    }
}

public enum NumberWords {
    private static let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]

    /// Small counts read better spelled out in narrative sentences.
    public static func spell(_ n: Int, capitalized: Bool = false) -> String {
        let s = (0..<words.count).contains(n) ? words[n] : String(n)
        return capitalized ? s.prefix(1).uppercased() + s.dropFirst() : s
    }
}
