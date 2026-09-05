import Foundation
import InfinitusCore
import InfinitusWinUI
import WinSDK

public final class UsagePane: SettingsPane {
    public static var descriptor: PaneDescriptor {
        PaneDescriptor(
            id: "usage",
            title: "Usage",
            glyph: "\u{E9D2}",
            tintRGB: (50, 190, 90),
            keywords: ["spend", "cost", "tokens", "estimate", "usage", "model", "account"]
        )
    }

    private var ctx: PaneContext?
    private var windowComboHwnd: HWND?
    private var refreshButtonHwnd: HWND?
    private var statusLabelHwnd: HWND?

    private var dailyCanvasHwnd: HWND?
    private var modelsCanvasHwnd: HWND?
    private var caveatsLabelHwnd: HWND?

    private var accountRowLabels: [HWND] = []

    private var report: UsageReport?
    private var isLoading = false
    private var selectedDays: Int = 7
    private var computedHeight: Int32 = 600

    private var cacheURL: URL {
        WinSettingsStore.infinitusHome.appendingPathComponent("usage-cache.json")
    }

    public init() {
        selectedDays = WinSettingsStore.load().usageDays
        if selectedDays != 7 && selectedDays != 14 && selectedDays != 30 {
            selectedDays = 7
        }
    }

    public func attach(host: HWND, ctx: PaneContext) {
        self.ctx = ctx
        let base = ctx.idBase

        // Window combo (7, 14, 30 days)
        let comboItems = ["7 days", "14 days", "30 days"]
        windowComboHwnd = PaneControls.combo(comboItems, in: ctx, id: base + 1, x: 0, y: 0, w: 0, h: 0)
        let selStr = "\(selectedDays) days"
        PaneControls.setComboSelection(windowComboHwnd, selStr)

        // Refresh button
        refreshButtonHwnd = PaneControls.button("Refresh", in: ctx, id: base + 2, x: 0, y: 0, w: 0, h: 0)

        // Status label
        statusLabelHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)

        // Canvas controls for charts
        dailyCanvasHwnd = PaneControls.canvas(in: ctx, id: base + 10, x: 0, y: 0, w: 0, h: 0)
        modelsCanvasHwnd = PaneControls.canvas(in: ctx, id: base + 11, x: 0, y: 0, w: 0, h: 0)

        // Caveats label
        caveatsLabelHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.faint)

        // Load disk cache immediately
        loadCache()
    }

    public func layout(width: Int32, height: Int32) {
        guard let ctx else { return }
        ctx.recycleTransients()
        let m = ctx.metrics
        let pad = m.pad
        let contentW = max(100, width - pad * 2)

        var y = pad

        // Top bar: [Window: 7 days v]      [ Refresh ] scanning…
        let comboW = m.px(120)
        let btnW = m.px(80)
        let fieldH = m.fieldHeight + m.px(4)
        if let combo = windowComboHwnd {
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

        // Section 1: Daily estimated spend
        y = PaneControls.sectionHeader("Daily estimated spend", in: ctx, y: y, width: width)
        let dailyH = m.px(110)
        if let dailyC = dailyCanvasHwnd {
            MoveWindow(dailyC, pad, y, contentW, dailyH, true)
        }
        y += dailyH + m.sectionGap

        // Section 2: By model
        y = PaneControls.sectionHeader("By model", in: ctx, y: y, width: width)
        let models = report.map { modelsSpend(from: $0) } ?? []
        let modelsCount = max(1, models.count)
        let modelsH = min(m.px(160), max(m.px(60), Int32(modelsCount) * m.px(24)))
        if let modelsC = modelsCanvasHwnd {
            MoveWindow(modelsC, pad, y, contentW, modelsH, true)
        }
        y += modelsH + m.sectionGap

        // Section 3: Estimated spend, last N days
        y = PaneControls.sectionHeader("Estimated spend, last \(selectedDays) days", in: ctx, y: y, width: width)

        // Clear previous dynamic account labels
        for lbl in accountRowLabels {
            DestroyWindow(lbl)
        }
        accountRowLabels.removeAll()

        if let r = report {
            var rank = 1
            for acc in r.accounts {
                let name = acc.alias ?? acc.email ?? "Account \(acc.number ?? rank)"
                let spendStr = String(format: "$%.2f", acc.estimatedUSD)
                let details = "\(acc.messages) msgs · out \(TokenFormat.compact(acc.output)) · cache \(TokenFormat.compact(acc.cacheRead))"
                let line1 = "\(rank)  \(name)"

                if let l1 = PaneControls.label(line1, in: ctx, x: pad + m.px(4), y: y, w: contentW - m.px(100), h: m.px(18), bold: true) {
                    accountRowLabels.append(l1)
                }
                if let lSpend = PaneControls.label(spendStr, in: ctx, x: pad + contentW - m.px(90), y: y, w: m.px(86), h: m.px(18), bold: true) {
                    accountRowLabels.append(lSpend)
                }
                y += m.px(18)

                if let l2 = PaneControls.label(details, in: ctx, x: pad + m.px(16), y: y, w: contentW - m.px(20), h: m.px(16), caption: true, color: WinDark.dim) {
                    accountRowLabels.append(l2)
                }
                y += m.px(20)
                rank += 1
            }

            if let unattributed = r.unattributed, unattributed.estimatedUSD > 0 {
                let line = "before switch log"
                let spendStr = String(format: "$%.2f", unattributed.estimatedUSD)
                if let l1 = PaneControls.label(line, in: ctx, x: pad + m.px(16), y: y, w: contentW - m.px(100), h: m.px(18)) {
                    accountRowLabels.append(l1)
                }
                if let lSpend = PaneControls.label(spendStr, in: ctx, x: pad + contentW - m.px(90), y: y, w: m.px(86), h: m.px(18)) {
                    accountRowLabels.append(lSpend)
                }
                y += m.px(22)
            }

            // Total
            let totalLine = "Total"
            let totalStr = String(format: "$%.2f", r.estimatedTotalUSD)
            if let l1 = PaneControls.label(totalLine, in: ctx, x: pad + m.px(4), y: y, w: contentW - m.px(100), h: m.px(20), bold: true) {
                accountRowLabels.append(l1)
            }
            if let lSpend = PaneControls.label(totalStr, in: ctx, x: pad + contentW - m.px(90), y: y, w: m.px(86), h: m.px(20), bold: true) {
                accountRowLabels.append(lSpend)
            }
            y += m.px(26)
        } else if !isLoading {
            let emptyMsg = CswapLocator.locate() == nil
                ? "cswap not found — spend estimates come from cswap usage."
                : "No usage history found for the selected window."
            if let l = PaneControls.label(emptyMsg, in: ctx, x: pad + m.px(4), y: y, w: contentW, h: m.px(24), caption: true, color: WinDark.dim) {
                accountRowLabels.append(l)
            }
            y += m.px(30)
        }

        y += m.sectionGap

        // Caveats footer
        let caveatsText = (report?.caveats.isEmpty ?? true)
            ? "Usage-cost figures are estimates, never billing truth."
            : (report?.caveats.joined(separator: " ") ?? "")
        let measuredH = PaneControls.helpText(caveatsText, in: ctx, x: pad, y: y, width: contentW)
        if let cav = caveatsLabelHwnd {
            MoveWindow(cav, pad, y, contentW, measuredH, true)
            PaneControls.setText(cav, caveatsText)
        }
        y += measuredH + m.sectionGap + pad

        computedHeight = y
        PaneHost.setContentHeight(ctx.host, computedHeight)
    }

    public func activate() {
        if report == nil {
            refresh()
        }
    }

    public func deactivate() {}

    public func command(id: Int32, code: UINT, from: HWND?) -> Bool {
        guard let ctx else { return false }
        let base = ctx.idBase
        if id == base + 1 && code == UINT(CBN_SELCHANGE) {
            let sel = PaneControls.comboSelection(windowComboHwnd)
            if sel.contains("14") { selectedDays = 14 }
            else if sel.contains("30") { selectedDays = 30 }
            else { selectedDays = 7 }
            _ = try? WinSettingsStore.update { $0.usageDays = self.selectedDays }
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
            // Daily estimated spend chart
            drawDailyChart(dis.hDC, rect: dis.rcItem)
            return true
        } else if ctlID == base + 11 {
            // By model horizontal chart
            drawModelsChart(dis.hDC, rect: dis.rcItem)
            return true
        }
        return false
    }

    public func contentHeight(width: Int32) -> Int32 {
        computedHeight
    }

    // MARK: - Private loading & rendering

    private func loadCache() {
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(UsageReport.self, from: data),
           cached.days == selectedDays {
            self.report = cached
        }
    }

    private func refresh() {
        guard !isLoading, let ctx else { return }
        isLoading = true
        PaneControls.setText(statusLabelHwnd, "scanning…")

        let days = selectedDays
        let url = cacheURL

        ctx.async { () -> (UsageReport?, String?) in
            guard let cli = CswapLocator.locate() else {
                return (nil, "cswap not found")
            }
            let sem = DispatchSemaphore(value: 0)
            var reportRes: UsageReport? = nil
            var errorRes: String? = nil

            Task {
                do {
                    let (r, raw) = try await CswapCLI(binaryPath: cli).usageReportRaw(days: days)
                    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? raw.write(to: url, options: .atomic)
                    reportRes = r
                } catch {
                    errorRes = "\(error)"
                }
                sem.signal()
            }
            sem.wait()
            return (reportRes, errorRes)
        } then: { [weak self] result in
            guard let self else { return }
            self.isLoading = false
            self.report = result.0
            if let err = result.1 {
                PaneControls.setText(self.statusLabelHwnd, err)
            } else {
                PaneControls.setText(self.statusLabelHwnd, "")
            }
            if let host = self.ctx?.host {
                var rc = RECT()
                GetClientRect(host, &rc)
                self.layout(width: rc.right - rc.left, height: rc.bottom - rc.top)
                InvalidateRect(host, nil, true)
            }
        }
    }

    private func modelsSpend(from r: UsageReport) -> [(model: String, estimatedUSD: Double)] {
        var byModel: [String: Double] = [:]
        for acc in r.accounts {
            for m in acc.models { byModel[m.model, default: 0] += m.estimatedUSD }
        }
        if let unattributed = r.unattributed {
            for m in unattributed.models { byModel[m.model, default: 0] += m.estimatedUSD }
        }
        return byModel.sorted(by: { $0.value > $1.value }).map { ($0.key, $0.value) }
    }

    private func drawDailyChart(_ dc: HDC, rect: RECT) {
        guard let ctx else { return }
        // Background
        if let bg = WinDark.backgroundBrush {
            var r = rect
            FillRect(dc, &r, bg)
        }

        guard let r = report, let daily = r.daily, !daily.isEmpty else {
            return
        }

        // Aggregate daily spend by date
        var byDate: [String: Double] = [:]
        for slice in daily {
            byDate[slice.date, default: 0.0] += slice.estimatedUSD
        }
        let sortedDates = byDate.keys.sorted()
        let values = sortedDates.map { byDate[$0] ?? 0.0 }
        let labels = sortedDates.map { d -> String in
            // Format "YYYY-MM-DD" -> "M/D"
            let parts = d.split(separator: "-")
            if parts.count == 3, let m = Int(parts[1]), let day = Int(parts[2]) {
                return "\(m)/\(day)"
            }
            return String(d.suffix(5))
        }

        GDIChart.bars(
            dc, rect,
            values: values,
            color: WinDark.rgb(50, 190, 90),
            labels: labels,
            metrics: ctx.metrics,
            font: ctx.captionFont
        )
    }

    private func drawModelsChart(_ dc: HDC, rect: RECT) {
        guard let ctx else { return }
        // Background
        if let bg = WinDark.backgroundBrush {
            var r = rect
            FillRect(dc, &r, bg)
        }

        guard let r = report else { return }
        let rawRows = modelsSpend(from: r)
        guard !rawRows.isEmpty else { return }
        let rows = rawRows.map { (label: $0.model, value: $0.estimatedUSD) }

        GDIChart.hbars(
            dc, rect,
            rows: rows,
            color: WinDark.rgb(80, 210, 180),
            metrics: ctx.metrics,
            font: ctx.captionFont
        )
    }
}
