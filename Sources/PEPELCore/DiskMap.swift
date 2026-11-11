import CoreGraphics
import Foundation

/// One tile of the disk map: a folder, a large file, the small files of a folder taken
/// together, or a folder PEPEL does not read without being asked.
public struct DiskNode: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case folder, file
        /// Every file of the folder that is too small to show on its own.
        case smallFiles
        /// A folder macOS guards (Documents, Photos, Mail…). It is not read until the user opens it.
        case restricted
    }

    public var path: String
    public var name: String
    public var kind: Kind
    public var bytes: Int64
    public var fileCount: Int
    /// Entries inside that could not be read; the size is then a lower bound.
    public var unreadable: Int

    public var id: String { kind == .smallFiles ? path + "/\u{1}small" : path }
    public var canOpen: Bool { kind == .folder || kind == .restricted }

    public init(path: String, name: String, kind: Kind, bytes: Int64, fileCount: Int = 0, unreadable: Int = 0) {
        self.path = path
        self.name = name
        self.kind = kind
        self.bytes = bytes
        self.fileCount = fileCount
        self.unreadable = unreadable
    }
}

/// What one folder contains, largest first, as measured at one moment.
public struct DiskLevel: Codable, Sendable, Hashable {
    public var path: String
    public var nodes: [DiskNode]
    public var measuredAt: Date
    /// False when measuring was stopped before it finished.
    public var complete: Bool

    public var bytes: Int64 { nodes.reduce(0) { $0 + $1.bytes } }

    public init(path: String, nodes: [DiskNode], measuredAt: Date = Date(), complete: Bool = true) {
        self.path = path
        self.nodes = nodes
        self.measuredAt = measuredAt
        self.complete = complete
    }
}

/// Squarified treemap layout (Bruls, Huizing, van Wijk): rectangles whose areas are proportional
/// to the weights and whose shapes stay as close to squares as the space allows, so that sizes
/// can be compared by eye and labels fit.
public enum Treemap {
    /// - Parameter weights: positive values, largest first. Zero and negative weights get an empty rectangle.
    public static func layout(_ weights: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: weights.count)
        let total = weights.filter { $0 > 0 }.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let areas = weights.map { max(0, $0) * scale }
        var free = rect
        var index = 0
        while index < areas.count {
            guard areas[index] > 0 else { index += 1; continue }
            let side = Double(min(free.width, free.height))
            guard side > 0 else { break }
            // Grow the row while adding the next tile does not make the worst shape in it worse.
            var row = [index]
            var sum = areas[index]
            var worst = ratio(sum: sum, smallest: areas[index], largest: areas[index], side: side)
            var next = index + 1
            while next < areas.count, areas[next] > 0 {
                let candidate = ratio(sum: sum + areas[next], smallest: areas[next], largest: areas[row[0]], side: side)
                guard candidate <= worst else { break }
                row.append(next)
                sum += areas[next]
                worst = candidate
                next += 1
            }
            // Lay the row along the shorter side of what is left.
            let thickness = sum / side
            var offset = 0.0
            let horizontal = free.width >= free.height
            for item in row {
                let length = areas[item] / thickness
                result[item] = horizontal
                    ? CGRect(x: Double(free.minX), y: Double(free.minY) + offset, width: thickness, height: length)
                    : CGRect(x: Double(free.minX) + offset, y: Double(free.minY), width: length, height: thickness)
                offset += length
            }
            free = horizontal
                ? CGRect(x: Double(free.minX) + thickness, y: Double(free.minY), width: max(0, Double(free.width) - thickness), height: Double(free.height))
                : CGRect(x: Double(free.minX), y: Double(free.minY) + thickness, width: Double(free.width), height: max(0, Double(free.height) - thickness))
            index = next
        }
        return result
    }

    /// The worst width-to-height ratio in a row laid along `side`.
    private static func ratio(sum: Double, smallest: Double, largest: Double, side: Double) -> Double {
        let squared = side * side
        return max(squared * largest / (sum * sum), sum * sum / (squared * smallest))
    }
}
