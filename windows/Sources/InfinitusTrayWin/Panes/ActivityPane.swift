import Foundation
import InfinitusCore
import InfinitusWinUI
import WinSDK

public final class ActivityPane: SettingsPane {
    public static var descriptor: PaneDescriptor {
        PaneDescriptor(
            id: "activity",
            title: "Activity",
            glyph: "\u{E81C}",
            tintRGB: (60, 180, 180),
            keywords: ["history", "switches", "log", "events", "activity", "switch"]
        )
    }

    private var ctx: PaneContext?
    private var refreshButtonHwnd: HWND?
    private var openLogButtonHwnd: HWND?

    private var dynamicLabels: [HWND] = []

    private var switchHistory: [SwitchHistoryList.Switch] = []
    private var logPath: String?
    private var engineEvents: [StatsEvent] = []
    private var isLoading = false
    private var computedHeight: Int32 = 600

    public init() {}

    public func attach(host: HWND, ctx: PaneContext) {
        self.ctx = ctx
        let base = ctx.idBase

        refreshButtonHwnd = PaneControls.button("Refresh", in: ctx, id: base + 1, x: 0, y: 0, w: 0, h: 0)
        openLogButtonHwnd = PaneControls.button("Open full log…", in: ctx, id: base + 2, x: 0, y: 0, w: 0, h: 0)
    }

    public func layout(width: Int32, height: Int32) {
        guard let ctx else { return }
        ctx.recycleTransients()
        let m = ctx.metrics
        let pad = m.pad
        let contentW = max(100, width - pad * 2)

        var y = pad

        // Top button bar
        let btnW = m.px(90)
        let fieldH = m.fieldHeight + m.px(4)
        if let rBtn = refreshButtonHwnd {
            MoveWindow(rBtn, pad, y, btnW, fieldH, true)
        }
        if let lBtn = openLogButtonHwnd {
            MoveWindow(lBtn, pad + btnW + m.px(10), y, m.px(120), fieldH, true)
        }
        y += fieldH + m.sectionGap

        // Clear dynamic labels
        for lbl in dynamicLabels {
            DestroyWindow(lbl)
        }
        dynamicLabels.removeAll()

        // Section 1: Switch history
        y = PaneControls.sectionHeader("Switch history", in: ctx, y: y, width: width)

        let accounts = TrayFleet.cached()?.accounts ?? []
        func accountName(_ num: Int) -> String {
            if let acc = accounts.first(where: { $0.number == num }) {
                return acc.alias ?? acc.email.split(separator: "@").first.map(String.init) ?? "\(num)"
            }
            return "account \(num)"
        }

        if switchHistory.isEmpty {
            let emptyMsg = CswapLocator.locate() == nil
                ? "cswap not found — switch history comes from cswap history."
                : "No switches recorded."
            if let l = PaneControls.label(emptyMsg, in: ctx, x: pad + m.px(4), y: y, w: contentW, h: m.px(18), caption: true, color: WinDark.dim) {
                dynamicLabels.append(l)
            }
            y += m.px(24)
        } else {
            for sw in switchHistory.prefix(15) {
                let fromName = accountName(sw.from)
                let toName = accountName(sw.to)
                let text = "\(fromName)  →  \(toName)"

                let timeStr = UsageHistory.parseISO(sw.at).map { formatTime($0) } ?? sw.at

                if let l1 = PaneControls.label(text, in: ctx, x: pad + m.px(4), y: y, w: contentW - m.px(110), h: m.px(18), bold: true) {
                    dynamicLabels.append(l1)
                }
                if let lTime = PaneControls.label(timeStr, in: ctx, x: pad + contentW - m.px(100), y: y, w: m.px(96), h: m.px(18), caption: true, color: WinDark.dim) {
                    dynamicLabels.append(lTime)
                }
                y += m.px(20)
            }
        }

        y += m.sectionGap

        // Section 2: Engine events
        y = PaneControls.sectionHeader("Engine events", in: ctx, y: y, width: width)

        if engineEvents.isEmpty {
            if let l = PaneControls.label("No events yet", in: ctx, x: pad + m.px(4), y: y, w: contentW, h: m.px(18), caption: true, color: WinDark.dim) {
                dynamicLabels.append(l)
            }
            y += m.px(24)
        } else {
            let recentEvents = engineEvents.suffix(30).reversed()
            for evt in recentEvents {
                let glyph = segoeGlyph(for: evt.icon)
                let timeStr = formatTime(evt.at)

                let line = "\(glyph)  \(evt.text)"
                if let l1 = PaneControls.label(line, in: ctx, x: pad + m.px(4), y: y, w: contentW - m.px(110), h: m.px(18)) {
                    dynamicLabels.append(l1)
                }
                if let lTime = PaneControls.label(timeStr, in: ctx, x: pad + contentW - m.px(100), y: y, w: m.px(96), h: m.px(18), caption: true, color: WinDark.dim) {
                    dynamicLabels.append(lTime)
                }
                y += m.px(20)
            }
        }

        y += m.sectionGap + pad
        computedHeight = y
        PaneHost.setContentHeight(ctx.host, computedHeight)
    }

    public func activate() {
        refresh()
    }

    public func deactivate() {}

    public func command(id: Int32, code: UINT, from: HWND?) -> Bool {
        guard let ctx else { return false }
        let base = ctx.idBase
        if id == base + 1 {
            refresh()
            return true
        } else if id == base + 2 {
            openLog()
            return true
        }
        return false
    }

    public func notify(_ header: UnsafePointer<NMHDR>) -> Bool { false }
    public func drawItem(_ item: UnsafePointer<DRAWITEMSTRUCT>) -> Bool { false }

    public func contentHeight(width: Int32) -> Int32 {
        computedHeight
    }

    // MARK: - Scanning & Helpers

    private func refresh() {
        guard !isLoading, let ctx else { return }
        isLoading = true

        ctx.async { () -> ([SwitchHistoryList.Switch], String?, [StatsEvent]) in
            var switches: [SwitchHistoryList.Switch] = []
            var logPath: String? = nil

            if let cli = CswapLocator.locate() {
                let sem = DispatchSemaphore(value: 0)
                Task {
                    if let list = try? await CswapCLI(binaryPath: cli).history(limit: 20) {
                        switches = list.switches
                        logPath = list.logPath
                    }
                    sem.signal()
                }
                sem.wait()
            }

            let events = WinEventStore.load()
            return (switches, logPath, events)
        } then: { [weak self] (switches, logPath, events) in
            guard let self else { return }
            self.isLoading = false
            self.switchHistory = switches
            self.logPath = logPath
            self.engineEvents = events

            if let host = self.ctx?.host {
                var rc = RECT()
                GetClientRect(host, &rc)
                self.layout(width: rc.right - rc.left, height: rc.bottom - rc.top)
                InvalidateRect(host, nil, true)
            }
        }
    }

    private func openLog() {
        let path = logPath ?? WinEventStore.url.path
        let wide = Array(path.utf16) + [0]
        _ = wide.withUnsafeBufferPointer { buf in
            ShellExecuteW(nil, nil, buf.baseAddress, nil, nil, SW_SHOWNORMAL)
        }
    }

    private func segoeGlyph(for iconName: String) -> String {
        switch iconName {
        case "arrow.left.arrow.right", "arrow.triangle.2.circlepath", "switch":
            return "⇄"
        case "skull", "death":
            return "💀"
        case "sparkles", "revival":
            return "✨"
        case "exclamationmark.triangle", "limit":
            return "⚠"
        case "bolt.fill", "ignite":
            return "⚡"
        case "play.fill", "resume", "nudge":
            return "⟲"
        default:
            return "●"
        }
    }

    private func formatTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let pDate = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let pNow = calendar.dateComponents([.year, .month, .day], from: now)
        let hour = pDate.hour ?? 0
        let minute = pDate.minute ?? 0
        let timeStr = String(format: "%02d:%02d", hour, minute)

        if pDate.year == pNow.year && pDate.month == pNow.month && pDate.day == pNow.day {
            return timeStr
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now) {
            let pYest = calendar.dateComponents([.year, .month, .day], from: yesterday)
            if pDate.year == pYest.year && pDate.month == pYest.month && pDate.day == pYest.day {
                return "yesterday \(timeStr)"
            }
        }

        let monthNames = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let mIdx = max(1, min(12, pDate.month ?? 1))
        return "\(monthNames[mIdx]) \(pDate.day ?? 1) \(timeStr)"
    }
}
