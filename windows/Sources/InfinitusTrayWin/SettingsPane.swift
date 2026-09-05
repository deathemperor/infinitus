import Foundation
import InfinitusCore
import InfinitusWinUI
import WinSDK

/// Everything a pane needs from the shell. Handed to `attach`; panes
/// hold it for the window's lifetime.
public final class PaneContext {
    public let host: HWND                 // the pane's own WS_CHILD container
    public let shell: HWND                // the settings window, for PostMessageW
    public let instance: HMODULE?
    public var metrics: Metrics           // re-made on WM_DPICHANGED
    public var font: HFONT?               // Segoe UI, body
    public var boldFont: HFONT?
    public var captionFont: HFONT?        // smaller, for help text
    public let idBase: Int32              // this pane's 512-id block
    public let paneIndex: Int32

    private nonisolated(unsafe) static var globalGeneration: UInt64 = 0
    private static let genLock = NSLock()
    private var paneGeneration: UInt64 = 0

    /// Controls a pane re-creates on every `layout` (section headers, help
    /// text, per-row labels). `layout` runs on EVERY `WM_SIZE`, so without
    /// a recycle these accumulate one HWND per header per resize tick and
    /// exhaust the process's 10k USER-handle quota during a single window
    /// drag. Panes call `recycleTransients()` first thing in `layout`.
    private var transientControls: [HWND] = []

    public func registerTransient(_ hwnd: HWND?) {
        guard let hwnd else { return }
        transientControls.append(hwnd)
    }

    public func recycleTransients() {
        for h in transientControls { DestroyWindow(h) }
        transientControls.removeAll(keepingCapacity: true)
    }

    public init(
        host: HWND,
        shell: HWND,
        instance: HMODULE?,
        metrics: Metrics,
        font: HFONT?,
        boldFont: HFONT?,
        captionFont: HFONT?,
        idBase: Int32,
        paneIndex: Int32
    ) {
        self.host = host
        self.shell = shell
        self.instance = instance
        self.metrics = metrics
        self.font = font
        self.boldFont = boldFont
        self.captionFont = captionFont
        self.idBase = idBase
        self.paneIndex = paneIndex
    }

    /// Ask the shell to post `WM_APP_PANE_RESULT` back to this pane once
    /// `work` finishes on a worker thread. The generation is bumped only
    /// by `invalidateResults()` (which `deactivate` drives), so a result
    /// issued before the pane was hidden is dropped while two requests in
    /// flight AT THE SAME TIME both survive — stamping a new generation
    /// per request made the second call silently cancel the first.
    public func async<T: Sendable>(
        _ work: @escaping @Sendable () -> T,
        then apply: @escaping (T) -> Void
    ) {
        Self.genLock.lock()
        let gen = self.paneGeneration
        Self.genLock.unlock()

        let pIdx = self.paneIndex
        let shellHwnd = self.shell

        Thread.detachNewThread {
            let result = work()
            let thunk: @Sendable () -> Void = {
                apply(result)
            }
            let slot = SettingsShell.storeAsyncSlot(paneIndex: pIdx, generation: gen, thunk: thunk)
            PostMessageW(shellHwnd, SettingsShell.WM_APP_PANE_RESULT, WPARAM(UInt(pIdx)), LPARAM(slot))
        }
    }

    public func currentGeneration() -> UInt64 {
        Self.genLock.lock()
        defer { Self.genLock.unlock() }
        return paneGeneration
    }

    /// Every result already in flight is stale from here on. The shell
    /// calls this when a pane is hidden.
    public func invalidateResults() {
        Self.genLock.lock()
        Self.globalGeneration += 1
        self.paneGeneration = Self.globalGeneration
        Self.genLock.unlock()
    }
}

/// One settings pane. Implementations live in their own file and own
/// their child controls; the shell owns the container HWND, the font and
/// the metrics.
public protocol SettingsPane: AnyObject {
    /// Sidebar row: title, glyph, tint, and the words the search box
    /// matches (the Mac's `SettingsTab.keywords`).
    static var descriptor: PaneDescriptor { get }

    /// Create the pane's child controls inside `host`. Called once, from
    /// the shell's WM_CREATE. `ctx` carries the shared font handles and
    /// the DPI metrics.
    func attach(host: HWND, ctx: PaneContext)

    /// Re-place every control for a new content size. Called on resize,
    /// on WM_DPICHANGED, and once right after `attach`.
    func layout(width: Int32, height: Int32)

    /// The pane became visible. Load/refresh here, NEVER in `attach` —
    /// 14 panes each shelling out at window-open would take seconds.
    func activate()

    /// The pane was hidden. Stop timers; keep state.
    func deactivate()

    /// WM_COMMAND from one of the pane's own controls. Return true when
    /// handled so the shell can stop looking.
    func command(id: Int32, code: UINT, from: HWND?) -> Bool

    /// WM_NOTIFY (list views, up-downs) — same contract.
    func notify(_ header: UnsafePointer<NMHDR>) -> Bool

    /// WM_DRAWITEM for a pane-owned owner-draw control (theme tiles,
    /// chart canvases). Return true when drawn.
    func drawItem(_ item: UnsafePointer<DRAWITEMSTRUCT>) -> Bool

    /// The pane's natural content height at `width` — drives the
    /// container's scroll range.
    func contentHeight(width: Int32) -> Int32
}

/// A pane's WS_CHILD container with vertical scrolling. Panes place
/// controls in CONTENT coordinates (0 = top of the content); the host
/// offsets them. A pane never sees the scroll position.
public enum PaneHost {
    private static let className = "InfinitusPaneHost"
    private nonisolated(unsafe) static var isRegistered = false

    private final class HostState {
        var contentHeight: Int32 = 0
        var scrollY: Int32 = 0
        var metrics: Metrics

        init(metrics: Metrics) {
            self.metrics = metrics
        }
    }

    private static func registerClassIfNeeded(instance: HMODULE?) {
        guard !isRegistered else { return }
        isRegistered = true

        let wideName = Array(className.utf16) + [0]
        wideName.withUnsafeBufferPointer { buf in
            var wc = WNDCLASSEXW()
            wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            wc.lpfnWndProc = hostWndProc
            wc.hInstance = instance
            wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            wc.hbrBackground = WinDark.backgroundBrush
            wc.lpszClassName = buf.baseAddress
            RegisterClassExW(&wc)
        }
    }

    public static func create(parent: HWND, id: Int32, metrics: Metrics, instance: HMODULE?) -> HWND? {
        registerClassIfNeeded(instance: instance)

        let state = HostState(metrics: metrics)
        let wideName = Array(className.utf16) + [0]
        let statePtr = Unmanaged.passRetained(state).toOpaque()

        let hwnd = wideName.withUnsafeBufferPointer { buf in
            CreateWindowExW(
                0,
                buf.baseAddress,
                nil,
                DWORD(WS_CHILD | WS_CLIPCHILDREN | WS_VSCROLL),
                0, 0, 100, 100,
                parent,
                HMENU(bitPattern: Int(id)),
                instance,
                statePtr
            )
        }
        return hwnd
    }

    public static func setContentHeight(_ host: HWND, _ height: Int32) {
        guard let state = getState(host) else { return }
        state.contentHeight = height
        updateScroll(host, state: state)
    }

    private static func getState(_ hwnd: HWND) -> HostState? {
        let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA)
        guard ptr != 0 else { return nil }
        return Unmanaged<HostState>.fromOpaque(UnsafeMutableRawPointer(bitPattern: Int(ptr))!).takeUnretainedValue()
    }

    private static func updateScroll(_ hwnd: HWND, state: HostState) {
        var rc = RECT()
        GetClientRect(hwnd, &rc)
        let viewportH = rc.bottom - rc.top

        let (newOffset, maxOffset) = SettingsCatalogWin.clampScroll(
            offset: state.scrollY,
            contentHeight: state.contentHeight,
            viewportHeight: viewportH
        )

        let delta = newOffset - state.scrollY
        if delta != 0 {
            ScrollWindowEx(hwnd, 0, -delta, nil, nil, nil, nil, UINT(SW_SCROLLCHILDREN | SW_INVALIDATE))
            state.scrollY = newOffset
        }

        var si = SCROLLINFO()
        si.cbSize = UINT(MemoryLayout<SCROLLINFO>.size)
        si.fMask = UINT(SIF_RANGE | SIF_PAGE | SIF_POS)
        si.nMin = 0
        si.nMax = max(0, state.contentHeight - 1)
        si.nPage = UINT(max(0, viewportH))
        si.nPos = state.scrollY
        SetScrollInfo(hwnd, Int32(SB_VERT), &si, true)
    }

    public static func scrollByLines(_ hwnd: HWND, lines: Int32) {
        guard let state = getState(hwnd) else { return }
        var rc = RECT()
        GetClientRect(hwnd, &rc)
        let viewportH = rc.bottom - rc.top
        let linePx = state.metrics.px(20)
        let target = state.scrollY + lines * linePx
        let (clamped, _) = SettingsCatalogWin.clampScroll(
            offset: target,
            contentHeight: state.contentHeight,
            viewportHeight: viewportH
        )
        let delta = clamped - state.scrollY
        if delta != 0 {
            ScrollWindowEx(hwnd, 0, -delta, nil, nil, nil, nil, UINT(SW_SCROLLCHILDREN | SW_INVALIDATE))
            state.scrollY = clamped

            var si = SCROLLINFO()
            si.cbSize = UINT(MemoryLayout<SCROLLINFO>.size)
            si.fMask = UINT(SIF_POS)
            si.nPos = state.scrollY
            SetScrollInfo(hwnd, Int32(SB_VERT), &si, true)
        }
    }

    private static let hostWndProc: WNDPROC = { hwnd, msg, wParam, lParam in
        guard let hwnd else { return DefWindowProcW(hwnd, msg, wParam, lParam) }
        switch Int32(bitPattern: msg) {
        case WM_NCCREATE:
            let cs = UnsafePointer<CREATESTRUCTW>(bitPattern: Int(lParam))!
            let ptr = cs.pointee.lpCreateParams
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, LONG_PTR(Int(bitPattern: ptr)))
            return 1

        case WM_SIZE:
            if let state = getState(hwnd) {
                updateScroll(hwnd, state: state)
            }
            return 0

        case WM_VSCROLL:
            guard let state = getState(hwnd) else { return 0 }
            let request = UInt16(truncatingIfNeeded: wParam)
            var rc = RECT()
            GetClientRect(hwnd, &rc)
            let viewportH = rc.bottom - rc.top
            let linePx = state.metrics.px(20)

            var target = state.scrollY
            switch Int32(request) {
            case SB_LINEUP: target -= linePx
            case SB_LINEDOWN: target += linePx
            case SB_PAGEUP: target -= max(linePx, viewportH - linePx)
            case SB_PAGEDOWN: target += max(linePx, viewportH - linePx)
            case SB_THUMBTRACK, SB_THUMBPOSITION:
                var si = SCROLLINFO()
                si.cbSize = UINT(MemoryLayout<SCROLLINFO>.size)
                si.fMask = UINT(SIF_TRACKPOS)
                GetScrollInfo(hwnd, Int32(SB_VERT), &si)
                target = si.nTrackPos
            default: break
            }

            let (clamped, _) = SettingsCatalogWin.clampScroll(
                offset: target,
                contentHeight: state.contentHeight,
                viewportHeight: viewportH
            )
            let delta = clamped - state.scrollY
            if delta != 0 {
                ScrollWindowEx(hwnd, 0, -delta, nil, nil, nil, nil, UINT(SW_SCROLLCHILDREN | SW_INVALIDATE))
                state.scrollY = clamped

                var si = SCROLLINFO()
                si.cbSize = UINT(MemoryLayout<SCROLLINFO>.size)
                si.fMask = UINT(SIF_POS)
                si.nPos = state.scrollY
                SetScrollInfo(hwnd, Int32(SB_VERT), &si, true)
            }
            return 0

        case WM_MOUSEWHEEL:
            var wheelLines: UINT = 3
            SystemParametersInfoW(UINT(SPI_GETWHEELSCROLLLINES), 0, &wheelLines, 0)
            let delta = GET_WHEEL_DELTA_WPARAM(wParam)
            let notches = Int32(delta) / WHEEL_DELTA
            let lines = -notches * Int32(wheelLines)
            scrollByLines(hwnd, lines: lines)
            return 0

        case WM_COMMAND, WM_NOTIFY, WM_DRAWITEM:
            let parent = GetParent(hwnd)
            if let parent {
                return SendMessageW(parent, msg, wParam, lParam)
            }
            return 0

        case WM_CTLCOLORSTATIC, WM_CTLCOLOREDIT, WM_CTLCOLORBTN, WM_CTLCOLORLISTBOX:
            let parent = GetParent(hwnd)
            if let parent {
                return SendMessageW(parent, msg, wParam, lParam)
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam)

        case WM_DESTROY:
            let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA)
            if ptr != 0 {
                Unmanaged<HostState>.fromOpaque(UnsafeMutableRawPointer(bitPattern: Int(ptr))!).release()
                SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0)
            }
            return 0

        default:
            return DefWindowProcW(hwnd, msg, wParam, lParam)
        }
    }
}

/// `DWORD(wParam)` traps: wParam is 64-bit and WM_MOUSEWHEEL packs the
/// key-state flags into the low word, so the value routinely exceeds
/// UInt32.max. Truncate, never convert.
private func GET_WHEEL_DELTA_WPARAM(_ wParam: WPARAM) -> Int16 { Int16(truncatingIfNeeded: wParam >> 16) }

/// Shared control helpers, lifted from SettingsWindow and made reusable.
public enum PaneControls {
    private static let staticClass = Array("STATIC".utf16) + [0]
    private static let buttonClass = Array("BUTTON".utf16) + [0]
    private static let editClass = Array("EDIT".utf16) + [0]
    private static let comboClass = Array("COMBOBOX".utf16) + [0]

    /// `transient: true` for a control re-created on every `layout` —
    /// the pane recycles it instead of leaking one HWND per resize tick.
    public static func label(
        _ text: String, in ctx: PaneContext,
        x: Int32, y: Int32, w: Int32, h: Int32,
        bold: Bool = false, caption: Bool = false,
        color: COLORREF? = nil, transient: Bool = false
    ) -> HWND? {
        let textWide = Array(text.utf16) + [0]
        let hwnd = staticClass.withUnsafeBufferPointer { sc in
            textWide.withUnsafeBufferPointer { tw in
                CreateWindowExW(
                    0, sc.baseAddress, tw.baseAddress,
                    DWORD(WS_CHILD | WS_VISIBLE | SS_LEFT),
                    x, y, w, h, ctx.host, nil, ctx.instance, nil
                )
            }
        }
        guard let hwnd else { return nil }
        let hfont = bold ? ctx.boldFont : (caption ? ctx.captionFont : ctx.font)
        SendMessageW(hwnd, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: hfont)), LPARAM(1))
        if transient { ctx.registerTransient(hwnd) }
        return hwnd
    }

    public static func edit(
        in ctx: PaneContext, id: Int32,
        x: Int32, y: Int32, w: Int32, h: Int32,
        password: Bool = false, multiline: Bool = false,
        readOnly: Bool = false
    ) -> HWND? {
        var style = DWORD(WS_CHILD | WS_VISIBLE | WS_TABSTOP)
        if password { style |= DWORD(ES_PASSWORD) }
        if multiline {
            style |= DWORD(ES_MULTILINE | ES_AUTOVSCROLL | WS_VSCROLL)
        } else {
            style |= DWORD(ES_AUTOHSCROLL)
        }
        if readOnly { style |= DWORD(ES_READONLY) }

        let hwnd = editClass.withUnsafeBufferPointer { ec in
            CreateWindowExW(
                DWORD(WS_EX_CLIENTEDGE), ec.baseAddress, nil,
                style,
                x, y, w, h, ctx.host, HMENU(bitPattern: Int(id)), ctx.instance, nil
            )
        }
        guard let hwnd else { return nil }
        SendMessageW(hwnd, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: ctx.font)), LPARAM(1))
        return hwnd
    }

    public static func checkbox(
        _ text: String, in ctx: PaneContext, id: Int32,
        x: Int32, y: Int32, w: Int32, h: Int32
    ) -> HWND? {
        let textWide = Array(text.utf16) + [0]
        let hwnd = buttonClass.withUnsafeBufferPointer { bc in
            textWide.withUnsafeBufferPointer { tw in
                CreateWindowExW(
                    0, bc.baseAddress, tw.baseAddress,
                    DWORD(WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX | WS_TABSTOP),
                    x, y, w, h, ctx.host, HMENU(bitPattern: Int(id)), ctx.instance, nil
                )
            }
        }
        guard let hwnd else { return nil }
        SendMessageW(hwnd, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: ctx.font)), LPARAM(1))
        return hwnd
    }

    public static func button(
        _ text: String, in ctx: PaneContext, id: Int32,
        x: Int32, y: Int32, w: Int32, h: Int32,
        default_: Bool = false, destructive: Bool = false
    ) -> HWND? {
        let textWide = Array(text.utf16) + [0]
        let style = DWORD(WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW | (default_ ? BS_DEFPUSHBUTTON : BS_PUSHBUTTON))
        let hwnd = buttonClass.withUnsafeBufferPointer { bc in
            textWide.withUnsafeBufferPointer { tw in
                CreateWindowExW(
                    0, bc.baseAddress, tw.baseAddress,
                    style,
                    x, y, w, h, ctx.host, HMENU(bitPattern: Int(id)), ctx.instance, nil
                )
            }
        }
        guard let hwnd else { return nil }
        SendMessageW(hwnd, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: ctx.font)), LPARAM(1))
        return hwnd
    }

    public static func combo(
        _ items: [String], in ctx: PaneContext, id: Int32,
        x: Int32, y: Int32, w: Int32, h: Int32
    ) -> HWND? {
        let hwnd = comboClass.withUnsafeBufferPointer { cc in
            CreateWindowExW(
                0, cc.baseAddress, nil,
                DWORD(WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST | WS_TABSTOP | WS_VSCROLL),
                x, y, w, h, ctx.host, HMENU(bitPattern: Int(id)), ctx.instance, nil
            )
        }
        guard let hwnd else { return nil }
        SendMessageW(hwnd, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: ctx.font)), LPARAM(1))
        for item in items {
            let strWide = Array(item.utf16) + [0]
            strWide.withUnsafeBufferPointer { buf in
                SendMessageW(hwnd, UINT(CB_ADDSTRING), 0, LPARAM(UInt(bitPattern: buf.baseAddress)))
            }
        }
        return hwnd
    }

    public static func canvas(
        in ctx: PaneContext, id: Int32,
        x: Int32, y: Int32, w: Int32, h: Int32
    ) -> HWND? {
        let hwnd = staticClass.withUnsafeBufferPointer { sc in
            CreateWindowExW(
                0, sc.baseAddress, nil,
                DWORD(WS_CHILD | WS_VISIBLE | SS_OWNERDRAW),
                x, y, w, h, ctx.host, HMENU(bitPattern: Int(id)), ctx.instance, nil
            )
        }
        return hwnd
    }

    /// Always transient: every caller builds it inside `layout`.
    public static func sectionHeader(_ title: String, in ctx: PaneContext, y: Int32, width: Int32) -> Int32 {
        _ = label(title, in: ctx, x: ctx.metrics.pad, y: y, w: width - ctx.metrics.pad * 2, h: ctx.metrics.px(20), bold: true, transient: true)
        return y + ctx.metrics.px(24)
    }

    public static func helpText(
        _ text: String, in ctx: PaneContext,
        x: Int32, y: Int32, width: Int32
    ) -> Int32 {
        var rect = RECT(left: 0, top: 0, right: width, bottom: 0)
        let dc = GetDC(ctx.host)
        if let dc {
            let oldFont = ctx.captionFont.map { SelectObject(dc, $0) }
            var textWide = Array(text.utf16) + [0]
            _ = textWide.withUnsafeMutableBufferPointer { buf in
                DrawTextW(dc, buf.baseAddress, Int32(buf.count - 1), &rect, UINT(DT_CALCRECT | DT_WORDBREAK))
            }
            if let oldFont { SelectObject(dc, oldFont) }
            ReleaseDC(ctx.host, dc)
        }
        let measuredH = max(ctx.metrics.px(16), rect.bottom - rect.top)
        _ = label(text, in: ctx, x: x, y: y, w: width, h: measuredH, caption: true, color: WinDark.dim, transient: true)
        return measuredH
    }

    // Value accessors
    public static func text(_ hwnd: HWND?) -> String {
        guard let hwnd else { return "" }
        let len = SendMessageW(hwnd, UINT(WM_GETTEXTLENGTH), 0, 0)
        guard len > 0 else { return "" }
        var buffer = [WCHAR](repeating: 0, count: Int(len) + 1)
        return buffer.withUnsafeMutableBufferPointer { buf in
            SendMessageW(hwnd, UINT(WM_GETTEXT), WPARAM(buf.count), LPARAM(UInt(bitPattern: buf.baseAddress)))
            return String(decodingCString: buf.baseAddress!, as: UTF16.self)
        }
    }

    public static func setText(_ hwnd: HWND?, _ s: String) {
        guard let hwnd else { return }
        let wide = Array(s.utf16) + [0]
        wide.withUnsafeBufferPointer { buf in
            SendMessageW(hwnd, UINT(WM_SETTEXT), 0, LPARAM(UInt(bitPattern: buf.baseAddress)))
        }
    }

    public static func checked(_ hwnd: HWND?) -> Bool {
        guard let hwnd else { return false }
        return SendMessageW(hwnd, UINT(BM_GETCHECK), 0, 0) == BST_CHECKED
    }

    public static func setChecked(_ hwnd: HWND?, _ on: Bool) {
        guard let hwnd else { return }
        SendMessageW(hwnd, UINT(BM_SETCHECK), WPARAM(on ? BST_CHECKED : BST_UNCHECKED), 0)
    }

    public static func comboSelection(_ hwnd: HWND?) -> String {
        guard let hwnd else { return "" }
        let idx = SendMessageW(hwnd, UINT(CB_GETCURSEL), 0, 0)
        guard idx >= 0 else { return "" }
        let len = SendMessageW(hwnd, UINT(CB_GETLBTEXTLEN), WPARAM(idx), 0)
        guard len > 0 else { return "" }
        var buffer = [WCHAR](repeating: 0, count: Int(len) + 1)
        return buffer.withUnsafeMutableBufferPointer { buf in
            SendMessageW(hwnd, UINT(CB_GETLBTEXT), WPARAM(idx), LPARAM(UInt(bitPattern: buf.baseAddress)))
            return String(decodingCString: buf.baseAddress!, as: UTF16.self)
        }
    }

    public static func setComboSelection(_ hwnd: HWND?, _ s: String) {
        guard let hwnd else { return }
        let wide = Array(s.utf16) + [0]
        let idx = wide.withUnsafeBufferPointer { buf in
            SendMessageW(hwnd, UINT(CB_FINDSTRINGEXACT), WPARAM(bitPattern: -1), LPARAM(UInt(bitPattern: buf.baseAddress)))
        }
        if idx >= 0 {
            SendMessageW(hwnd, UINT(CB_SETCURSEL), WPARAM(idx), 0)
        }
    }

    public static func enable(_ hwnd: HWND?, _ enabled: Bool) {
        guard let hwnd else { return }
        EnableWindow(hwnd, enabled)
    }
}
