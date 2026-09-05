import Foundation
import InfinitusCore
import InfinitusWinUI
import WinSDK

public final class UtilizationPane: SettingsPane {
    public static var descriptor: PaneDescriptor {
        PaneDescriptor(
            id: "utilization",
            title: "Utilization",
            glyph: "\u{E9D9}",
            tintRGB: (80, 210, 180),
            keywords: ["history", "utilization", "waste", "window", "5h", "7d", "weekly", "chart", "over time", "run rate", "tokens", "forecast"]
        )
    }

    private var ctx: PaneContext?
    private var rangeComboHwnd: HWND?
    private var refreshButtonHwnd: HWND?
    private var statusLabelHwnd: HWND?

    private var utilChartCanvasHwnd: HWND?
    private var fiveHourChartCanvasHwnd: HWND?

    private var dynamicLabels: [HWND] = []

    private var rangeDays: Int = 7
    private var isLoading = false
    private var computedHeight: Int32 = 900

    // Loaded data
    private var samples: [UsageSample] = []
    private var rates: TokenRates?
    private var plan: WindowPlanner.Plan?
    private var replay: WindowPlanner.ReplayReport?
    private var fiveHourWindows: [FiveHourWindow] = []
    private var wasteGenerations: [WindowGeneration] = []

    private var ratesCacheURL: URL {
        WinSettingsStore.infinitusHome.appendingPathComponent("token-rates-cache.json")
    }

    public init() {
        rangeDays = WinSettingsStore.load().utilizationDays
        if rangeDays != 1 && rangeDays != 7 && rangeDays != 30 {
            rangeDays = 7
        }
    }

    public func attach(host: HWND, ctx: PaneContext) {
        self.ctx = ctx
        let base = ctx.idBase

        // Range combo (24 hours, 7 days, 30 days)
        let comboItems = ["24 hours", "7 days", "30 days"]
        rangeComboHwnd = PaneControls.combo(comboItems, in: ctx, id: base + 1, x: 0, y: 0, w: 0, h: 0)
        let selStr = rangeDays == 1 ? "24 hours" : "\(rangeDays) days"
        PaneControls.setComboSelection(rangeComboHwnd, selStr)

        refreshButtonHwnd = PaneControls.button("Refresh", in: ctx, id: base + 2, x: 0, y: 0, w: 0, h: 0)
        statusLabelHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)

        utilChartCanvasHwnd = PaneControls.canvas(in: ctx, id: base + 10, x: 0, y: 0, w: 0, h: 0)
        fiveHourChartCanvasHwnd = PaneControls.canvas(in: ctx, id: base + 11, x: 0, y: 0, w: 0, h: 0)
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
        if let combo = rangeComboHwnd {
            MoveWindow(combo, pad, y, comboW, fieldH + m.px(100), true)
        }
        if let btn = refreshButtonHwnd {
            MoveWindow(btn, pad + comboW + m.px(10), y, btnW, fieldH, true)
        }
        if let status = statusLabelHwnd {
            let statusX = pad + comboW + btnW + m.px(20)
            MoveWindow(status, statusX, y + m.px(2), contentW - statusX, fieldH, true)
        }
        y += fieldH + m.sectionGap

        // Clear dynamic labels
        for lbl in dynamicLabels {
            DestroyWindow(lbl)
        }
        dynamicLabels.removeAll()

        // 1. Forecast section
        y = PaneControls.sectionHeader("Forecast — every account at its own pace", in: ctx, y: y, width: width)
        let now = Date().timeIntervalSince1970
        let recentSamples = samples.filter { $0.t >= now - 3600 }
        if recentSamples.isEmpty {
            if let l = PaneControls.label("No recent usage samples to forecast.", in: ctx, x: pad + m.px(4), y: y, w: contentW, h: m.px(18), caption: true, color: WinDark.dim) {
                dynamicLabels.append(l)
            }
            y += m.px(22)
        } else {
            var latestByEmail: [String: UsageSample] = [:]
            for s in recentSamples {
                if let cur = latestByEmail[s.email], cur.t >= s.t { continue }
                latestByEmail[s.email] = s
            }
            for (_, sample) in latestByEmail.sorted(by: { $0.key < $1.key }) {
                let name = sample.email.split(separator: "@").first.map(String.init) ?? sample.email
                let isActive = sample.active == true
                let headerText = "\(name)\(isActive ? "  (active)" : "")"
                if let l = PaneControls.label(headerText, in: ctx, x: pad + m.px(4), y: y, w: contentW, h: m.px(18), bold: true) {
                    dynamicLabels.append(l)
                }
                y += m.px(18)

                if let five = sample.fiveHour {
                    let rate = WindowTelemetry.burnRate(samples, email: sample.email, now: now)
                    let rateStr = (rate != nil && rate! > 0) ? String(format: "+%.0f%%/h", rate!) : "pace unknown"
                    let line = "   5h: \(Int(five.pct.rounded()))%   \(rateStr)"
                    if let l = PaneControls.label(line, in: ctx, x: pad + m.px(4), y: y, w: contentW, h: m.px(16), caption: true, color: WinDark.text) {
                        dynamicLabels.append(l)
                    }
                    y += m.px(16)
                }
                if let seven = sample.sevenDay {
                    let line = "   7d: \(Int(seven.pct.rounded()))%"
                    if let l = PaneControls.label(line, in: ctx, x: pad + m.px(4), y: y, w: contentW, h: m.px(16), caption: true, color: WinDark.text) {
                        dynamicLabels.append(l)
                    }
                    y += m.px(16)
                }
                y += m.px(4)
            }
        }
        let forecastFootnote = "Estimate. 5h pace measured over the last hour, weekly and per-model paces over the last 24 hours."
        let fNoteH = PaneControls.helpText(forecastFootnote, in: ctx, x: pad, y: y, width: contentW)
        y += fNoteH + m.sectionGap

        // 2. Fleet section
        y = PaneControls.sectionHeader("Fleet", in: ctx, y: y, width: width)
        let drainOrder = plan?.steps.compactMap { s -> String? in
            if case .switchTo(let n) = s.action { return "#\(n)" }
            return nil
        }.joined(separator: " → ") ?? "—"
        let fleetText = "Drain order: \(drainOrder.isEmpty ? "—" : drainOrder)"
        if let l = PaneControls.label(fleetText, in: ctx, x: pad + m.px(4), y: y, w: contentW, h: m.px(18)) {
            dynamicLabels.append(l)
        }
        y += m.px(22) + m.sectionGap

        // 3. Run rate section
        y = PaneControls.sectionHeader("Run rate", in: ctx, y: y, width: width)
        if let r = rates {
            func addRateRow(_ label: String, _ t: TokenRates.Totals, divide: Double) {
                let tokStr = TokenFormat.compact(Int((Double(t.tokens) / divide).rounded()))
                let usdStr = String(format: "$%.2f", t.usd / divide)
                let turnsStr = divide == 1 ? "\(t.messages)" : String(format: "%.1f", Double(t.messages) / divide)
                let line = "\(label):  Tokens \(tokStr)  ·  API-equiv \(usdStr)  ·  Turns \(turnsStr)"
                if let l = PaneControls.label(line, in: ctx, x: pad + m.px(4), y: y, w: contentW, h: m.px(18)) {
                    dynamicLabels.append(l)
                }
                y += m.px(18)
            }
            addRateRow("per minute", r.lastHour, divide: 60)
            addRateRow("per hour", r.lastHour, divide: 1)
            addRateRow("per day", r.lastDay, divide: 1)
            addRateRow("per week", r.lastWeek, divide: 1)
        } else {
            if let l = PaneControls.label("Scanning transcripts for run rate…", in: ctx, x: pad + m.px(4), y: y, w: contentW, h: m.px(18), caption: true, color: WinDark.dim) {
                dynamicLabels.append(l)
            }
            y += m.px(20)
        }
        let rateFootnote = "Read off Claude Code's own transcripts: per minute and per hour from the last 60 minutes, per day from the last 24 hours, per week from the last 7 days. One turn counted once; dollars are what the same tokens would cost at API list prices — an estimate, not a bill."
        let rNoteH = PaneControls.helpText(rateFootnote, in: ctx, x: pad, y: y, width: contentW)
        y += rNoteH + m.sectionGap

        // 4. Utilization over time line chart
        y = PaneControls.sectionHeader("Utilization over time", in: ctx, y: y, width: width)
        let chartH = m.px(120)
        if let utilC = utilChartCanvasHwnd {
            MoveWindow(utilC, pad, y, contentW, chartH, true)
        }
        y += chartH + m.px(4)
        let chartFootnote = "One point per engine usage poll, thinned for the range. Gaps are hours this PC (or its engine) wasn't running."
        let cNoteH = PaneControls.helpText(chartFootnote, in: ctx, x: pad, y: y, width: contentW)
        y += cNoteH + m.sectionGap

        // 5. 5h windows rhythm
        y = PaneControls.sectionHeader("5h windows & rhythm", in: ctx, y: y, width: width)
        let fiveHCount = fiveHourWindows.count
        let meanPeak = fiveHCount > 0 ? Int((fiveHourWindows.reduce(0.0) { $0 + $1.peakPct } / Double(fiveHCount)).rounded()) : 0
        let unusedCount = fiveHourWindows.filter { $0.peakPct < 10 }.count
        let winSummary = "\(fiveHCount) windows · mean peak \(meanPeak)% · \(unusedCount) unused"
        if let l = PaneControls.label(winSummary, in: ctx, x: pad + m.px(4), y: y, w: contentW, h: m.px(18)) {
            dynamicLabels.append(l)
        }
        y += m.px(20)
        let barH = m.px(90)
        if let fiveC = fiveHourChartCanvasHwnd {
            MoveWindow(fiveC, pad, y, contentW, barH, true)
        }
        y += barH + m.sectionGap

        // 6. Waste at weekly resets
        y = PaneControls.sectionHeader("Waste at weekly resets", in: ctx, y: y, width: width)
        if wasteGenerations.isEmpty {
            if let l = PaneControls.label("No weekly resets observed yet.", in: ctx, x: pad + m.px(4), y: y, w: contentW, h: m.px(18), caption: true, color: WinDark.dim) {
                dynamicLabels.append(l)
            }
            y += m.px(20)
        } else {
            var byEmail: [String: [WindowGeneration]] = [:]
            for g in wasteGenerations { byEmail[g.email, default: []].append(g) }
            for (email, gens) in byEmail {
                let name = email.split(separator: "@").first.map(String.init) ?? email
                let avgWaste = Int((gens.reduce(0.0) { $0 + $1.wastePct } / Double(gens.count)).rounded())
                let worstWaste = Int((gens.map(\.wastePct).max() ?? 0).rounded())
                let line = "\(name):  \(avgWaste)% wasted avg  ·  \(gens.count) resets observed  ·  worst \(worstWaste)%"
                if let l = PaneControls.label(line, in: ctx, x: pad + m.px(4), y: y, w: contentW, h: m.px(18)) {
                    dynamicLabels.append(l)
                }
                y += m.px(18)
            }
        }
        let wasteFootnote = "Waste = headroom still unused when a 7-day window rolled over. Headroom is lost forever at the reset."
        let wNoteH = PaneControls.helpText(wasteFootnote, in: ctx, x: pad, y: y, width: contentW)
        y += wNoteH + m.sectionGap + pad

        computedHeight = y
        PaneHost.setContentHeight(ctx.host, computedHeight)
    }

    public func activate() {
        if samples.isEmpty {
            refresh()
        }
    }

    public func deactivate() {}

    public func command(id: Int32, code: UINT, from: HWND?) -> Bool {
        guard let ctx else { return false }
        let base = ctx.idBase
        if id == base + 1 && code == UINT(CBN_SELCHANGE) {
            let sel = PaneControls.comboSelection(rangeComboHwnd)
            if sel.contains("24") { rangeDays = 1 }
            else if sel.contains("30") { rangeDays = 30 }
            else { rangeDays = 7 }
            _ = try? WinSettingsStore.update { $0.utilizationDays = self.rangeDays }
            refresh()
            return true
        } else if id == base + 2 {
            refresh()
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

        if ctlID == base + 10 {
            drawUtilizationChart(dis.hDC, rect: dis.rcItem)
            return true
        } else if ctlID == base + 11 {
            drawFiveHourChart(dis.hDC, rect: dis.rcItem)
            return true
        }
        return false
    }

    public func contentHeight(width: Int32) -> Int32 {
        computedHeight
    }

    // MARK: - Scanning & Painting

    private func refresh() {
        guard !isLoading, let ctx else { return }
        isLoading = true
        PaneControls.setText(statusLabelHwnd, "scanning…")

        let days = rangeDays
        let rCache = ratesCacheURL

        ctx.async { () -> ([UsageSample], TokenRates?, WindowPlanner.Plan?, WindowPlanner.ReplayReport?, [FiveHourWindow], [WindowGeneration]) in
            let urls = WinUsageHistoryRecorder.readableURLs()
            let all = urls.map { UsageHistory.load(url: $0) }
            let merged = UsageHistory.merge(all)

            let now = Date().timeIntervalSince1970
            let cutoff = now - Double(days * 86_400)
            let filtered = merged.filter { $0.t >= cutoff }

            let plan = UtilizationModelHelper.dryRunPlan(filtered, now: now)
            let replay = WindowPlanner.replay(filtered, from: cutoff, to: now)
            let fiveH = WindowTelemetry.fiveHourWindows(filtered, now: now)
            let waste = WasteMath.generations(filtered)

            let rates = TokenRateScanner.scan(
                projectsDir: TokenRateScanner.defaultProjectsDir(),
                cacheURL: rCache,
                now: now
            )

            return (filtered, rates, plan, replay, fiveH, waste)
        } then: { [weak self] (samples, rates, plan, replay, fiveH, waste) in
            guard let self else { return }
            self.isLoading = false
            self.samples = samples
            self.rates = rates
            self.plan = plan
            self.replay = replay
            self.fiveHourWindows = fiveH
            self.wasteGenerations = waste
            PaneControls.setText(self.statusLabelHwnd, "")

            if let host = self.ctx?.host {
                var rc = RECT()
                GetClientRect(host, &rc)
                self.layout(width: rc.right - rc.left, height: rc.bottom - rc.top)
                InvalidateRect(host, nil, true)
            }
        }
    }

    private func drawUtilizationChart(_ dc: HDC, rect: RECT) {
        guard let ctx else { return }
        if let bg = WinDark.backgroundBrush {
            var r = rect
            FillRect(dc, &r, bg)
        }

        guard !samples.isEmpty else { return }

        // Group samples by email
        var byEmail: [String: [UsageSample]] = [:]
        for s in samples { byEmail[s.email, default: []].append(s) }

        let palette: [COLORREF] = [
            WinDark.rgb(80, 210, 180),
            WinDark.rgb(52, 152, 219),
            WinDark.rgb(155, 89, 182),
            WinDark.rgb(230, 126, 34),
            WinDark.rgb(231, 76, 60)
        ]

        var series: [(name: String, color: COLORREF, points: [(x: Double, y: Double)])] = []
        for (idx, (email, accSamples)) in byEmail.enumerated() {
            let color = palette[idx % palette.count]
            let name = email.split(separator: "@").first.map(String.init) ?? email
            let points = accSamples.sorted(by: { $0.t < $1.t }).map { s in
                (x: s.t, y: s.fiveHour?.pct ?? s.sevenDay?.pct ?? 0.0)
            }
            series.append((name: name, color: color, points: points))
        }

        GDIChart.lines(
            dc, rect,
            series: series,
            yMax: 100.0,
            metrics: ctx.metrics,
            font: ctx.captionFont
        )
    }

    private func drawFiveHourChart(_ dc: HDC, rect: RECT) {
        guard let ctx else { return }
        if let bg = WinDark.backgroundBrush {
            var r = rect
            FillRect(dc, &r, bg)
        }

        let rhythm = WindowTelemetry.dailyRhythm(fiveHourWindows)
        var values = [Double](repeating: 0.0, count: 24)
        for h in 0..<24 {
            values[h] = Double(rhythm[h] ?? 0)
        }
        let labels = (0..<24).map { h in h % 4 == 0 ? "\(h)h" : "" }

        GDIChart.bars(
            dc, rect,
            values: values,
            color: WinDark.rgb(80, 210, 180),
            labels: labels,
            metrics: ctx.metrics,
            font: ctx.captionFont
        )
    }
}

public enum UtilizationModelHelper {
    public static func dryRunPlan(_ samples: [UsageSample], now: Double) -> WindowPlanner.Plan? {
        var latest: [String: UsageSample] = [:]
        for s in samples where s.t >= now - 3600 {
            if let cur = latest[s.email], cur.t >= s.t { continue }
            latest[s.email] = s
        }
        let states = latest.values.map { s in
            let weekly = ([s.sevenDay?.pct] + (s.scoped ?? [:]).values.map { $0.pct })
                .compactMap { $0 }.max() ?? 0
            return WindowPlanner.AccountState(
                number: s.number, email: s.email, active: s.active == true,
                fiveHourPct: s.fiveHour?.pct, fiveHourResetsAt: s.fiveHour?.resetsAt,
                weeklyPct: weekly
            )
        }
        guard let active = states.first(where: { $0.active }) else { return nil }
        let rate = WindowTelemetry.burnRate(samples, email: active.email, now: now)
        return WindowPlanner.plan(accounts: states, burnPctPerHour: rate, busySessions: 1, now: now)
    }
}
