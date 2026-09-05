import Foundation

public struct ChartBarRect: Equatable, Sendable {
    public let x: Int32
    public let y: Int32
    public let width: Int32
    public let height: Int32

    public init(x: Int32, y: Int32, width: Int32, height: Int32) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum ChartMath {
    /// Computes vertical bar rectangles within the given bounding box.
    /// Handles empty array, all-zero, negative values, count == 1, etc.
    public static func barRects(
        values: [Double],
        maxValue: Double? = nil,
        in bounds: (x: Int32, y: Int32, width: Int32, height: Int32),
        gap: Int32 = 2
    ) -> [ChartBarRect] {
        guard !values.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }
        let count = values.count
        let totalGaps = gap * Int32(max(0, count - 1))
        let availableWidth = max(0, bounds.width - totalGaps)
        let barWidth = max(1, availableWidth / Int32(count))

        let maxV: Double
        if let mv = maxValue, mv > 0 {
            maxV = mv
        } else {
            maxV = values.reduce(0.0) { max($0, $1) }
        }

        var rects: [ChartBarRect] = []
        rects.reserveCapacity(count)

        var curX = bounds.x
        for v in values {
            let clampedV = max(0, v)
            let ratio = maxV > 0 ? min(1.0, clampedV / maxV) : 0.0
            let h = Int32((Double(bounds.height) * ratio).rounded())
            let y = bounds.y + bounds.height - h
            rects.append(ChartBarRect(x: curX, y: y, width: barWidth, height: h))
            curX += barWidth + gap
        }
        return rects
    }

    /// Maps day (0..6, Monday = 0) and hour (0..23) to slot index (0..167).
    public static func heatmapIndex(day: Int, hour: Int) -> Int {
        let d = max(0, min(6, day))
        let h = max(0, min(23, hour))
        return d * 24 + h
    }

    /// Deconstructs a slot index (0..167) back to (day, hour).
    public static func heatmapDayHour(from index: Int) -> (day: Int, hour: Int) {
        let clamped = max(0, min(167, index))
        return (clamped / 24, clamped % 24)
    }
}
