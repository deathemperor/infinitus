import Foundation
import InfinitusCore
import InfinitusWinUI
import WinSDK

public enum GDIChart {
    /// Vertical bars, one per value, left to right.
    /// Used by: daily spend, session-length buckets, the 5h start-hour rhythm.
    public static func bars(
        _ dc: HDC, _ rect: RECT, values: [Double],
        color: COLORREF, labels: [String]? = nil,
        metrics: Metrics, font: HFONT?
    ) {
        let width = rect.right - rect.left
        let height = rect.bottom - rect.top
        guard width > 0, height > 0 else { return }

        let labelHeight = labels != nil ? metrics.px(16) : 0
        let chartH = max(1, height - labelHeight - metrics.px(4))
        let chartBounds = (x: rect.left, y: rect.top, width: width, height: chartH)

        let barRects = ChartMath.barRects(values: values, in: chartBounds, gap: metrics.px(3))

        // Draw baseline axis line
        let baselineY = rect.top + chartH
        if let axisPen = CreatePen(PS_SOLID, 1, WinDark.separator) {
            let oldPen = SelectObject(dc, axisPen)
            MoveToEx(dc, rect.left, baselineY, nil)
            LineTo(dc, rect.right, baselineY)
            SelectObject(dc, oldPen)
            DeleteObject(axisPen)
        }

        guard !barRects.isEmpty else {
            // Empty state
            drawEmptyText(dc, rect: rect, font: font)
            return
        }

        // Draw bars
        if let brush = CreateSolidBrush(color) {
            for b in barRects {
                if b.height > 0 {
                    var r = RECT(left: b.x, top: b.y, right: b.x + b.width, bottom: b.y + b.height)
                    FillRect(dc, &r, brush)
                }
            }
            DeleteObject(brush)
        }

        // Draw labels below bars
        if let labels, !labels.isEmpty {
            let oldFont = font.map { SelectObject(dc, $0) }
            SetBkMode(dc, TRANSPARENT)
            SetTextColor(dc, WinDark.faint)

            let labelY = baselineY + metrics.px(2)
            let step = max(1, values.count / 8) // Thin out labels if too many
            for (idx, b) in barRects.enumerated() {
                guard idx < labels.count, (idx % step == 0 || idx == barRects.count - 1) else { continue }
                let text = labels[idx]
                var wide = Array(text.utf16) + [0]
                var lr = RECT(
                    left: max(rect.left, b.x - metrics.px(10)),
                    top: labelY,
                    right: min(rect.right, b.x + b.width + metrics.px(10)),
                    bottom: rect.bottom
                )
                _ = DrawTextW(dc, &wide, Int32(text.utf16.count), &lr,
                              UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))
            }
            if let oldFont { SelectObject(dc, oldFont) }
        }
    }

    /// Horizontal bars with a leading label column.
    /// Used by: spend by model, activity/model effort tables.
    public static func hbars(
        _ dc: HDC, _ rect: RECT, rows: [(label: String, value: Double)],
        color: COLORREF, metrics: Metrics, font: HFONT?
    ) {
        let width = rect.right - rect.left
        let height = rect.bottom - rect.top
        guard width > 0, height > 0 else { return }
        guard !rows.isEmpty else {
            drawEmptyText(dc, rect: rect, font: font)
            return
        }

        let maxVal = rows.reduce(0.0) { max($0, $1.value) }
        let rowH = max(metrics.px(18), height / Int32(rows.count))
        let labelW = min(metrics.px(120), width / 3)
        let valueW = metrics.px(60)
        let barMaxW = max(1, width - labelW - valueW - metrics.px(16))

        let oldFont = font.map { SelectObject(dc, $0) }
        SetBkMode(dc, TRANSPARENT)

        let barBrush = CreateSolidBrush(color)

        var curY = rect.top
        for row in rows {
            if curY + rowH > rect.bottom { break }

            // Label text
            SetTextColor(dc, WinDark.dim)
            var labelRc = RECT(left: rect.left, top: curY, right: rect.left + labelW, bottom: curY + rowH)
            var labelWide = Array(row.label.utf16) + [0]
            _ = DrawTextW(dc, &labelWide, Int32(row.label.utf16.count), &labelRc,
                          UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX))

            // Bar
            let ratio = maxVal > 0 ? min(1.0, max(0.0, row.value) / maxVal) : 0.0
            let barW = Int32((Double(barMaxW) * ratio).rounded())
            let barH = max(metrics.px(6), rowH - metrics.px(8))
            let barY = curY + (rowH - barH) / 2
            let barX = rect.left + labelW + metrics.px(8)

            if barW > 0, let brush = barBrush {
                var barRc = RECT(left: barX, top: barY, right: barX + barW, bottom: barY + barH)
                FillRect(dc, &barRc, brush)
            }

            // Value text
            SetTextColor(dc, WinDark.text)
            let valStr = String(format: "$%.2f", row.value)
            var valRc = RECT(left: rect.right - valueW, top: curY, right: rect.right, bottom: curY + rowH)
            var valWide = Array(valStr.utf16) + [0]
            _ = DrawTextW(dc, &valWide, Int32(valStr.utf16.count), &valRc,
                          UINT(DT_RIGHT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))

            curY += rowH
        }

        if let barBrush { DeleteObject(barBrush) }
        if let oldFont { SelectObject(dc, oldFont) }
    }

    /// One or more polylines over a shared x axis, y clamped 0…yMax.
    /// Used by: utilization over time.
    public static func lines(
        _ dc: HDC, _ rect: RECT,
        series: [(name: String, color: COLORREF, points: [(x: Double, y: Double)])],
        yMax: Double, metrics: Metrics, font: HFONT?
    ) {
        let width = rect.right - rect.left
        let height = rect.bottom - rect.top
        guard width > 0, height > 0 else { return }

        let activeSeries = series.filter { !$0.points.isEmpty }
        guard !activeSeries.isEmpty, yMax > 0 else {
            drawEmptyText(dc, rect: rect, font: font)
            return
        }

        let labelW = metrics.px(36)
        let chartX = rect.left + labelW
        let chartW = max(1, width - labelW - metrics.px(8))
        let chartY = rect.top + metrics.px(4)
        let chartH = max(1, height - metrics.px(24))

        // Grid lines (0%, 50%, 100%)
        let oldFont = font.map { SelectObject(dc, $0) }
        SetBkMode(dc, TRANSPARENT)
        SetTextColor(dc, WinDark.faint)

        let gridSteps = [1.0, 0.5, 0.0]
        let gridLabels = ["100%", "50%", "0%"]
        if let gridPen = CreatePen(PS_SOLID, 1, WinDark.separator) {
            let oldPen = SelectObject(dc, gridPen)
            for (step, label) in zip(gridSteps, gridLabels) {
                let y = chartY + Int32((Double(chartH) * (1.0 - step)).rounded())
                MoveToEx(dc, chartX, y, nil)
                LineTo(dc, chartX + chartW, y)

                var lRc = RECT(left: rect.left, top: y - metrics.px(8), right: chartX - metrics.px(4), bottom: y + metrics.px(8))
                var wide = Array(label.utf16) + [0]
                _ = DrawTextW(dc, &wide, Int32(label.utf16.count), &lRc,
                              UINT(DT_RIGHT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))
            }
            SelectObject(dc, oldPen)
            DeleteObject(gridPen)
        }

        // Determine min/max X across all series
        var minX = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        for s in activeSeries {
            for pt in s.points {
                if pt.x < minX { minX = pt.x }
                if pt.x > maxX { maxX = pt.x }
            }
        }
        let xRange = max(1.0, maxX - minX)

        // Draw each series polyline
        for s in activeSeries {
            guard s.points.count >= 2 else { continue }
            if let pen = CreatePen(PS_SOLID, metrics.px(2), s.color) {
                let oldPen = SelectObject(dc, pen)

                var winPoints: [POINT] = []
                winPoints.reserveCapacity(s.points.count)
                for pt in s.points {
                    let rx = (pt.x - minX) / xRange
                    let ry = min(1.0, max(0.0, pt.y / yMax))
                    let px = chartX + Int32((Double(chartW) * rx).rounded())
                    let py = chartY + chartH - Int32((Double(chartH) * ry).rounded())
                    winPoints.append(POINT(x: px, y: py))
                }

                Polyline(dc, winPoints, Int32(winPoints.count))
                SelectObject(dc, oldPen)
                DeleteObject(pen)
            }
        }

        if let oldFont { SelectObject(dc, oldFont) }
    }

    /// A 7×24 intensity grid. Used by: the Stats hour heatmap.
    public static func heatmap(
        _ dc: HDC, _ rect: RECT, values: [Int],
        base: COLORREF, metrics: Metrics, font: HFONT?
    ) {
        let width = rect.right - rect.left
        let height = rect.bottom - rect.top
        guard width > 0, height > 0 else { return }

        let dayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let labelW = metrics.px(30)
        let gridX = rect.left + labelW
        let gridW = max(1, width - labelW - metrics.px(4))
        let gridH = max(1, height - metrics.px(4))

        let cellW = max(1, gridW / 24)
        let cellH = max(1, gridH / 7)

        let maxVal = max(1, values.reduce(0) { max($0, $1) })

        let oldFont = font.map { SelectObject(dc, $0) }
        SetBkMode(dc, TRANSPARENT)
        SetTextColor(dc, WinDark.faint)

        let baseR = Double(base & 0xFF)
        let baseG = Double((base >> 8) & 0xFF)
        let baseB = Double((base >> 16) & 0xFF)

        // Draw day labels and grid cells
        for day in 0..<7 {
            let y = rect.top + Int32(day) * cellH

            // Day label
            var lRc = RECT(left: rect.left, top: y, right: gridX - metrics.px(4), bottom: y + cellH)
            var lWide = Array(dayLabels[day].utf16) + [0]
            _ = DrawTextW(dc, &lWide, Int32(dayLabels[day].utf16.count), &lRc,
                          UINT(DT_RIGHT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))

            for hour in 0..<24 {
                let idx = ChartMath.heatmapIndex(day: day, hour: hour)
                let val = idx < values.count ? values[idx] : 0
                let x = gridX + Int32(hour) * cellW

                let cellColor: COLORREF
                if val <= 0 {
                    cellColor = WinDark.rgb(32, 32, 38)
                } else {
                    let intensity = min(1.0, max(0.2, Double(val) / Double(maxVal)))
                    let r = Int(baseR * intensity)
                    let g = Int(baseG * intensity)
                    let b = Int(baseB * intensity)
                    cellColor = WinDark.rgb(r, g, b)
                }

                if let brush = CreateSolidBrush(cellColor) {
                    var cRc = RECT(left: x + 1, top: y + 1, right: x + cellW - 1, bottom: y + cellH - 1)
                    FillRect(dc, &cRc, brush)
                    DeleteObject(brush)
                }
            }
        }

        if let oldFont { SelectObject(dc, oldFont) }
    }

    /// A flat sparkline for a stat tile — no axes, no labels.
    public static func spark(_ dc: HDC, _ rect: RECT, values: [Double], color: COLORREF) {
        let width = rect.right - rect.left
        let height = rect.bottom - rect.top
        guard width > 4, height > 4, values.count >= 2 else { return }

        let maxV = values.reduce(0.0) { max($0, $1) }
        guard maxV > 0 else { return }

        var points: [POINT] = []
        points.reserveCapacity(values.count)

        let stepX = Double(width) / Double(values.count - 1)
        for (i, v) in values.enumerated() {
            let px = rect.left + Int32((Double(i) * stepX).rounded())
            let ratio = min(1.0, max(0.0, v / maxV))
            let py = rect.bottom - Int32((Double(height) * ratio).rounded())
            points.append(POINT(x: px, y: py))
        }

        if let pen = CreatePen(PS_SOLID, 1, color) {
            let oldPen = SelectObject(dc, pen)
            Polyline(dc, points, Int32(points.count))
            SelectObject(dc, oldPen)
            DeleteObject(pen)
        }
    }

    private static func drawEmptyText(_ dc: HDC, rect: RECT, font: HFONT?) {
        let oldFont = font.map { SelectObject(dc, $0) }
        SetBkMode(dc, TRANSPARENT)
        SetTextColor(dc, WinDark.faint)
        var rc = rect
        var textWide = Array("No data".utf16) + [0]
        _ = DrawTextW(dc, &textWide, Int32("No data".utf16.count), &rc,
                      UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))
        if let oldFont { SelectObject(dc, oldFont) }
    }
}
