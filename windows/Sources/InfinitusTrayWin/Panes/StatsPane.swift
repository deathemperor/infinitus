import Foundation
import InfinitusCore
import InfinitusWinUI
import WinSDK

public final class StatsPane: SettingsPane {
    public static var descriptor: PaneDescriptor {
        PaneDescriptor(
            id: "stats",
            title: "Stats",
            glyph: "\u{E9E9}",
            tintRGB: (108, 92, 231),
            keywords: ["stats", "metrics", "commits", "prs", "lines", "messages", "sessions", "week", "month", "year", "heatmap", "rhythm"]
        )
    }

    private var ctx: PaneContext?
    private var periodComboHwnd: HWND?
    private var refreshButtonHwnd: HWND?
    private var progressLabelHwnd: HWND?

    // Canvases for sections
    private var groupCanvasHwnds: [HWND] = []
    private var effortCanvasHwnd: HWND?
    private var heatmapCanvasHwnd: HWND?
    private var sessionCanvasHwnd: HWND?
    private var notesLabelHwnd: HWND?

    private var selectedPeriod: Stats.Period = .day
    private var computedHeight: Int32 = 1400
    private var isScanning = false

    // State
    private var allDays: [String: Stats.Day] = [:]
    private var currentSummary: Stats.Summary?
    private var cachedGroups: [Stats.Presentation.Group] = []
    private var scanNotes: [String] = []

    private var cacheURL: URL {
        WinSettingsStore.infinitusHome.appendingPathComponent("stats/transcripts.json")
    }

    public init() {
        let periodStr = WinSettingsStore.load().statsPeriod
        switch periodStr {
        case "week": selectedPeriod = .week
        case "month": selectedPeriod = .month
        case "year": selectedPeriod = .year
        default: selectedPeriod = .day
        }
    }

    public func attach(host: HWND, ctx: PaneContext) {
        self.ctx = ctx
        let base = ctx.idBase

        // Period picker: Today | This week | This month | This year
        let periods = Stats.Period.allCases.map(\.title)
        periodComboHwnd = PaneControls.combo(periods, in: ctx, id: base + 1, x: 0, y: 0, w: 0, h: 0)
        PaneControls.setComboSelection(periodComboHwnd, selectedPeriod.title)

        refreshButtonHwnd = PaneControls.button("Refresh", in: ctx, id: base + 2, x: 0, y: 0, w: 0, h: 0)
        progressLabelHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)

        // 6 Tile Group Canvases
        for i in 0..<6 {
            let hwnd = PaneControls.canvas(in: ctx, id: base + 10 + Int32(i), x: 0, y: 0, w: 0, h: 0)
            if let hwnd { groupCanvasHwnds.append(hwnd) }
        }

        // Effort canvas
        effortCanvasHwnd = PaneControls.canvas(in: ctx, id: base + 20, x: 0, y: 0, w: 0, h: 0)
        // Heatmap canvas
        heatmapCanvasHwnd = PaneControls.canvas(in: ctx, id: base + 21, x: 0, y: 0, w: 0, h: 0)
        // Session bucket canvas
        sessionCanvasHwnd = PaneControls.canvas(in: ctx, id: base + 22, x: 0, y: 0, w: 0, h: 0)

        notesLabelHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.faint)
    }

    public func layout(width: Int32, height: Int32) {
        guard let ctx else { return }
        ctx.recycleTransients()
        let m = ctx.metrics
        let pad = m.pad
        let contentW = max(100, width - pad * 2)

        var y = pad

        // Top bar
        let comboW = m.px(120)
        let btnW = m.px(80)
        let fieldH = m.fieldHeight + m.px(4)
        if let combo = periodComboHwnd {
            MoveWindow(combo, pad, y, comboW, fieldH + m.px(120), true)
        }
        if let btn = refreshButtonHwnd {
            MoveWindow(btn, pad + comboW + m.px(10), y, btnW, fieldH, true)
        }
        if let prog = progressLabelHwnd {
            let progX = pad + comboW + btnW + m.px(20)
            MoveWindow(prog, progX, y + m.px(2), contentW - progX, fieldH, true)
        }
        y += fieldH + m.sectionGap

        // Tile groups (up to 6)
        let cols = max(1, contentW / m.px(150))
        let tileH = m.px(74)

        for (idx, grp) in cachedGroups.enumerated() {
            guard idx < groupCanvasHwnds.count else { break }
            let canvas = groupCanvasHwnds[idx]
            y = PaneControls.sectionHeader(grp.id, in: ctx, y: y, width: width)

            let rows = Int32((grp.tiles.count + Int(cols) - 1) / Int(cols))
            let grpH = max(tileH, rows * (tileH + m.px(6)))
            MoveWindow(canvas, pad, y, contentW, grpH, true)
            y += grpH + m.sectionGap
        }

        // Section: Where the effort went
        y = PaneControls.sectionHeader("Where the effort went", in: ctx, y: y, width: width)
        let effortCount = max(2, (currentSummary?.total.activities.count ?? 0) + (currentSummary?.total.byModel.count ?? 0))
        let effortH = min(m.px(220), max(m.px(80), Int32(effortCount) * m.px(22)))
        if let ec = effortCanvasHwnd {
            MoveWindow(ec, pad, y, contentW, effortH, true)
        }
        y += effortH + m.sectionGap

        // Section: Rhythm
        y = PaneControls.sectionHeader("Rhythm — activity by hour", in: ctx, y: y, width: width)
        let heatH = m.px(130)
        if let hc = heatmapCanvasHwnd {
            MoveWindow(hc, pad, y, contentW, heatH, true)
        }
        y += heatH + m.px(8)

        let sessH = m.px(90)
        if let sc = sessionCanvasHwnd {
            MoveWindow(sc, pad, y, contentW, sessH, true)
        }
        y += sessH + m.sectionGap

        // Notes footer
        let notesText = scanNotes.joined(separator: " · ")
        let measuredH = PaneControls.helpText(notesText, in: ctx, x: pad, y: y, width: contentW)
        if let nl = notesLabelHwnd {
            MoveWindow(nl, pad, y, contentW, measuredH, true)
            PaneControls.setText(nl, notesText)
        }
        y += measuredH + m.sectionGap + pad

        computedHeight = y
        PaneHost.setContentHeight(ctx.host, computedHeight)
    }

    public func activate() {
        if allDays.isEmpty {
            startChunkScan()
        }
    }

    public func deactivate() {}

    public func command(id: Int32, code: UINT, from: HWND?) -> Bool {
        guard let ctx else { return false }
        let base = ctx.idBase
        if id == base + 1 && code == UINT(CBN_SELCHANGE) {
            let sel = PaneControls.comboSelection(periodComboHwnd)
            if sel.contains("week") { selectedPeriod = .week }
            else if sel.contains("month") { selectedPeriod = .month }
            else if sel.contains("year") { selectedPeriod = .year }
            else { selectedPeriod = .day }
            _ = try? WinSettingsStore.update { $0.statsPeriod = self.selectedPeriod.rawValue }
            recomputeSummary()
            return true
        } else if id == base + 2 {
            startChunkScan()
            return true
        }
        return false
    }

    public func notify(_ header: UnsafePointer<NMHDR>) -> Bool { false }

    public func drawItem(_ item: UnsafePointer<DRAWITEMSTRUCT>) -> Bool {
        guard let ctx else { return false }
        let dis = item.pointee
        let ctlID = Int32(dis.CtlID)
        let base = ctx.idBase

        // Check group canvases
        for i in 0..<groupCanvasHwnds.count {
            if ctlID == base + 10 + Int32(i) {
                if i < cachedGroups.count {
                    drawTileGroup(dis.hDC, rect: dis.rcItem, group: cachedGroups[i])
                }
                return true
            }
        }

        if ctlID == base + 20 {
            drawEffort(dis.hDC, rect: dis.rcItem)
            return true
        } else if ctlID == base + 21 {
            drawHeatmap(dis.hDC, rect: dis.rcItem)
            return true
        } else if ctlID == base + 22 {
            drawSessionBuckets(dis.hDC, rect: dis.rcItem)
            return true
        }
        return false
    }

    public func contentHeight(width: Int32) -> Int32 {
        computedHeight
    }

    // MARK: - Scanning chunk loop

    private func recomputeSummary() {
        guard !allDays.isEmpty else { return }
        let summary = Stats.fold(days: allDays, period: selectedPeriod, calendar: .current)
        self.currentSummary = summary
        self.cachedGroups = Stats.Presentation.groups(summary)

        if let host = ctx?.host {
            var rc = RECT()
            GetClientRect(host, &rc)
            layout(width: rc.right - rc.left, height: rc.bottom - rc.top)
            InvalidateRect(host, nil, true)
        }
    }

    private func startChunkScan() {
        guard !isScanning, let ctx else { return }
        isScanning = true
        PaneControls.setText(progressLabelHwnd, "scanning…")

        let cURL = cacheURL
        let period = selectedPeriod

        ctx.async { () -> ([String: Stats.Day], [String], Stats.Summary) in
            let projectsDir = TokenRateScanner.defaultProjectsDir()
            let calendar = Calendar.current
            let events = WinEventStore.load()
            let eventDays = StatsEvents.days(events, calendar: calendar)

            var chunkState = StatsChunkLoop.State()
            var currentTranscriptDays: [String: Stats.Day] = [:]
            var scanCwds: Set<String> = []
            var remaining = 1
            var notes: [String] = []

            while remaining > 0 {
                let res = StatsScanner.scan(
                    projectsDir: projectsDir,
                    cacheURL: cURL,
                    calendar: calendar,
                    byteBudget: StatsChunkLoop.defaultChunkByteBudget
                )
                remaining = res.remaining
                currentTranscriptDays = res.days
                scanCwds.formUnion(res.cwds)

                let stepInput = StatsChunkLoop.StepInput(
                    remainingFiles: res.remaining,
                    bytesTotal: res.bytesTotal,
                    bytesRemaining: res.bytesRemaining
                )
                let (_, stop) = chunkState.step(input: stepInput)
                if stop { break }
            }

            notes.append("\(currentTranscriptDays.count) active days")
            if let firstEvent = events.first {
                notes.append("switches & limits since \(firstEvent.at.formatted(date: .abbreviated, time: .omitted))")
            }

            // Merge transcript days + event days
            var merged = currentTranscriptDays
            for (k, d) in eventDays {
                merged[k] = (merged[k] ?? Stats.Day()) + d
            }

            // Repo scan in background
            let repoOutcome = WinRepoStatsScanner.scan(cwds: scanCwds, since: Date().addingTimeInterval(-365 * 86400))
            for (k, d) in repoOutcome.days {
                merged[k] = (merged[k] ?? Stats.Day()) + d
            }
            notes.append(contentsOf: repoOutcome.notes)

            let summary = Stats.fold(days: merged, period: period, calendar: calendar)
            return (merged, notes, summary)
        } then: { [weak self] (merged, notes, summary) in
            guard let self else { return }
            self.isScanning = false
            self.allDays = merged
            self.scanNotes = notes
            self.currentSummary = summary
            self.cachedGroups = Stats.Presentation.groups(summary)
            PaneControls.setText(self.progressLabelHwnd, "All transcripts scanned.")

            if let host = self.ctx?.host {
                var rc = RECT()
                GetClientRect(host, &rc)
                self.layout(width: rc.right - rc.left, height: rc.bottom - rc.top)
                InvalidateRect(host, nil, true)
            }
        }
    }

    // MARK: - Painting

    private func drawTileGroup(_ dc: HDC, rect: RECT, group: Stats.Presentation.Group) {
        guard let ctx else { return }
        if let bg = WinDark.backgroundBrush {
            var r = rect
            FillRect(dc, &r, bg)
        }

        let m = ctx.metrics
        let width = rect.right - rect.left
        let cols = max(1, width / m.px(150))
        let gap = m.px(6)
        let tileW = (width - gap * (cols - 1)) / cols
        let tileH = m.px(74)

        for (idx, tile) in group.tiles.enumerated() {
            let col = Int32(idx % Int(cols))
            let row = Int32(idx / Int(cols))

            let tx = rect.left + col * (tileW + gap)
            let ty = rect.top + row * (tileH + gap)
            var tr = RECT(left: tx, top: ty, right: tx + tileW, bottom: ty + tileH)

            // Tile background & frame
            if let tileBrush = CreateSolidBrush(WinDark.rgb(36, 36, 42)) {
                FillRect(dc, &tr, tileBrush)
                DeleteObject(tileBrush)
            }
            if let framePen = CreatePen(PS_SOLID, 1, WinDark.separator) {
                let oldP = SelectObject(dc, framePen)
                let oldB = SelectObject(dc, GetStockObject(NULL_BRUSH))
                Rectangle(dc, tr.left, tr.top, tr.right, tr.bottom)
                SelectObject(dc, oldB)
                SelectObject(dc, oldP)
                DeleteObject(framePen)
            }

            // Top: title
            let oldFont = ctx.captionFont.map { SelectObject(dc, $0) }
            SetBkMode(dc, TRANSPARENT)
            SetTextColor(dc, WinDark.dim)
            var titleRc = RECT(left: tx + m.px(8), top: ty + m.px(6), right: tx + tileW - m.px(8), bottom: ty + m.px(20))
            var titleWide = Array(tile.id.utf16) + [0]
            _ = DrawTextW(dc, &titleWide, Int32(tile.id.utf16.count), &titleRc,
                          UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))

            // Middle: value + delta
            _ = ctx.boldFont.map { SelectObject(dc, $0) }
            SetTextColor(dc, WinDark.text)
            var valRc = RECT(left: tx + m.px(8), top: ty + m.px(22), right: tx + tileW - m.px(8), bottom: ty + m.px(42))
            var valWide = Array(tile.value.utf16) + [0]
            _ = DrawTextW(dc, &valWide, Int32(tile.value.utf16.count), &valRc,
                          UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))

            if let delta = tile.delta {
                _ = ctx.captionFont.map { SelectObject(dc, $0) }
                let isPos = delta.hasPrefix("+")
                let isNeg = delta.hasPrefix("−") || delta.hasPrefix("-")
                SetTextColor(dc, isPos ? WinDark.rgb(46, 204, 113) : (isNeg ? WinDark.rgb(230, 126, 34) : WinDark.dim))
                var dRc = RECT(left: tx + m.px(8), top: ty + m.px(22), right: tx + tileW - m.px(8), bottom: ty + m.px(42))
                var dWide = Array(delta.utf16) + [0]
                _ = DrawTextW(dc, &dWide, Int32(delta.utf16.count), &dRc,
                              UINT(DT_RIGHT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))
            }

            // Bottom: sparkline
            var sparkRc = RECT(left: tx + m.px(8), top: ty + m.px(46), right: tx + tileW - m.px(8), bottom: ty + tileH - m.px(6))
            GDIChart.spark(dc, sparkRc, values: tile.series, color: WinDark.rgb(108, 92, 231))

            if let oldFont { SelectObject(dc, oldFont) }
        }
    }

    private func drawEffort(_ dc: HDC, rect: RECT) {
        guard let ctx else { return }
        if let bg = WinDark.backgroundBrush {
            var r = rect
            FillRect(dc, &r, bg)
        }
        guard let summary = currentSummary else { return }

        var rows: [(label: String, value: Double)] = []
        for (actName, tally) in summary.total.activities.sorted(by: { $0.value.usd > $1.value.usd }) {
            let label = Stats.Activity(rawValue: actName)?.title ?? actName
            rows.append((label, tally.usd))
        }
        for (modelName, tally) in summary.total.byModel.sorted(by: { $0.value.usd > $1.value.usd }) {
            rows.append((modelName, tally.usd))
        }

        GDIChart.hbars(
            dc, rect,
            rows: rows,
            color: WinDark.rgb(108, 92, 231),
            metrics: ctx.metrics,
            font: ctx.captionFont
        )
    }

    private func drawHeatmap(_ dc: HDC, rect: RECT) {
        guard let ctx else { return }
        if let bg = WinDark.backgroundBrush {
            var r = rect
            FillRect(dc, &r, bg)
        }
        guard let summary = currentSummary else { return }

        GDIChart.heatmap(
            dc, rect,
            values: summary.total.hours,
            base: WinDark.rgb(108, 92, 231),
            metrics: ctx.metrics,
            font: ctx.captionFont
        )
    }

    private func drawSessionBuckets(_ dc: HDC, rect: RECT) {
        guard let ctx else { return }
        if let bg = WinDark.backgroundBrush {
            var r = rect
            FillRect(dc, &r, bg)
        }
        guard let summary = currentSummary else { return }

        let values = summary.total.sessionBuckets.map(Double.init)
        let labels = ["< 15 min", "15–60 min", "1–4 h", "> 4 h"]

        GDIChart.bars(
            dc, rect,
            values: values,
            color: WinDark.rgb(108, 92, 231),
            labels: labels,
            metrics: ctx.metrics,
            font: ctx.captionFont
        )
    }
}
