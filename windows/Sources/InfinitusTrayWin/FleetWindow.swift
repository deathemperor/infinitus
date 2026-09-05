import Foundation
import InfinitusCore
import InfinitusWinUI
import WinSDK

/// The account panel — the Windows answer to the Mac popup's grid of
/// accounts with 5h/7d gauges (user 2026-09-04: "why windows do not have
/// UI likes MAC?").
///
/// Owner-drawn GDI, because there is no alternative: SwiftUI, AppKit and
/// UIKit ship only inside Apple's SDKs, and the Windows Swift SDK has
/// none of them (verified 2026-09-04 — 25 modules, no SwiftUI). The Mac's
/// 18,478 lines of SwiftUI cannot compile here at all, which is why
/// Package.swift fences them behind `#if os(macOS)`. So every rectangle
/// is placed by hand and every gauge is a FillRect.
///
/// What it deliberately does NOT copy: the burn overlays, HP-drop zooms
/// and intro choreography. Those are CAAnimations on the Mac
/// (CLAUDE.md's hard-won fact: five effects at 20 fps idled the pop-out
/// at 43% CPU; as layer animations, 0.4%). GDI has no equivalent
/// compositor, so imitating them would mean a repaint timer — the exact
/// thing that rule forbids. This paints on demand and on the tray's
/// existing 5 s tick, so an idle panel costs nothing.
///
/// Pace is still SHOWN, just statically: ahead-of-pace tints the bar
/// warm and marks where the burn should be, behind-pace tints it cool.
enum FleetWindow {
    private static let windowClassName = "InfinitusFleetWindow"
    private nonisolated(unsafe) static var isClassRegistered = false
    private nonisolated(unsafe) static var open: HWND?
    /// Own repaint tick, alive only while the window is. 3 s is well
    /// under the engine layer's 30 s cache, so most ticks are a repaint
    /// of unchanged data and the subprocess runs at its own pace.
    private static let refreshTimerId: UINT_PTR = 1
    private static let refreshMilliseconds: UINT = 3000

    // MARK: - metrics (moved to shared Metrics.swift)

    /// The slot badge's text for a row — the theme's prefix ("agent-",
    /// "P", "🎬", …) plus the number, or the active icon on the active
    /// row (the Mac's `slotDisplay` rule).
    static func slotString(for row: FleetLayout.Row, theme: RowTheme?) -> String {
        if row.active, let theme, !theme.plain, !theme.activeIcon.isEmpty {
            return theme.activeIcon
        }
        return (theme?.slotPrefix ?? "") + "\(row.number)"
    }

    /// Widest slot badge in the panel, so every row's name column starts
    /// at the same x (the Mac's `alignedColumn("slot")` rule). Measured
    /// exactly with `dc` + `font` when available; estimated from character
    /// counts otherwise (window sizing has no DC yet — resizeToFit does).
    static func slotColumnWidth(_ panel: FleetLayout.Panel, metrics: Metrics,
                                theme: RowTheme?, dc: HDC? = nil, font: HFONT? = nil) -> Int32 {
        var oldFont: HGDIOBJ? = nil
        if let dc, let font { oldFont = SelectObject(dc, font) }
        defer {
            if let dc, let oldFont { _ = SelectObject(dc, oldFont) }
        }
        var maxW = metrics.numberWidth
        for row in panel.rows {
            let s = slotString(for: row, theme: theme)
            if let dc {
                maxW = max(maxW, textExtent(dc, s).cx + metrics.px(8))
            } else {
                // ~6.5 px/char at 96 dpi for Segoe UI caption; emoji count as two
                maxW = max(maxW, metrics.px(Int32(s.count) * 7 + 10))
            }
        }
        return maxW
    }

    /// The window's own size for a given panel — computed, not guessed,
    /// so the frame always fits its rows AND its fleet headers.
    static func idealSize(rows: Int, gauges: Int, metrics: Metrics,
                          fleetHeaders: Int = 0, slotWidth: Int32? = nil) -> (width: Int32, height: Int32) {
        let width = metrics.pad * 2 + (slotWidth ?? metrics.numberWidth) + metrics.nameWidth
            + Int32(max(1, gauges)) * (metrics.barWidth + metrics.gaugeGap + metrics.px(52))
        let body = Int32(max(1, rows)) * metrics.rowHeight
            + Int32(fleetHeaders) * metrics.fleetHeaderHeight
        let height = metrics.headerHeight + body + metrics.footerHeight + metrics.pad
        return (min(width, metrics.px(980)), min(height, metrics.px(680)))
    }

    /// True when a card paints a subtitle line under its header — dead
    /// note, or the email on a non-active row. cardHeight and paintCard
    /// must agree on this or content overflows the card's bottom edge.
    static func hasCardSubtitle(_ row: FleetLayout.Row) -> Bool {
        if row.deadNote != nil { return true }
        return !row.active && !row.email.isEmpty
    }

    /// A card's full height: top pad, header line, optional subtitle,
    /// gauge rows, bottom pad — the same arithmetic paintCard walks.
    /// One source of truth: place() sizes the cards, idealSize sizes the
    /// window, paintCard draws inside — drift between them clipped the
    /// subtitle under the card edge.
    static func cardHeight(_ row: FleetLayout.Row, metrics: Metrics) -> Int32 {
        metrics.px(8 + 18 + (hasCardSubtitle(row) ? 14 : 0) + 2)
            + Int32(max(1, row.gauges.count)) * metrics.px(20) + metrics.px(8)
    }

    /// Layout-aware ideal size matching Mac popup layouts ("wide", "stacked", "hstack").
    /// The card layouts run place() itself and take the final y — one
    /// walk decides both the cards' bounds and the window's height, so
    /// the two can never drift.
    static func idealSize(panel: FleetLayout.Panel, metrics: Metrics, layout: String) -> (width: Int32, height: Int32) {
        switch layout {
        case "stacked":
            let width = min(metrics.pad * 2 + metrics.px(380), metrics.px(980))
            let bodyH = place(panel, metrics: metrics, layout: layout, clientWidth: width)
                .last?.rect.bottom ?? metrics.headerHeight
            let height = bodyH + metrics.footerHeight + metrics.pad
            return (width, min(height, metrics.px(760)))

        case "hstack":
            let cardW = metrics.px(230)
            let gap = metrics.px(8)
            let accCount = max(1, panel.rows.count)
            // Enough columns for every card, capped so the window stays
            // within the max width — extra cards wrap onto further rows.
            let availW = metrics.px(1100) - metrics.pad * 2
            let cols = min(Int32(accCount), max(1, (availW + gap) / (cardW + gap)))
            let width = metrics.pad * 2 + cols * cardW + (cols - 1) * gap
            let bodyH = place(panel, metrics: metrics, layout: layout, clientWidth: width)
                .last?.rect.bottom ?? metrics.headerHeight
            let height = bodyH + metrics.footerHeight + metrics.pad
            return (width, min(height, metrics.px(680)))

        default: // "wide"
            let gauges = panel.rows.map(\.gauges.count).max() ?? 2
            let headers = panel.lines.filter { if case .header = $0 { return true } else { return false } }.count
            let slotW = slotColumnWidth(panel, metrics: metrics, theme: currentTheme())
            return idealSize(rows: max(1, panel.rows.count), gauges: gauges, metrics: metrics,
                             fleetHeaders: headers, slotWidth: slotW)
        }
    }

    /// The panel's paint plan: every header and row with the bounds it sits
    /// at, so painting and hit-testing can never fall out of step.
    struct Placed {
        let line: FleetLayout.Line
        let rect: RECT
    }

    static func place(_ panel: FleetLayout.Panel, metrics: Metrics,
                      layout: String = "wide", clientWidth: Int32 = 0) -> [Placed] {
        var out: [Placed] = []
        let pad = metrics.pad

        switch layout {
        case "stacked":
            var y = metrics.headerHeight
            let w = max(metrics.px(200), (clientWidth > 0 ? clientWidth : metrics.px(420)) - pad * 2)
            for line in panel.lines {
                switch line {
                case .header:
                    let r = RECT(left: pad, top: y, right: pad + w, bottom: y + metrics.fleetHeaderHeight)
                    out.append(Placed(line: line, rect: r))
                    y += metrics.fleetHeaderHeight + metrics.px(4)
                case .account(let row):
                    let cardH = cardHeight(row, metrics: metrics)
                    let r = RECT(left: pad, top: y, right: pad + w, bottom: y + cardH)
                    out.append(Placed(line: line, rect: r))
                    y += cardH + metrics.px(8)
                }
            }

        case "hstack":
            let cardW = metrics.px(230)
            let gap = metrics.px(8)
            var maxCardH: Int32 = metrics.px(80)
            for row in panel.rows {
                maxCardH = max(maxCardH, cardHeight(row, metrics: metrics))
            }
            // Wrap into a grid of `cols` per row — 8 Gemini accounts at
            // 238px each must never run off the window's right edge.
            let availW = max(cardW, (clientWidth > 0 ? clientWidth : metrics.px(1100)) - pad * 2)
            let cols = max(1, (availW + gap) / (cardW + gap))
            var y = metrics.headerHeight
            var col = 0
            for line in panel.lines {
                switch line {
                case .header:
                    if col > 0 {
                        col = 0
                        y += maxCardH + gap
                    }
                    let r = RECT(left: pad, top: y, right: pad + availW, bottom: y + metrics.fleetHeaderHeight)
                    out.append(Placed(line: line, rect: r))
                    y += metrics.fleetHeaderHeight + metrics.px(4)
                case .account(let row):
                    let h = cardHeight(row, metrics: metrics)
                    let x = pad + Int32(col) * (cardW + gap)
                    let r = RECT(left: x, top: y, right: x + cardW, bottom: y + maxCardH)
                    out.append(Placed(line: line, rect: r))
                    col += 1
                    if col >= cols {
                        col = 0
                        y += maxCardH + gap
                    }
                }
            }

        default: // "wide"
            var y = metrics.headerHeight
            let w = max(metrics.px(200), clientWidth > 0 ? clientWidth : metrics.px(600))
            for line in panel.lines {
                let height: Int32
                let rect: RECT
                switch line {
                case .header:
                    height = metrics.fleetHeaderHeight
                    rect = RECT(left: pad, top: y, right: w - pad, bottom: y + height)
                case .account:
                    height = metrics.rowHeight
                    rect = RECT(left: pad / 2, top: y, right: w - pad / 2, bottom: y + height - 2)
                }
                out.append(Placed(line: line, rect: rect))
                y += height
            }
        }
        return out
    }

    // MARK: - colours
    //
    // The shared dark palette (WinDark.swift) — the settings window uses
    // the same one, so the two can't drift into slightly different greys
    // sitting side by side. Fixed rather than following the system theme:
    // the Mac popup is dark in both appearances, and a light variant
    // would need its own contrast pass to stay readable.

    private static let bg = WinDark.bg
    private static let rowBg = WinDark.rowBg
    private static let activeBg = WinDark.activeBg
    private static let text = WinDark.text
    private static let dim = WinDark.dim
    private static let faint = WinDark.faint
    /// The fleet header's provider name — brighter than its engine name,
    /// the same emphasis split the Mac's `FleetHeader` uses (semibold
    /// provider, secondary engine).
    private static let headerText = WinDark.headerText
    private static let track = WinDark.track
    private static let sessionColor = WinDark.sessionColor
    private static let weeklyColor = WinDark.weeklyColor
    private static let scopedColor = WinDark.scopedColor
    private static let dangerColor = WinDark.dangerColor
    private static let warmTint = WinDark.warmTint
    private static let coolTint = WinDark.coolTint

    /// A gauge's colour by its label, matching the active theme's colors
    /// (session blue, weekly purple, per-model amber) and going red once
    /// the window is spent.
    static func color(for gauge: FleetLayout.Gauge, theme: RowTheme? = nil) -> COLORREF {
        if gauge.spent { return dangerColor }
        if let theme, !theme.plain {
            switch gauge.label {
            case "5h", theme.sessionLabel:
                return WinDark.themeColor(theme.sessionColor)
            case "7d", theme.weeklyLabel:
                return WinDark.themeColor(theme.weeklyColor)
            default:
                return WinDark.themeColor(theme.scopedColor)
            }
        }
        switch gauge.label {
        case "5h": return sessionColor
        case "7d": return weeklyColor
        default: return scopedColor
        }
    }

    /// Resolves the currently configured RowTheme from settings.
    static func currentTheme() -> RowTheme {
        let style = WinSettingsStore.load().gamificationStyle
        let custom = RowTheme.loadCustom(from: WinSettingsStore.windowsThemesURL)
        let all = RowTheme.builtins + custom
        return all.first { $0.id == style } ?? RowTheme.off
    }

    // MARK: - state

    final class State {
        var panel = FleetLayout.Panel(empty: "Loading\u{2026}")
        var titleFont: HFONT?
        var bodyFont: HFONT?
        var captionFont: HFONT?
        /// Row under the pointer, for the hover highlight.
        var hotRow = -1
        /// Set while a switch is in flight so a second click can't queue
        /// another one behind it.
        var switching = false

        deinit {
            for font in [titleFont, bodyFont, captionFont] {
                if let font { DeleteObject(font) }
            }
        }
    }

    // MARK: - opening

    /// Shows the panel, raising the existing one rather than stacking a
    /// second window (the Mac popup is single too).
    static func show() {
        if let existing = open, IsWindow(existing) {
            if IsIconic(existing) { ShowWindow(existing, SW_RESTORE) }
            SetForegroundWindow(existing)
            refresh(existing)
            return
        }
        registerClassIfNeeded()
        let state = State()
        state.panel = currentPanel()
        let retained = Unmanaged.passRetained(state).toOpaque()

        let title = Array("Infinitus \u{2014} accounts".utf16) + [0]
        let className = Array(windowClassName.utf16) + [0]
        let style = DWORD(WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX)
        guard let hwnd = CreateWindowExW(
            0, className, title, style,
            Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT), 100, 100,
            nil, nil, GetModuleHandleW(nil), retained)
        else {
            Unmanaged<State>.fromOpaque(retained).release()
            return
        }
        open = hwnd
        // Before ShowWindow: DWM re-renders the frame when the attribute
        // changes, so a visible window flashes a light caption first.
        WinDark.applyTitleBar(to: hwnd)
        // Size AFTER creating it, for two reasons found by looking at the
        // result (2026-09-04): GetDpiForWindow needs a real window, so
        // measuring before gave 96 dpi and a panel too small for its own
        // rows; and CreateWindowExW's size is the OUTER frame, so caption
        // and borders were eating the content height — the second row and
        // the footer overlapped.
        resizeToFit(hwnd, panel: state.panel, style: style)
        ShowWindow(hwnd, SW_SHOW)
        SetForegroundWindow(hwnd)
    }

    /// Grows the window so every row fits, converting the content size to
    /// an outer frame with AdjustWindowRectExForDpi — the client area is
    /// what the painting code addresses, and the frame is what
    /// SetWindowPos takes.
    private static func resizeToFit(_ hwnd: HWND, panel: FleetLayout.Panel, style: DWORD) {
        let metrics = Metrics(hwnd: hwnd)
        let layout = WinSettingsStore.load().popupLayout
        let content = idealSize(panel: panel, metrics: metrics, layout: layout)
        var rect = RECT(left: 0, top: 0, right: content.width, bottom: content.height)
        AdjustWindowRectExForDpi(&rect, style, false, 0, GetDpiForWindow(hwnd))
        SetWindowPos(hwnd, nil, 0, 0, rect.right - rect.left, rect.bottom - rect.top,
                     UINT(SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE))
    }

    /// Re-reads the engine and repaints — called on the tray's tick so an
    /// open panel stays current without a timer of its own.
    static func refresh(_ hwnd: HWND? = nil) {
        let target = hwnd ?? open
        guard let target, IsWindow(target) else { return }
        let raw = GetWindowLongPtrW(target, GWLP_USERDATA)
        guard raw != 0, let ptr = UnsafeMutableRawPointer(bitPattern: Int(raw)) else { return }
        let state = Unmanaged<State>.fromOpaque(ptr).takeUnretainedValue()
        let previous = state.panel
        state.panel = currentPanel()
        // The first engine read is async, so the panel opens on the
        // "Reading accounts…" placeholder and the rows arrive a moment
        // later. Re-fit when the shape changes or they stay clipped —
        // that is what the first screenshot showed (2026-09-04).
        let rowsChanged = previous.rows.count != state.panel.rows.count
        let gaugesChanged = (previous.rows.map(\.gauges.count).max() ?? 0)
            != (state.panel.rows.map(\.gauges.count).max() ?? 0)
        // A fleet appearing or disappearing changes the header count and
        // so the height, even when the row total happens to match.
        let sectionsChanged = previous.sections.count != state.panel.sections.count
        if rowsChanged || gaugesChanged || sectionsChanged {
            let style = DWORD(bitPattern: Int32(truncatingIfNeeded:
                GetWindowLongPtrW(target, GWL_STYLE)))
            resizeToFit(target, panel: state.panel, style: style)
        }
        InvalidateRect(target, nil, false)
    }

    /// True while a panel is on screen, so the tray only refreshes then.
    static var isOpen: Bool {
        guard let open else { return false }
        return IsWindow(open)
    }

    private static func currentPanel() -> FleetLayout.Panel {
        // `INFINITUS_ACCOUNTS_JSON=<path>` renders a fixture instead of
        // the engine — the only way to exercise the GAUGE painting here,
        // since a token account reports `usage: null` (usageStatus
        // "unavailable") and draws no bars at all. Same seam the resume
        // supervisor's tests use. `[EngineFleet]` is tried first so a
        // multi-fleet fixture exercises the headers too.
        if let path = ProcessInfo.processInfo.environment["INFINITUS_ACCOUNTS_JSON"],
           !path.isEmpty,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            let (_, _, live) = liveCounts()
            if let fleets = try? JSONDecoder().decode([EngineFleet].self, from: data) {
                return FleetLayout.panel(fleets: fleets, live: live, engineInstalled: true)
            }
            if let fixture = try? JSONDecoder().decode(AccountList.self, from: data) {
                return FleetLayout.panel(list: fixture, live: live, engineInstalled: true)
            }
        }
        let (_, _, live) = liveCounts()
        // Every fleet the engine holds, not just the flattened Claude
        // one: with 9Router that is Claude, Codex, Gemini, Kiro… each
        // under its own "<provider> · 9Router" header, the same stack the
        // Mac's FleetStack renders.
        return FleetLayout.panel(fleets: TrayFleet.cachedFleets(), live: live,
                                 engineInstalled: TrayFleet.hasEngine(),
                                 engine: TrayFleet.engineIndicator())
    }

    /// Session totals for the footer, from the same records the tray
    /// menu counts.
    private static func liveCounts() -> (total: Int, busy: Int, live: LiveSessions) {
        let (rows, busy) = readSessions()
        let waiting = rows.filter { $0.status == "waiting" }.count
        let idle = rows.filter { $0.status == "idle" }.count
        return (rows.count, busy,
                LiveSessions(busy: busy, total: rows.count, idle: idle,
                             waiting: waiting, shell: 0, unknown: 0, sessions: nil))
    }

    private static func registerClassIfNeeded() {
        guard !isClassRegistered else { return }
        let className = Array(windowClassName.utf16) + [0]
        var wc = WNDCLASSW()
        wc.lpfnWndProc = fleetWndProc
        wc.hInstance = GetModuleHandleW(nil)
        // Own background brush: letting the class paint COLOR_BTNFACE
        // flashes light grey behind a dark panel on every resize.
        wc.hbrBackground = CreateSolidBrush(bg)
        wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
        className.withUnsafeBufferPointer { buf in
            wc.lpszClassName = buf.baseAddress
            _ = RegisterClassW(&wc)
        }
        isClassRegistered = true
    }

    // MARK: - window procedure

    private static let fleetWndProc: @convention(c) (HWND?, UINT, WPARAM, LPARAM) -> LRESULT = {
        hwnd, msg, wParam, lParam in
        guard let hwnd else { return DefWindowProcW(hwnd, msg, wParam, lParam) }

        if msg == UINT(WM_NCCREATE) {
            let cs = UnsafePointer<CREATESTRUCTW>(bitPattern: Int(lParam))
            if let ptr = cs?.pointee.lpCreateParams {
                SetWindowLongPtrW(hwnd, GWLP_USERDATA, LONG_PTR(Int(bitPattern: ptr)))
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam)
        }
        // GetWindowLongPtrW, never a Set/Set dance — that zeroed USERDATA
        // for any message arriving in between and gave the session window
        // a blank first paint (2026-09-04).
        let raw = GetWindowLongPtrW(hwnd, GWLP_USERDATA)
        guard raw != 0, let ptr = UnsafeMutableRawPointer(bitPattern: Int(raw)) else {
            return DefWindowProcW(hwnd, msg, wParam, lParam)
        }
        let state = Unmanaged<State>.fromOpaque(ptr).takeUnretainedValue()

        // Int32(bitPattern:), not Int32(_:): Windows sends messages above
        // Int32.max and the checked initializer TRAPS on them ("Not
        // enough bits to represent the passed value", 2026-09-04).
        switch Int32(bitPattern: msg) {
        case WM_CREATE:
            makeFonts(hwnd: hwnd, state: state)
            // The panel drives its OWN refresh rather than depending on
            // the tray's tick: `--panel` runs this window with no tray at
            // all, and it sat on "Reading accounts…" forever because the
            // first read is async and nothing came back to repaint it.
            // Only alive while the window is (killed in WM_DESTROY), and
            // it just re-reads a 30 s cache, so an open panel is cheap and
            // a closed one costs nothing.
            SetTimer(hwnd, refreshTimerId, refreshMilliseconds, nil)
            return 0

        case WM_TIMER:
            // Ask the engine layer to re-shell if ITS cache has expired;
            // it coalesces, so calling every few seconds is free.
            TrayFleet.refresh()
            refresh(hwnd)
            return 0

        case WM_ERASEBKGND:
            // Painted whole in WM_PAINT via a back buffer; erasing here
            // as well is the flicker.
            return 1

        case WM_PAINT:
            paint(hwnd: hwnd, state: state)
            return 0

        case WM_MOUSEMOVE:
            var clientRc = RECT()
            GetClientRect(hwnd, &clientRc)
            let x = Int32(truncatingIfNeeded: lParam & 0xffff)
            let y = Int32(truncatingIfNeeded: lParam >> 16)
            let row = rowIndex(at: POINT(x: x, y: y), hwnd: hwnd, state: state, clientWidth: clientRc.right)
            if row != state.hotRow {
                state.hotRow = row
                InvalidateRect(hwnd, nil, false)
                // Ask for WM_MOUSELEAVE so the highlight clears when the
                // pointer exits without crossing a row.
                var track = TRACKMOUSEEVENT()
                track.cbSize = DWORD(MemoryLayout<TRACKMOUSEEVENT>.size)
                track.dwFlags = DWORD(TME_LEAVE)
                track.hwndTrack = hwnd
                TrackMouseEvent(&track)
            }
            return 0

        case WM_MOUSELEAVE:
            if state.hotRow != -1 {
                state.hotRow = -1
                InvalidateRect(hwnd, nil, false)
            }
            return 0

        case WM_LBUTTONUP:
            var clientRc = RECT()
            GetClientRect(hwnd, &clientRc)
            let x = Int32(truncatingIfNeeded: lParam & 0xffff)
            let y = Int32(truncatingIfNeeded: lParam >> 16)
            let index = rowIndex(at: POINT(x: x, y: y), hwnd: hwnd, state: state, clientWidth: clientRc.right)
            if index >= 0, index < state.panel.rows.count {
                clickRow(state.panel.rows[index], state: state, hwnd: hwnd)
            }
            return 0

        case WM_DPICHANGED:
            // Fonts are sized in device pixels, so a monitor change needs
            // new ones or the panel renders at the old scale.
            makeFonts(hwnd: hwnd, state: state)
            InvalidateRect(hwnd, nil, true)
            return 0

        case WM_CLOSE:
            DestroyWindow(hwnd)
            return 0

        case WM_DESTROY:
            KillTimer(hwnd, refreshTimerId)
            open = nil
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0)
            Unmanaged<State>.fromOpaque(ptr).release()
            return 0

        default:
            return DefWindowProcW(hwnd, msg, wParam, lParam)
        }
    }

    /// Which ROW a client-area (x, y) lands on, or -1 — a fleet header is not
    /// a row. Walks the same placement the paint uses, so a header's
    /// height can never desync the two.
    private static func rowIndex(at pt: POINT, hwnd: HWND, state: State, clientWidth: Int32 = 0) -> Int {
        let metrics = Metrics(hwnd: hwnd)
        let layout = WinSettingsStore.load().popupLayout
        var index = 0
        for placed in place(state.panel, metrics: metrics, layout: layout, clientWidth: clientWidth) {
            let hit = pt.x >= placed.rect.left && pt.x <= placed.rect.right
                && pt.y >= placed.rect.top && pt.y <= placed.rect.bottom
            switch placed.line {
            case .header:
                if hit { return -1 }
            case .account:
                if hit { return index }
                index += 1
            }
        }
        return -1
    }

    /// Clicking a row switches to that account — the engine decides, we
    /// forward and report (CLAUDE.md: account policy is the engine's).
    /// The row carries its own provider, so a Gemini row switches inside
    /// the Gemini fleet rather than being read as a Claude ordinal.
    private static func clickRow(_ row: FleetLayout.Row, state: State, hwnd: HWND) {
        guard !row.active, !state.switching else { return }
        state.switching = true
        TrayFleet.requestSwitch(to: row.number, provider: row.provider) { message in
            state.switching = false
            // The reply lands on a worker thread; the tray's own window
            // owns the balloon, and this window just needs repainting.
            TrayFleet.invalidate()
            TrayFleet.refresh(force: true)
            postEngineReport(message)
            if IsWindow(hwnd) { InvalidateRect(hwnd, nil, false) }
        }
    }

    // MARK: - fonts

    private static func makeFonts(hwnd: HWND, state: State) {
        for font in [state.titleFont, state.bodyFont, state.captionFont] {
            if let font { DeleteObject(font) }
        }
        let metrics = Metrics(hwnd: hwnd)
        state.titleFont = font(height: metrics.px(-15), bold: true)
        state.bodyFont = font(height: metrics.px(-13), bold: false)
        state.captionFont = font(height: metrics.px(-11), bold: false)
    }

    private static func font(height: Int32, bold: Bool) -> HFONT? {
        let face = Array("Segoe UI".utf16) + [0]
        return face.withUnsafeBufferPointer { buf in
            CreateFontW(height, 0, 0, 0, bold ? FW_SEMIBOLD : FW_NORMAL,
                        0, 0, 0, DWORD(DEFAULT_CHARSET), DWORD(OUT_TT_PRECIS),
                        DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY),
                        DWORD(DEFAULT_PITCH | FF_DONTCARE), buf.baseAddress)
        }
    }

    // MARK: - painting

    private static func paint(hwnd: HWND, state: State) {
        var ps = PAINTSTRUCT()
        guard let dc = BeginPaint(hwnd, &ps) else { return }
        defer { EndPaint(hwnd, &ps) }

        var client = RECT()
        GetClientRect(hwnd, &client)
        // Double-buffered: drawing rows straight to the window tears
        // visibly on a resize.
        guard let memDC = CreateCompatibleDC(dc),
              let bitmap = CreateCompatibleBitmap(dc, client.right, client.bottom)
        else { return }
        let oldBitmap = SelectObject(memDC, bitmap)
        defer {
            BitBlt(dc, 0, 0, client.right, client.bottom, memDC, 0, 0, DWORD(SRCCOPY))
            SelectObject(memDC, oldBitmap)
            DeleteObject(bitmap)
            DeleteDC(memDC)
        }

        fill(memDC, client, bg)
        SetBkMode(memDC, TRANSPARENT)
        let metrics = Metrics(hwnd: hwnd)

        // Header
        if let font = state.titleFont { SelectObject(memDC, font) }
        draw(memDC, "Infinitus", x: metrics.pad, y: metrics.px(7), color: text)

        if let empty = state.panel.empty {
            if let font = state.bodyFont { SelectObject(memDC, font) }
            drawWrapped(memDC, empty,
                        RECT(left: metrics.pad, top: metrics.headerHeight,
                             right: client.right - metrics.pad,
                             bottom: client.bottom - metrics.footerHeight),
                        color: dim)
        } else {
            let theme = currentTheme()
            let layout = WinSettingsStore.load().popupLayout
            // Exact slot-column width from the live DC — the estimated one
            // used at resize time can undershoot a long theme prefix.
            let slotW = slotColumnWidth(state.panel, metrics: metrics, theme: theme,
                                        dc: memDC, font: state.captionFont)
            if let style = DWORD(exactly: Int32(truncatingIfNeeded:
                GetWindowLongPtrW(hwnd, GWL_STYLE))),
               abs(Int(idealSize(panel: state.panel, metrics: metrics, layout: layout).width
                       - client.right)) > metrics.px(8) {
                resizeToFit(hwnd, panel: state.panel, style: style)
            }
            var index = 0
            for placed in place(state.panel, metrics: metrics, layout: layout, clientWidth: client.right) {
                switch placed.line {
                case .header(let label):
                    paintFleetHeader(memDC, label, top: placed.rect.top, metrics: metrics, state: state)
                case .account(let row):
                    if layout == "stacked" || layout == "hstack" {
                        paintCard(memDC, row, index: index, rect: placed.rect, metrics: metrics, state: state, theme: theme)
                    } else {
                        paintRow(memDC, row, index: index, top: placed.rect.top, width: client.right,
                                 metrics: metrics, state: state, theme: theme, slotWidth: slotW)
                    }
                    index += 1
                }
            }
        }

        // Footer
        if let font = state.captionFont { SelectObject(memDC, font) }
        draw(memDC, state.panel.footer, x: metrics.pad,
             y: client.bottom - metrics.footerHeight + metrics.px(6), color: faint)
        let hint = state.panel.rows.count > 1 ? "click an account to switch" : ""
        if !hint.isEmpty {
            let size = textExtent(memDC, hint)
            draw(memDC, hint, x: client.right - metrics.pad - size.cx,
                 y: client.bottom - metrics.footerHeight + metrics.px(6), color: faint)
        }
    }

    /// "Claude · 9Router" over a fleet's rows — the Mac's `FleetHeader`,
    /// same emphasis split (provider bright, engine dim, caveat amber).
    private static func paintFleetHeader(_ dc: HDC, _ label: FleetLabel,
                                         top: Int32, metrics: Metrics, state: State) {
        if let font = state.captionFont { SelectObject(dc, font) }
        var x = metrics.pad
        let y = top + metrics.px(5)
        draw(dc, label.provider.displayName, x: x, y: y, color: headerText)
        x += textExtent(dc, label.provider.displayName).cx + metrics.px(5)
        let separator = "\u{00B7}"
        draw(dc, separator, x: x, y: y, color: faint)
        x += textExtent(dc, separator).cx + metrics.px(5)
        draw(dc, label.engineName, x: x, y: y, color: dim)
        if let caveat = label.caveat, !caveat.isEmpty {
            x += textExtent(dc, label.engineName).cx + metrics.px(6)
            drawClipped(dc, "\u{2014} " + caveat, x: x, y: y,
                        maxWidth: metrics.px(360), color: warmTint)
        }
    }

    private static func paintCard(_ dc: HDC, _ row: FleetLayout.Row, index: Int,
                                  rect: RECT, metrics: Metrics, state: State,
                                  theme: RowTheme? = nil) {
        // Card background: active gets highlighted border/accent, hover gets lighter plate
        if row.active {
            fill(dc, rect, activeBg)
            // Accent outline
            if let pen = CreatePen(PS_SOLID, metrics.px(1), WinDark.selection) {
                let oldPen = SelectObject(dc, pen)
                let oldBrush = SelectObject(dc, GetStockObject(NULL_BRUSH))
                Rectangle(dc, rect.left, rect.top, rect.right, rect.bottom)
                SelectObject(dc, oldBrush)
                SelectObject(dc, oldPen)
                DeleteObject(pen)
            }
        } else if index == state.hotRow {
            fill(dc, rect, rowBg)
            if let pen = CreatePen(PS_SOLID, metrics.px(1), WinDark.separator) {
                let oldPen = SelectObject(dc, pen)
                let oldBrush = SelectObject(dc, GetStockObject(NULL_BRUSH))
                Rectangle(dc, rect.left, rect.top, rect.right, rect.bottom)
                SelectObject(dc, oldBrush)
                SelectObject(dc, oldPen)
                DeleteObject(pen)
            }
        } else {
            fill(dc, rect, WinDark.control)
            if let pen = CreatePen(PS_SOLID, metrics.px(1), WinDark.separator) {
                let oldPen = SelectObject(dc, pen)
                let oldBrush = SelectObject(dc, GetStockObject(NULL_BRUSH))
                Rectangle(dc, rect.left, rect.top, rect.right, rect.bottom)
                SelectObject(dc, oldBrush)
                SelectObject(dc, oldPen)
                DeleteObject(pen)
            }
        }

        let innerPad = metrics.px(8)
        var curY = rect.top + innerPad
        let innerW = rect.right - rect.left - innerPad * 2
        var curX = rect.left + innerPad

        // Header line in Card: Slot badge + Name + [Dead / Email]
        if let font = state.captionFont { SelectObject(dc, font) }
        let slotStr = slotString(for: row, theme: theme)
        draw(dc, slotStr, x: curX, y: curY + metrics.px(2),
             color: row.active ? text : faint)
        let slotW = textExtent(dc, slotStr).cx + metrics.px(6)
        curX += slotW

        if let font = state.bodyFont { SelectObject(dc, font) }
        let name = row.disabled ? "\(row.name) (held)" : row.name
        let availNameW = max(metrics.px(60), innerW - slotW)
        drawClipped(dc, name, x: curX, y: curY, maxWidth: availNameW,
                    color: row.dead ? dim : text)

        curY += metrics.px(18)

        // Subtitle: note or email — only when hasCardSubtitle agreed the
        // card reserves the line, else the text paints past the card's
        // bottom edge.
        if let note = row.deadNote {
            if let font = state.captionFont { SelectObject(dc, font) }
            let deadStr = (theme != nil && !theme!.plain && !theme!.deadMarker.isEmpty) ? "\(theme!.deadMarker) \(note)" : note
            drawClipped(dc, deadStr, x: rect.left + innerPad, y: curY,
                        maxWidth: innerW, color: dangerColor)
            curY += metrics.px(14)
        } else if !row.active, !row.email.isEmpty {
            if let font = state.captionFont { SelectObject(dc, font) }
            drawClipped(dc, row.email, x: rect.left + innerPad, y: curY,
                        maxWidth: innerW, color: faint)
            curY += metrics.px(14)
        }

        // Gauges stacked inside card
        curY += metrics.px(2)
        for gauge in row.gauges {
            paintGaugeBar(dc, gauge, x: rect.left + innerPad, top: curY, width: innerW,
                          metrics: metrics, state: state, theme: theme)
            curY += metrics.px(20)
        }
    }

    /// Single gauge bar spanning custom width, used in card layouts
    private static func paintGaugeBar(_ dc: HDC, _ gauge: FleetLayout.Gauge,
                                      x: Int32, top: Int32, width: Int32,
                                      metrics: Metrics, state: State,
                                      theme: RowTheme? = nil) {
        let tint = color(for: gauge, theme: theme)
        let percent = "\(Int(gauge.usedPct.rounded()))%"

        if let font = state.captionFont { SelectObject(dc, font) }
        let pctSize = textExtent(dc, percent)
        let pctX = max(x, x + width - pctSize.cx)
        draw(dc, percent, x: pctX, y: top,
             color: gauge.spent ? dangerColor : text)

        let maxLabelWidth = max(metrics.px(10), pctX - x - metrics.px(4))
        let displayLabel: String = {
            guard let theme, !theme.plain else { return gauge.label }
            switch gauge.label {
            case "5h": return theme.sessionLabel
            case "7d": return theme.weeklyLabel
            default: return theme.scopedPrefix + theme.modelName(gauge.label)
            }
        }()
        drawClipped(dc, displayLabel, x: x, y: top,
                    maxWidth: maxLabelWidth, color: tint)

        // The bar sits under label & pct
        let barTop = top + metrics.px(13)
        let barHeight = metrics.px(4)
        let barRect = RECT(left: x, top: barTop,
                           right: x + width, bottom: barTop + barHeight)
        fill(dc, barRect, track)

        let filled = Int32((Double(width) * gauge.remaining / 100).rounded())
        if filled > 0 {
            fill(dc, RECT(left: x, top: barTop, right: x + filled,
                          bottom: barTop + barHeight), tint)
        }

        if gauge.burnHeat > 0 || gauge.chill > 0 {
            let ahead = gauge.burnHeat > 0
            let markColor = ahead ? warmTint : coolTint
            let intensity = ahead ? gauge.burnHeat : gauge.chill
            let markWidth = max(metrics.px(2), Int32((Double(metrics.px(6)) * intensity).rounded()))
            let markLeft = min(x + width - markWidth, x + filled)
            fill(dc, RECT(left: max(x, markLeft), top: barTop - metrics.px(1),
                          right: max(x, markLeft) + markWidth,
                          bottom: barTop + barHeight + metrics.px(1)), markColor)
        }
    }

    private static func paintRow(_ dc: HDC, _ row: FleetLayout.Row, index: Int,
                                 top: Int32, width: Int32, metrics: Metrics, state: State,
                                 theme: RowTheme? = nil, slotWidth: Int32? = nil) {
        let rect = RECT(left: metrics.pad / 2, top: top,
                        right: width - metrics.pad / 2, bottom: top + metrics.rowHeight - 2)
        // Active reads as selected (the screenshot's blue band); hover is
        // a lighter plate so a click target is obvious.
        if row.active {
            fill(dc, rect, activeBg)
        } else if index == state.hotRow {
            fill(dc, rect, rowBg)
        }

        var x = metrics.pad
        let baseline = top + metrics.px(7)

        if let font = state.captionFont { SelectObject(dc, font) }
        let slotStr = slotString(for: row, theme: theme)
        draw(dc, slotStr, x: x, y: baseline + metrics.px(2),
             color: row.active ? text : faint)
        // Advance past the slot badge itself (the Mac's aligned slot
        // column) — a fixed width broke the moment a theme prefixed the
        // number ("agent-1" is 3× wider than the 18px that "1" needs).
        x += max(slotWidth ?? 0, textExtent(dc, slotStr).cx + metrics.px(8))

        if let font = state.bodyFont { SelectObject(dc, font) }
        // Truncate rather than overflow into the gauges.
        let name = row.disabled ? "\(row.name) (held)" : row.name
        drawClipped(dc, name, x: x, y: baseline, maxWidth: metrics.nameWidth - metrics.px(6),
                    color: row.dead ? dim : text)

        if let note = row.deadNote {
            if let font = state.captionFont { SelectObject(dc, font) }
            let deadStr = (theme != nil && !theme!.plain && !theme!.deadMarker.isEmpty) ? "\(theme!.deadMarker) \(note)" : note
            drawClipped(dc, deadStr, x: x, y: baseline + metrics.px(17),
                        maxWidth: metrics.nameWidth - metrics.px(6), color: dangerColor)
        } else if !row.active {
            if let font = state.captionFont { SelectObject(dc, font) }
            drawClipped(dc, row.email, x: x, y: baseline + metrics.px(17),
                        maxWidth: metrics.nameWidth - metrics.px(6), color: faint)
        }
        x += metrics.nameWidth

        for gauge in row.gauges {
            paintGauge(dc, gauge, x: x, top: baseline, metrics: metrics, state: state, theme: theme)
            x += metrics.barWidth + metrics.gaugeGap + metrics.px(52)
        }
    }

    /// Label, percentage, bar, reset caption — the Mac's `windowCell`
    /// laid out by hand.
    private static func paintGauge(_ dc: HDC, _ gauge: FleetLayout.Gauge,
                                   x: Int32, top: Int32, metrics: Metrics, state: State,
                                   theme: RowTheme? = nil) {
        let tint = color(for: gauge, theme: theme)
        let percent = "\(Int(gauge.usedPct.rounded()))%"

        // Percentage right-aligned against the bar width so the label and percentage
        // never collide regardless of how long the model name is (e.g. Gemini 3.1 Flash Image).
        if let font = state.bodyFont { SelectObject(dc, font) }
        let pctSize = textExtent(dc, percent)
        let pctX = max(x, x + metrics.barWidth - pctSize.cx)
        draw(dc, percent, x: pctX, y: top,
             color: gauge.spent ? dangerColor : text)

        if let font = state.captionFont { SelectObject(dc, font) }
        let maxLabelWidth = max(metrics.px(10), pctX - x - metrics.px(4))
        let displayLabel: String = {
            guard let theme, !theme.plain else { return gauge.label }
            switch gauge.label {
            case "5h": return theme.sessionLabel
            case "7d": return theme.weeklyLabel
            default: return theme.scopedPrefix + theme.modelName(gauge.label)
            }
        }()
        drawClipped(dc, displayLabel, x: x, y: top + metrics.px(2),
                    maxWidth: maxLabelWidth, color: tint)

        // The bar sits under the numbers, full width of the cell.
        let barTop = top + metrics.px(20)
        let barRect = RECT(left: x, top: barTop,
                           right: x + metrics.barWidth, bottom: barTop + metrics.barHeight)
        fill(dc, barRect, track)

        // Fill is REMAINING, not used — HP semantics, so a fresh account
        // shows a full bar (GaugeMath.remaining).
        let filled = Int32((Double(metrics.barWidth) * gauge.remaining / 100).rounded())
        if filled > 0 {
            fill(dc, RECT(left: x, top: barTop, right: x + filled,
                          bottom: barTop + metrics.barHeight), tint)
        }

        // Pace, shown statically: a tick where the burn SHOULD be, warm
        // when usage is ahead of the clock, cool when it is behind. The
        // Mac animates this; a repaint timer here would break CLAUDE.md's
        // idle-CPU rule, so the information is kept and the motion isn't.
        if gauge.burnHeat > 0 || gauge.chill > 0 {
            let ahead = gauge.burnHeat > 0
            let markColor = ahead ? warmTint : coolTint
            let intensity = ahead ? gauge.burnHeat : gauge.chill
            let markWidth = max(metrics.px(2), Int32((Double(metrics.px(10)) * intensity).rounded()))
            let markLeft = min(x + metrics.barWidth - markWidth, x + filled)
            fill(dc, RECT(left: max(x, markLeft), top: barTop - metrics.px(1),
                          right: max(x, markLeft) + markWidth,
                          bottom: barTop + metrics.barHeight + metrics.px(1)), markColor)
        }

        if let reset = gauge.reset {
            if let font = state.captionFont { SelectObject(dc, font) }
            drawClipped(dc, reset, x: x, y: barTop + metrics.barHeight + metrics.px(3),
                        maxWidth: metrics.barWidth + metrics.px(46), color: faint)
        }
    }

    // MARK: - GDI helpers

    private static func fill(_ dc: HDC, _ rect: RECT, _ color: COLORREF) {
        guard let brush = CreateSolidBrush(color) else { return }
        var r = rect
        FillRect(dc, &r, brush)
        DeleteObject(brush)
    }

    private static func draw(_ dc: HDC, _ text: String, x: Int32, y: Int32, color: COLORREF) {
        SetTextColor(dc, color)
        let wide = Array(text.utf16)
        var rect = RECT(left: x, top: y, right: x + 4000, bottom: y + 200)
        wide.withUnsafeBufferPointer { buf in
            _ = DrawTextW(dc, buf.baseAddress, Int32(buf.count), &rect,
                          UINT(DT_LEFT | DT_TOP | DT_SINGLELINE | DT_NOPREFIX))
        }
    }

    /// Single line, ellipsised at `maxWidth` — a long alias must not run
    /// under the gauges.
    private static func drawClipped(_ dc: HDC, _ text: String, x: Int32, y: Int32,
                                    maxWidth: Int32, color: COLORREF) {
        SetTextColor(dc, color)
        var wide = Array(text.utf16) + [0]
        var rect = RECT(left: x, top: y, right: x + maxWidth, bottom: y + 200)
        wide.withUnsafeMutableBufferPointer { buf in
            _ = DrawTextW(dc, buf.baseAddress, -1, &rect,
                          UINT(DT_LEFT | DT_TOP | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS))
        }
    }

    private static func drawWrapped(_ dc: HDC, _ text: String, _ rect: RECT, color: COLORREF) {
        SetTextColor(dc, color)
        var wide = Array(text.utf16) + [0]
        var r = rect
        wide.withUnsafeMutableBufferPointer { buf in
            _ = DrawTextW(dc, buf.baseAddress, -1, &r,
                          UINT(DT_LEFT | DT_TOP | DT_WORDBREAK | DT_NOPREFIX))
        }
    }

    private static func textExtent(_ dc: HDC, _ text: String) -> SIZE {
        var size = SIZE()
        let wide = Array(text.utf16)
        wide.withUnsafeBufferPointer { buf in
            GetTextExtentPoint32W(dc, buf.baseAddress, Int32(buf.count), &size)
        }
        return size
    }
}
