import Foundation
import InfinitusCore
import WinSDK

/// The tray's dark palette and the two things Win32 needs to actually
/// honour it: an immersive dark title bar, and `WM_CTLCOLOR*` answers
/// for the child controls.
///
/// Fixed dark rather than following the system theme — the Mac popup is
/// dark in both appearances, and a light variant would need its own
/// contrast pass to stay readable. One copy of the numbers, because the
/// account panel and the settings window sitting side by side in two
/// slightly different greys is worse than either.
enum WinDark {
    // MARK: palette (the account panel's, shared)

    static let bg = rgb(24, 24, 27)
    static let control = rgb(38, 38, 43)
    static let rowBg = rgb(32, 32, 36)
    static let activeBg = rgb(30, 58, 95)
    static let text = rgb(240, 240, 245)
    static let dim = rgb(150, 150, 160)
    static let faint = rgb(105, 105, 115)
    static let track = rgb(58, 58, 64)
    static let sessionColor = rgb(90, 190, 255)
    static let weeklyColor = rgb(170, 130, 255)
    static let scopedColor = rgb(255, 175, 90)
    static let dangerColor = rgb(255, 95, 95)
    static let warmTint = rgb(255, 140, 70)
    static let coolTint = rgb(90, 230, 190)
    /// A fleet header's provider name — brighter than its engine name,
    /// the same emphasis split the Mac's `FleetHeader` uses.
    static let headerText = rgb(200, 200, 210)

    // Settings additions
    /// Sidebar selection fill (the Mac's Color.accentColor row).
    static let selection = rgb(52, 92, 158)
    /// Hover plate for an unselected sidebar row.
    static let hover = rowBg
    /// Hairline between sidebar and content.
    static let separator = rgb(48, 48, 54)
    /// A destructive action's label ("Remove", "Forget key").
    static let destructive = dangerColor
    /// Live dot / success color (green)
    static let liveDot = rgb(46, 204, 113)

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> COLORREF {
        COLORREF(UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16))
    }

    /// Maps a theme color string — named or hex — to a COLORREF using ThemePalette.
    /// Named colors fall back to dim for secondary/gray and text for primary/unknown.
    static func themeColor(_ name: String) -> COLORREF {
        if let c = InfinitusCore.ThemePalette.rgb(name) {
            return rgb(Int(c.r), Int(c.g), Int(c.b))
        }
        let lower = name.lowercased()
        if lower == "secondary" || lower == "gray" {
            return dim
        }
        return text
    }

    // MARK: brushes
    //
    // A `WM_CTLCOLOR*` handler must return a brush that OUTLIVES the
    // message — returning a freshly created one and deleting it leaks or
    // paints garbage. These two are created once and live for the
    // process, which is what the docs' "static brush" means.

    private nonisolated(unsafe) static var bgBrushCache: HBRUSH?
    private nonisolated(unsafe) static var controlBrushCache: HBRUSH?
    private static let brushLock = NSLock()

    static var backgroundBrush: HBRUSH? {
        brushLock.lock(); defer { brushLock.unlock() }
        if bgBrushCache == nil { bgBrushCache = CreateSolidBrush(bg) }
        return bgBrushCache
    }

    static var controlBrush: HBRUSH? {
        brushLock.lock(); defer { brushLock.unlock() }
        if controlBrushCache == nil { controlBrushCache = CreateSolidBrush(control) }
        return controlBrushCache
    }

    // MARK: title bar

    /// Windows 10 before build 19041 uses attribute 19
    /// (`DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1`); 19041+ and Windows
    /// 11 use 20. Neither is exported to Swift by the SDK's dwmapi
    /// module, and asking for the wrong one just returns an error.
    private static let useImmersiveDarkMode: DWORD = 20
    private static let useImmersiveDarkModeBefore20H1: DWORD = 19

    /// Makes `hwnd`'s caption dark. A window's non-client area (caption,
    /// border, system buttons) is drawn by DWM, not by the app: painting
    /// the client area dark alone leaves a bright white caption bar
    /// sitting on top of it, which is what the account panel looked like
    /// (user 2026-09-05). Call after CreateWindowExW and before the
    /// window is shown — DWM re-renders the frame on the change, so
    /// applying it to a visible window flashes light first. On a build
    /// that knows neither attribute both calls fail and the caption
    /// stays light; nothing else changes.
    ///
    /// Swift imports Win32's `BOOL` as `WindowsBool` — the 4-byte C
    /// value DWM wants.
    static func applyTitleBar(to hwnd: HWND) {
        var enabled: WindowsBool = true
        let size = DWORD(MemoryLayout<WindowsBool>.size)
        let ok = withUnsafePointer(to: &enabled) { ptr in
            DwmSetWindowAttribute(hwnd, useImmersiveDarkMode, ptr, size)
        }
        if ok != S_OK {
            _ = withUnsafePointer(to: &enabled) { ptr in
                DwmSetWindowAttribute(hwnd, useImmersiveDarkModeBefore20H1, ptr, size)
            }
        }
    }

    // MARK: child controls

    /// The `WM_CTLCOLOR*` reply for a dark dialog: light text on the
    /// window's own background for labels and checkboxes, a slightly
    /// lifted plate for the fields you can type in. Returns nil for a
    /// message this doesn't handle so the caller falls through to
    /// `DefWindowProcW`.
    ///
    /// Push buttons go through `drawButton` instead (comctl32's themed
    /// renderer ignores the brush and paints its own light chrome, so
    /// they are `BS_OWNERDRAW`). Combo boxes keep the system look: their
    /// drop-down list is a separate themed window that owner-draw does
    /// not reach, and uxtheme — whose `SetWindowTheme` would — is not in
    /// the Windows Swift SDK's module map (verified 2026-09-05).
    static func controlColor(msg: UINT, wParam: WPARAM) -> LRESULT? {
        guard let dc = HDC(bitPattern: UInt(wParam)) else { return nil }
        switch Int32(bitPattern: msg) {
        case WM_CTLCOLORDLG, WM_CTLCOLORSTATIC, WM_CTLCOLORBTN:
            SetTextColor(dc, text)
            SetBkColor(dc, bg)
            SetBkMode(dc, TRANSPARENT)
            return brushResult(backgroundBrush)
        case WM_CTLCOLOREDIT, WM_CTLCOLORLISTBOX:
            SetTextColor(dc, text)
            SetBkColor(dc, control)
            return brushResult(controlBrush)
        default:
            return nil
        }
    }

    private static func brushResult(_ brush: HBRUSH?) -> LRESULT? {
        guard let brush else { return nil }
        return LRESULT(Int(bitPattern: UInt(bitPattern: Int(bitPattern: brush))))
    }

    // MARK: owner-drawn buttons

    /// A `WM_DRAWITEM` push button: dark plate, light label, a lighter
    /// plate while pressed or hot. Kept deliberately flat — this is a
    /// settings dialog, not the account panel, and a gradient would need
    /// its own contrast pass.
    ///
    /// The caller must have created the button `BS_OWNERDRAW`; a themed
    /// button never sends this message. Returns true when it drew, so the
    /// window procedure can answer TRUE as the message requires.
    static func drawButton(_ item: UnsafePointer<DRAWITEMSTRUCT>) -> Bool {
        let d = item.pointee
        guard d.CtlType == UINT(ODT_BUTTON), let dc = d.hDC else { return false }
        var rect = d.rcItem
        let pressed = (d.itemState & UINT(ODS_SELECTED)) != 0
        let focused = (d.itemState & UINT(ODS_FOCUS)) != 0
        let disabled = (d.itemState & UINT(ODS_DISABLED)) != 0

        if let brush = CreateSolidBrush(pressed ? activeBg : control) {
            FillRect(dc, &rect, brush)
            DeleteObject(brush)
        }
        // A hairline border so a button reads as a button on a flat dark
        // background; the focused one borrows the session blue.
        if let pen = CreatePen(PS_SOLID, 1, focused ? sessionColor : track),
           let brush = GetStockObject(NULL_BRUSH) {
            let oldPen = SelectObject(dc, pen)
            let oldBrush = SelectObject(dc, brush)
            Rectangle(dc, rect.left, rect.top, rect.right, rect.bottom)
            SelectObject(dc, oldPen)
            SelectObject(dc, oldBrush)
            DeleteObject(pen)
        }

        // The label is the control's own text, so the caller never has to
        // repeat it here.
        var buffer = [WCHAR](repeating: 0, count: 256)
        let length = GetWindowTextW(d.hwndItem, &buffer, 256)
        guard length > 0 else { return true }
        SetBkMode(dc, TRANSPARENT)
        SetTextColor(dc, disabled ? faint : text)
        _ = DrawTextW(dc, buffer, length, &rect,
                      UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))
        return true
    }

    /// Renders a tinted rounded tile with a glyph or fallback initial for sidebar rows.
    static func drawTile(dc: HDC, rect: RECT, tint: COLORREF, glyph: String, font: HFONT?) {
        guard let brush = CreateSolidBrush(tint) else { return }
        guard let nullPen = GetStockObject(NULL_PEN) else {
            DeleteObject(brush)
            return
        }
        let oldBrush = SelectObject(dc, brush)
        let oldPen = SelectObject(dc, nullPen)

        let radius: Int32 = 6
        RoundRect(dc, rect.left, rect.top, rect.right, rect.bottom, radius * 2, radius * 2)

        SelectObject(dc, oldPen)
        SelectObject(dc, oldBrush)
        DeleteObject(brush)

        let oldFont = font.map { SelectObject(dc, $0) }
        SetBkMode(dc, TRANSPARENT)
        SetTextColor(dc, rgb(255, 255, 255))
        var r = rect
        var glyphWide = Array(glyph.utf16) + [0]
        _ = DrawTextW(dc, &glyphWide, Int32(glyph.utf16.count), &r,
                      UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))
        if let oldFont { SelectObject(dc, oldFont) }
    }
}
