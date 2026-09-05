import Foundation
import InfinitusCore
import InfinitusWinUI
import WinSDK

/// Themes settings pane for Windows.
///
/// Features:
/// - 15 built-in themes (RowTheme.builtins) plus custom themes from %APPDATA%\Infinitus\themes.json.
/// - Owner-drawn GDI card gallery with preview rows.
/// - Custom theme starter template creation, file opening, and reloading.
/// - Writing selected theme to WinSettingsStore immediately and notifying FleetWindow if open.
public final class ThemesPane: SettingsPane {
    public static let descriptor = PaneDescriptor(
        id: "themes",
        title: "Themes",
        glyph: "\u{E790}", // Color icon
        tintRGB: (230, 140, 40), // Mac orange
        keywords: ["theme", "skin", "gallery", "community", "rpg", "row", "gamification"],
        section: .general
    )

    private var ctx: PaneContext?
    private var galleryCanvasHwnd: HWND?
    private var openFileBtnHwnd: HWND?
    private var reloadBtnHwnd: HWND?
    private var openGalleryBtnHwnd: HWND?

    private var builtinHeaderHwnd: HWND?
    private var customHeaderHwnd: HWND?
    private var customEmptyLabelHwnd: HWND?
    private var customHelpHwnd: HWND?
    private var communityHeaderHwnd: HWND?
    private var communityNoteHwnd: HWND?

    private var customThemes: [RowTheme] = []
    private var customParseError = false
    private var hoveredThemeId: String? = nil

    private enum Cmd {
        static let openFile: Int32 = 1
        static let reload: Int32 = 2
        static let openGallery: Int32 = 3
    }

    private static let canvasClassName = "InfinitusThemesCanvas"
    private nonisolated(unsafe) static var isCanvasRegistered = false

    public init() {}

    public func attach(host: HWND, ctx: PaneContext) {
        self.ctx = ctx
        let base = ctx.idBase
        Self.registerCanvasClassIfNeeded(instance: ctx.instance)

        builtinHeaderHwnd = PaneControls.label("Built-in", in: ctx, x: 0, y: 0, w: 0, h: 0, bold: true)

        let wideCanvas = Array(Self.canvasClassName.utf16) + [0]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        galleryCanvasHwnd = wideCanvas.withUnsafeBufferPointer { buf in
            CreateWindowExW(
                0,
                buf.baseAddress,
                nil,
                DWORD(WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN),
                0, 0, 100, 100,
                host,
                HMENU(bitPattern: 999),
                ctx.instance,
                selfPtr
            )
        }

        customHeaderHwnd = PaneControls.label("Your themes", in: ctx, x: 0, y: 0, w: 0, h: 0, bold: true)
        customEmptyLabelHwnd = PaneControls.label("None yet — themes.json skins appear here.", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)

        openFileBtnHwnd = PaneControls.button("Open themes file…", in: ctx, id: base + Cmd.openFile, x: 0, y: 0, w: 0, h: 0)
        reloadBtnHwnd = PaneControls.button("Reload", in: ctx, id: base + Cmd.reload, x: 0, y: 0, w: 0, h: 0)
        customHelpHwnd = PaneControls.label("Add your own skins — JSON, reloaded when this pane opens.", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)

        communityHeaderHwnd = PaneControls.label("Community", in: ctx, x: 0, y: 0, w: 0, h: 0, bold: true)
        communityNoteHwnd = PaneControls.label("Browse and contribute themes on GitHub.", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)
        openGalleryBtnHwnd = PaneControls.button("Open gallery…", in: ctx, id: base + Cmd.openGallery, x: 0, y: 0, w: 0, h: 0)

        loadCustomThemes()
    }

    public func layout(width: Int32, height: Int32) {
        guard let ctx else { return }
        let m = ctx.metrics
        let pad = m.pad
        let fullW = width - pad * 2

        var y = pad

        if let h = builtinHeaderHwnd { MoveWindow(h, pad, y, fullW, m.px(20), true) }
        y += m.px(24)

        // Built-in cards height
        let (cols, cardW) = calculateGrid(contentWidth: width, metrics: m)
        let builtinsCount = RowTheme.builtins.count
        let builtinRows = Int32(ceil(Double(builtinsCount) / Double(cols)))
        let cardH = m.px(120)
        let gap = m.px(10)
        let builtinGridH = builtinRows * (cardH + gap)

        if let h = galleryCanvasHwnd {
            MoveWindow(h, pad, y, fullW, builtinGridH, true)
            InvalidateRect(h, nil, false)
        }
        y += builtinGridH + gap * 2

        // SECTION: Your themes
        if let h = customHeaderHwnd { MoveWindow(h, pad, y, fullW, m.px(20), true) }
        y += m.px(24)

        if customParseError {
            PaneControls.setText(customEmptyLabelHwnd, "themes.json didn't parse — no custom themes loaded")
            if let h = customEmptyLabelHwnd {
                ShowWindow(h, SW_SHOW)
                MoveWindow(h, pad, y, fullW, m.px(18), true)
                y += m.px(22)
            }
        } else if customThemes.isEmpty {
            PaneControls.setText(customEmptyLabelHwnd, "None yet — themes.json skins appear here.")
            if let h = customEmptyLabelHwnd {
                ShowWindow(h, SW_SHOW)
                MoveWindow(h, pad, y, fullW, m.px(18), true)
                y += m.px(22)
            }
        } else {
            if let h = customEmptyLabelHwnd { ShowWindow(h, SW_HIDE) }
            // If there are custom themes, they render in custom card grid if present
        }

        if let of = openFileBtnHwnd, let rl = reloadBtnHwnd {
            MoveWindow(of, pad, y, m.px(140), m.buttonHeight, true)
            MoveWindow(rl, pad + m.px(150), y, m.px(80), m.buttonHeight, true)
        }
        y += m.buttonHeight + gap

        if let h = customHelpHwnd {
            MoveWindow(h, pad, y, fullW, m.px(18), true)
        }
        y += m.px(26) + gap

        // SECTION: Community
        if let h = communityHeaderHwnd { MoveWindow(h, pad, y, fullW, m.px(20), true) }
        y += m.px(24)

        if let cn = communityNoteHwnd, let og = openGalleryBtnHwnd {
            MoveWindow(cn, pad, y + m.px(4), m.px(260), m.px(20), true)
            MoveWindow(og, pad + m.px(270), y, m.px(120), m.buttonHeight, true)
        }
        y += m.buttonHeight + pad

        PaneHost.setContentHeight(ctx.host, y)
    }

    public func contentHeight(width: Int32) -> Int32 {
        guard let ctx else { return 800 }
        let m = ctx.metrics
        let (cols, _) = calculateGrid(contentWidth: width, metrics: m)
        let builtinsCount = RowTheme.builtins.count
        let builtinRows = Int32(ceil(Double(builtinsCount) / Double(cols)))
        let cardH = m.px(120)
        let gap = m.px(10)
        let gridH = builtinRows * (cardH + gap)
        return m.px(240) + gridH
    }

    public func activate() {
        loadCustomThemes()
        if let h = galleryCanvasHwnd {
            InvalidateRect(h, nil, false)
        }
    }

    public func deactivate() {}

    public func command(id: Int32, code: UINT, from: HWND?) -> Bool {
        guard let ctx else { return false }
        let rel = id - ctx.idBase

        switch rel {
        case Cmd.openFile:
            openThemesFile()
            return true
        case Cmd.reload:
            loadCustomThemes()
            if let h = galleryCanvasHwnd { InvalidateRect(h, nil, false) }
            return true
        case Cmd.openGallery:
            let urlWide = Array("https://github.com/deathemperor/infinitus/tree/main/themes".utf16) + [0]
            let openWide = Array("open".utf16) + [0]
            ShellExecuteW(nil, openWide, urlWide, nil, nil, SW_SHOWNORMAL)
            return true
        default:
            return false
        }
    }

    public func notify(_ header: UnsafePointer<NMHDR>) -> Bool { false }

    public func drawItem(_ item: UnsafePointer<DRAWITEMSTRUCT>) -> Bool { false }

    // MARK: - Custom Themes File Handling
    private func loadCustomThemes() {
        let fileURL = WinSettingsStore.windowsThemesURL
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: fileURL) {
                if let decoded = try? JSONDecoder().decode([RowTheme].self, from: data) {
                    customThemes = decoded
                    customParseError = false
                } else {
                    customThemes = []
                    customParseError = true
                }
            } else {
                customThemes = []
                customParseError = false
            }
        } else {
            customThemes = []
            customParseError = false
        }
        if let host = ctx?.host, let width = (ctx?.metrics.px(980)) {
            var rc = RECT()
            GetClientRect(host, &rc)
            let w = rc.right - rc.left
            layout(width: w > 0 ? w : width, height: rc.bottom - rc.top)
        }
    }

    private func openThemesFile() {
        let fileURL = WinSettingsStore.windowsThemesURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? RowTheme.templateJSON.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        let pathWide = Array(fileURL.path.utf16) + [0]
        let openWide = Array("open".utf16) + [0]
        ShellExecuteW(nil, openWide, pathWide, nil, nil, SW_SHOWNORMAL)
        loadCustomThemes()
    }

    // MARK: - Canvas & Cards Drawing
    private func calculateGrid(contentWidth: Int32, metrics: Metrics) -> (columns: Int32, cardWidth: Int32) {
        let pad = metrics.pad
        let availW = max(metrics.px(300), contentWidth - pad * 2)
        let nominalCardW = metrics.px(300)
        let gap = metrics.px(10)
        let cols = max(1, (availW + gap) / (nominalCardW + gap))
        let cardW = (availW - gap * (cols - 1)) / cols
        return (cols, cardW)
    }

    private static func registerCanvasClassIfNeeded(instance: HMODULE?) {
        guard !isCanvasRegistered else { return }
        isCanvasRegistered = true

        let wide = Array(canvasClassName.utf16) + [0]
        wide.withUnsafeBufferPointer { buf in
            var wc = WNDCLASSEXW()
            wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            wc.lpfnWndProc = canvasWndProc
            wc.hInstance = instance
            wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            wc.hbrBackground = WinDark.backgroundBrush
            wc.lpszClassName = buf.baseAddress
            RegisterClassExW(&wc)
        }
    }

    /// Mouse coordinates are SIGNED 16-bit words in lParam; `DWORD(lParam)`
    /// traps once lParam goes negative (pointer dragged above/left of the
    /// client area).
    private static func mouseX(_ l: LPARAM) -> Int32 { Int32(Int16(truncatingIfNeeded: l)) }
    private static func mouseY(_ l: LPARAM) -> Int32 { Int32(Int16(truncatingIfNeeded: l >> 16)) }

    private static let canvasWndProc: WNDPROC = { hwnd, msg, wParam, lParam in
        guard let hwnd else { return DefWindowProcW(hwnd, msg, wParam, lParam) }
        let msgInt = Int32(bitPattern: msg)

        switch msgInt {
        case WM_NCCREATE:
            let cs = UnsafePointer<CREATESTRUCTW>(bitPattern: Int(lParam))!
            let ptr = cs.pointee.lpCreateParams
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, LONG_PTR(Int(bitPattern: ptr)))
            return 1

        case WM_ERASEBKGND:
            return 1

        case WM_PAINT:
            let raw = GetWindowLongPtrW(hwnd, GWLP_USERDATA)
            guard raw != 0 else { return 0 }
            let pane = Unmanaged<ThemesPane>.fromOpaque(UnsafeMutableRawPointer(bitPattern: Int(raw))!).takeUnretainedValue()
            pane.paintCanvas(hwnd: hwnd)
            return 0

        case WM_MOUSEMOVE:
            let raw = GetWindowLongPtrW(hwnd, GWLP_USERDATA)
            guard raw != 0 else { return 0 }
            let pane = Unmanaged<ThemesPane>.fromOpaque(UnsafeMutableRawPointer(bitPattern: Int(raw))!).takeUnretainedValue()
            let x = mouseX(lParam)
            let y = mouseY(lParam)
            pane.handleMouseMove(hwnd: hwnd, x: x, y: y)
            return 0

        case WM_MOUSELEAVE:
            let raw = GetWindowLongPtrW(hwnd, GWLP_USERDATA)
            guard raw != 0 else { return 0 }
            let pane = Unmanaged<ThemesPane>.fromOpaque(UnsafeMutableRawPointer(bitPattern: Int(raw))!).takeUnretainedValue()
            pane.hoveredThemeId = nil
            InvalidateRect(hwnd, nil, false)
            return 0

        case WM_LBUTTONUP:
            let raw = GetWindowLongPtrW(hwnd, GWLP_USERDATA)
            guard raw != 0 else { return 0 }
            let pane = Unmanaged<ThemesPane>.fromOpaque(UnsafeMutableRawPointer(bitPattern: Int(raw))!).takeUnretainedValue()
            let x = mouseX(lParam)
            let y = mouseY(lParam)
            pane.handleClick(hwnd: hwnd, x: x, y: y)
            return 0

        default:
            return DefWindowProcW(hwnd, msg, wParam, lParam)
        }
    }

    private func handleMouseMove(hwnd: HWND, x: Int32, y: Int32) {
        var tme = TRACKMOUSEEVENT()
        tme.cbSize = DWORD(MemoryLayout<TRACKMOUSEEVENT>.size)
        tme.dwFlags = DWORD(TME_LEAVE)
        tme.hwndTrack = hwnd
        TrackMouseEvent(&tme)

        let hit = cardAt(x: x, y: y)
        if hit != hoveredThemeId {
            hoveredThemeId = hit
            InvalidateRect(hwnd, nil, false)
        }
    }

    private func handleClick(hwnd: HWND, x: Int32, y: Int32) {
        guard let themeId = cardAt(x: x, y: y) else { return }
        _ = try? WinSettingsStore.update { $0.gamificationStyle = themeId }
        InvalidateRect(hwnd, nil, false)
        FleetWindow.refresh()
    }

    private func cardAt(x: Int32, y: Int32) -> String? {
        guard let ctx else { return nil }
        var rc = RECT()
        guard let canvas = galleryCanvasHwnd else { return nil }
        GetClientRect(canvas, &rc)
        let fullW = rc.right - rc.left
        let m = ctx.metrics
        let (cols, cardW) = calculateGrid(contentWidth: fullW + m.pad * 2, metrics: m)
        let cardH = m.px(120)
        let gap = m.px(10)

        let allThemes = RowTheme.builtins + customThemes
        for (index, theme) in allThemes.enumerated() {
            let row = Int32(index) / cols
            let col = Int32(index) % cols
            let cardX = col * (cardW + gap)
            let cardY = row * (cardH + gap)
            if x >= cardX && x < cardX + cardW && y >= cardY && y < cardY + cardH {
                return theme.id
            }
        }
        return nil
    }

    private func paintCanvas(hwnd: HWND) {
        guard let ctx else { return }
        var ps = PAINTSTRUCT()
        guard let hdc = BeginPaint(hwnd, &ps) else { return }
        defer { EndPaint(hwnd, &ps) }

        var rc = RECT()
        GetClientRect(hwnd, &rc)
        let fullW = rc.right - rc.left
        let fullH = rc.bottom - rc.top

        guard let memDC = CreateCompatibleDC(hdc) else { return }
        defer { DeleteDC(memDC) }
        guard let hbm = CreateCompatibleBitmap(hdc, fullW, fullH) else { return }
        defer { DeleteObject(hbm) }
        let oldBmp = SelectObject(memDC, hbm)
        defer { if let oldBmp { SelectObject(memDC, oldBmp) } }

        if let bg = WinDark.backgroundBrush {
            FillRect(memDC, &rc, bg)
        }

        let m = ctx.metrics
        let (cols, cardW) = calculateGrid(contentWidth: fullW + m.pad * 2, metrics: m)
        let cardH = m.px(120)
        let gap = m.px(10)

        let selectedTheme = WinSettingsStore.load().gamificationStyle
        let allThemes = RowTheme.builtins + customThemes

        for (index, theme) in allThemes.enumerated() {
            let row = Int32(index) / cols
            let col = Int32(index) % cols
            let cardX = col * (cardW + gap)
            let cardY = row * (cardH + gap)
            let cardRc = RECT(left: cardX, top: cardY, right: cardX + cardW, bottom: cardY + cardH)

            paintCard(dc: memDC, rect: cardRc, theme: theme,
                      selected: theme.id == selectedTheme,
                      hovered: theme.id == hoveredThemeId,
                      metrics: m)
        }

        BitBlt(hdc, 0, 0, fullW, fullH, memDC, 0, 0, SRCCOPY)
    }

    private func paintCard(dc: HDC, rect: RECT, theme: RowTheme,
                           selected: Bool, hovered: Bool, metrics: Metrics) {
        var r = rect

        // Background
        let plateColor = hovered ? WinDark.hover : WinDark.rowBg
        if let brush = CreateSolidBrush(plateColor) {
            FillRect(dc, &r, brush)
            DeleteObject(brush)
        }

        // Border: 2px sessionColor when selected, 1px track when unselected
        let borderColor = selected ? WinDark.sessionColor : WinDark.track
        let borderWidth = selected ? metrics.px(2) : metrics.px(1)
        drawBorder(dc: dc, rect: r, color: borderColor, width: borderWidth)

        let innerPad = metrics.px(8)
        let contentW = rect.right - rect.left - innerPad * 2
        var y = rect.top + innerPad

        SetBkMode(dc, TRANSPARENT)

        if theme.plain {
            // Off / Plain theme: 3 text lines
            let oldFont = ctx?.captionFont.map { SelectObject(dc, $0) }
            SetTextColor(dc, WinDark.text)

            let l1 = "\(theme.sessionLabel) 21% 4h 8m (22:09)"
            drawTextLine(dc: dc, text: l1, x: rect.left + innerPad, y: y, maxW: contentW)
            y += metrics.px(18)

            let l2 = "\(theme.weeklyLabel) 68% 5d 9h (Sep 4 03:59)"
            drawTextLine(dc: dc, text: l2, x: rect.left + innerPad, y: y, maxW: contentW)
            y += metrics.px(18)

            let l3 = "\(theme.creditLabel) 74% · \(theme.scopedPrefix)\(theme.modelName("Fable")) 74%"
            drawTextLine(dc: dc, text: l3, x: rect.left + innerPad, y: y, maxW: contentW)
            y += metrics.px(22)

            if let oldFont { SelectObject(dc, oldFont) }
        } else {
            // 3 Rows with Gauges: session, weekly, credit/model
            let rowH = metrics.px(18)

            // Row 1: Session
            paintCardGaugeRow(dc: dc, label: theme.sessionLabel, labelColor: WinDark.themeColor(theme.sessionColor),
                              remaining: 79, barColor: WinDark.themeColor(theme.sessionColor),
                              caption: "4h 8m (22:09)",
                              x: rect.left + innerPad, y: y, width: contentW, metrics: metrics)
            y += rowH

            // Row 2: Weekly
            paintCardGaugeRow(dc: dc, label: theme.weeklyLabel, labelColor: WinDark.themeColor(theme.weeklyColor),
                              remaining: 32, barColor: WinDark.themeColor(theme.weeklyColor),
                              caption: theme.revivePrefix + "5d 9h (Sep 4 03:59)",
                              x: rect.left + innerPad, y: y, width: contentW, metrics: metrics)
            y += rowH

            // Row 3: Credit
            let modelAlias = theme.scopedPrefix + theme.modelName("Fable")
            let cashText = "\(theme.cashIcon)1,131"
            paintCardGaugeRow(dc: dc, label: theme.creditLabel, labelColor: WinDark.themeColor(theme.creditColor),
                              remaining: 26, barColor: WinDark.themeColor(theme.creditColor),
                              caption: "\(modelAlias) · \(cashText)",
                              x: rect.left + innerPad, y: y, width: contentW, metrics: metrics)
            y += rowH + metrics.px(4)
        }

        // Bottom row: Radio marker + Theme Name
        let radioGlyph = selected ? "\u{25C9}" : "\u{25CB}" // ◉ or ○
        let radioColor = selected ? WinDark.sessionColor : WinDark.dim
        SetTextColor(dc, radioColor)
        let oldFont = ctx?.font.map { SelectObject(dc, $0) }

        var radioWide = Array(radioGlyph.utf16) + [0]
        var radioRc = RECT(left: rect.left + innerPad, top: y, right: rect.left + innerPad + metrics.px(16), bottom: rect.bottom - innerPad)
        _ = DrawTextW(dc, &radioWide, Int32(radioGlyph.utf16.count), &radioRc, UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))

        SetTextColor(dc, WinDark.text)
        let nameX = radioRc.right + metrics.px(6)
        var nameWide = Array(theme.name.utf16) + [0]
        var nameRc = RECT(left: nameX, top: y, right: rect.right - innerPad, bottom: rect.bottom - innerPad)
        _ = DrawTextW(dc, &nameWide, Int32(theme.name.utf16.count), &nameRc, UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS))

        if let oldFont { SelectObject(dc, oldFont) }
    }

    private func paintCardGaugeRow(dc: HDC, label: String, labelColor: COLORREF,
                                   remaining: Double, barColor: COLORREF,
                                   caption: String,
                                   x: Int32, y: Int32, width: Int32, metrics: Metrics) {
        let labelW = metrics.px(28)
        let barW = metrics.px(80)
        let barH = metrics.px(6)
        let oldFont = ctx?.captionFont.map { SelectObject(dc, $0) }

        // Label
        SetTextColor(dc, labelColor)
        var lblWide = Array(label.utf16) + [0]
        var lblRc = RECT(left: x, top: y, right: x + labelW, bottom: y + metrics.px(16))
        _ = DrawTextW(dc, &lblWide, Int32(label.utf16.count), &lblRc, UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))

        // Bar Track & Fill
        let barX = x + labelW + metrics.px(4)
        let barY = y + (metrics.px(16) - barH) / 2
        let barRc = RECT(left: barX, top: barY, right: barX + barW, bottom: barY + barH)
        paintBar(dc: dc, rect: barRc, remaining: remaining, color: barColor)

        // Caption
        SetTextColor(dc, WinDark.dim)
        let capX = barX + barW + metrics.px(6)
        var capWide = Array(caption.utf16) + [0]
        var capRc = RECT(left: capX, top: y, right: x + width, bottom: y + metrics.px(16))
        _ = DrawTextW(dc, &capWide, Int32(caption.utf16.count), &capRc, UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS))

        if let oldFont { SelectObject(dc, oldFont) }
    }

    private func paintBar(dc: HDC, rect: RECT, remaining: Double, color: COLORREF) {
        if let trackBrush = CreateSolidBrush(WinDark.track) {
            var r = rect
            FillRect(dc, &r, trackBrush)
            DeleteObject(trackBrush)
        }
        let totalW = rect.right - rect.left
        let filledW = Int32((Double(totalW) * remaining / 100.0).rounded())
        if filledW > 0 {
            var fillRc = rect
            fillRc.right = min(rect.right, rect.left + filledW)
            if let fillBrush = CreateSolidBrush(color) {
                FillRect(dc, &fillRc, fillBrush)
                DeleteObject(fillBrush)
            }
        }
    }

    private func drawBorder(dc: HDC, rect: RECT, color: COLORREF, width: Int32) {
        guard let brush = CreateSolidBrush(color) else { return }
        defer { DeleteObject(brush) }
        var top = RECT(left: rect.left, top: rect.top, right: rect.right, bottom: rect.top + width)
        var bottom = RECT(left: rect.left, top: rect.bottom - width, right: rect.right, bottom: rect.bottom)
        var left = RECT(left: rect.left, top: rect.top, right: rect.left + width, bottom: rect.bottom)
        var right = RECT(left: rect.right - width, top: rect.top, right: rect.right, bottom: rect.bottom)
        FillRect(dc, &top, brush)
        FillRect(dc, &bottom, brush)
        FillRect(dc, &left, brush)
        FillRect(dc, &right, brush)
    }

    private func drawTextLine(dc: HDC, text: String, x: Int32, y: Int32, maxW: Int32) {
        var wide = Array(text.utf16) + [0]
        var rect = RECT(left: x, top: y, right: x + maxW, bottom: y + 20)
        _ = DrawTextW(dc, &wide, Int32(text.utf16.count), &rect, UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS))
    }
}
