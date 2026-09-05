import Foundation
import InfinitusCore
import InfinitusWinUI
import WinSDK

/// CodexBar-style Settings shell window with sidebar and child pane containers.
public enum SettingsShell {
    private static let className = "InfinitusSettingsShell"
    private nonisolated(unsafe) static var isRegistered = false
    private nonisolated(unsafe) static var openHwnd: HWND?
    private nonisolated(unsafe) static var currentShell: State?

    public static let WM_APP_PANE_RESULT: UINT = UINT(WM_APP + 101)

    // MARK: - Async slot storage
    public struct AsyncSlot {
        public let paneIndex: Int32
        public let generation: UInt64
        public let thunk: @Sendable () -> Void

        public init(paneIndex: Int32, generation: UInt64, thunk: @escaping @Sendable () -> Void) {
            self.paneIndex = paneIndex
            self.generation = generation
            self.thunk = thunk
        }
    }

    private static let slotLock = NSLock()
    private nonisolated(unsafe) static var asyncSlots: [Int: AsyncSlot] = [:]
    private nonisolated(unsafe) static var nextSlotID: Int = 1

    public static func storeAsyncSlot(paneIndex: Int32, generation: UInt64, thunk: @escaping @Sendable () -> Void) -> Int {
        slotLock.lock()
        defer { slotLock.unlock() }
        let id = nextSlotID
        nextSlotID += 1
        asyncSlots[id] = AsyncSlot(paneIndex: paneIndex, generation: generation, thunk: thunk)
        return id
    }

    public static func popAsyncSlot(id: Int) -> AsyncSlot? {
        slotLock.lock()
        defer { slotLock.unlock() }
        return asyncSlots.removeValue(forKey: id)
    }

    /// A slot whose `PostMessageW` lands after the window is gone is
    /// never drained, and its thunk retains the pane. Dropped wholesale
    /// when the shell dies.
    public static func clearAsyncSlots() {
        slotLock.lock()
        defer { slotLock.unlock() }
        asyncSlots.removeAll()
    }

    // MARK: - Pane Entry in Shell
    final class PaneEntry {
        let descriptor: PaneDescriptor
        let pane: SettingsPane
        let hostHwnd: HWND
        let ctx: PaneContext

        init(descriptor: PaneDescriptor, pane: SettingsPane, hostHwnd: HWND, ctx: PaneContext) {
            self.descriptor = descriptor
            self.pane = pane
            self.hostHwnd = hostHwnd
            self.ctx = ctx
        }
    }

    final class State {
        var hwnd: HWND?
        var searchHwnd: HWND?
        var metrics: Metrics

        var font: HFONT?
        var boldFont: HFONT?
        var captionFont: HFONT?
        var iconFont: HFONT?

        var panes: [PaneEntry] = []
        var filteredDescriptors: [PaneDescriptor] = []
        var selectedPaneID: String = "display"
        var hoveredRow: Int? = nil

        var trackingMouse = false

        init(metrics: Metrics) {
            self.metrics = metrics
        }

        deinit {
            if let font { DeleteObject(font) }
            if let boldFont { DeleteObject(boldFont) }
            if let captionFont { DeleteObject(captionFont) }
            if let iconFont { DeleteObject(iconFont) }
        }
    }

    public static func show(paneID: String? = nil) {
        if let existing = openHwnd, IsWindow(existing) {
            if IsIconic(existing) { ShowWindow(existing, SW_RESTORE) }
            SetForegroundWindow(existing)
            if let paneID, let state = currentShell {
                selectPane(paneID: paneID, state: state)
            }
            return
        }

        let instance = GetModuleHandleW(nil)
        registerClassIfNeeded(instance: instance)

        let initialMetrics = Metrics(hwnd: nil)
        let state = State(metrics: initialMetrics)
        currentShell = state

        let settings = WinSettingsStore.load()
        state.selectedPaneID = paneID ?? settings.lastPaneID

        var frameW = settings.windowWidth > 0 ? settings.windowWidth : initialMetrics.px(980)
        var frameH = settings.windowHeight > 0 ? settings.windowHeight : initialMetrics.px(680)

        // Center on monitor with cursor
        var pt = POINT()
        GetCursorPos(&pt)
        let hMon = MonitorFromPoint(pt, DWORD(MONITOR_DEFAULTTONEAREST))
        var mi = MONITORINFO()
        mi.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        GetMonitorInfoW(hMon, &mi)
        let monW = mi.rcWork.right - mi.rcWork.left
        let monH = mi.rcWork.bottom - mi.rcWork.top
        let x = mi.rcWork.left + max(0, (monW - frameW) / 2)
        let y = mi.rcWork.top + max(0, (monH - frameH) / 2)

        let title = "Infinitus Settings"
        let titleWide = Array(title.utf16) + [0]
        let classWide = Array(className.utf16) + [0]
        let statePtr = Unmanaged.passRetained(state).toOpaque()

        let hwnd = classWide.withUnsafeBufferPointer { cBuf in
            titleWide.withUnsafeBufferPointer { tBuf in
                CreateWindowExW(
                    0,
                    cBuf.baseAddress,
                    tBuf.baseAddress,
                    DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_CLIPCHILDREN),
                    x, y, frameW, frameH,
                    nil, nil, instance, statePtr
                )
            }
        }

        guard let hwnd else { return }
        openHwnd = hwnd
        state.hwnd = hwnd

        WinDark.applyTitleBar(to: hwnd)
        ShowWindow(hwnd, SW_SHOW)
        UpdateWindow(hwnd)

        selectPane(paneID: state.selectedPaneID, state: state)
    }

    private static func registerClassIfNeeded(instance: HMODULE?) {
        guard !isRegistered else { return }
        isRegistered = true

        let classWide = Array(className.utf16) + [0]
        classWide.withUnsafeBufferPointer { buf in
            var wc = WNDCLASSEXW()
            wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            wc.lpfnWndProc = shellWndProc
            wc.hInstance = instance
            wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            wc.hbrBackground = WinDark.backgroundBrush
            wc.lpszClassName = buf.baseAddress
            RegisterClassExW(&wc)
        }
    }

    public static func handles(_ msg: inout MSG) -> Bool {
        guard let shellHwnd = openHwnd, IsWindow(shellHwnd) else { return false }

        // Only handle messages destined for this window or its children
        var target: HWND? = msg.hwnd
        var isChildOfShell = false
        while let t = target, IsWindow(t) {
            if t == shellHwnd {
                isChildOfShell = true
                break
            }
            target = GetParent(t)
        }
        guard isChildOfShell else { return false }

        // Keyboard shortcuts
        if msg.message == UINT(WM_KEYDOWN) || msg.message == UINT(WM_SYSKEYDOWN) {
            let vk = Int32(msg.wParam)
            let ctrl = (GetKeyState(VK_CONTROL) & Int16(bitPattern: 0x8000)) != 0
            let shift = (GetKeyState(VK_SHIFT) & Int16(bitPattern: 0x8000)) != 0

            if vk == VK_ESCAPE {
                PostMessageW(shellHwnd, UINT(WM_CLOSE), 0, 0)
                return true
            }

            if ctrl && (vk == 0x46 || vk == 0x45) { // Ctrl+F or Ctrl+E
                if let state = currentShell, let sHwnd = state.searchHwnd {
                    SetFocus(sHwnd)
                    SendMessageW(sHwnd, UINT(EM_SETSEL), 0, -1)
                }
                return true
            }

            if ctrl && vk == VK_TAB {
                if let state = currentShell {
                    cyclePane(forward: !shift, state: state)
                }
                return true
            }

            if vk == VK_UP || vk == VK_DOWN {
                // If focus is in search box or window itself, navigate sidebar
                let focus = GetFocus()
                if let state = currentShell, (focus == shellHwnd || focus == state.searchHwnd) {
                    navigateSidebar(delta: vk == VK_UP ? -1 : 1, state: state)
                    return true
                }
            }

            if vk == VK_RETURN {
                let focus = GetFocus()
                if let state = currentShell, focus == state.searchHwnd {
                    if let first = state.filteredDescriptors.first {
                        selectPane(paneID: first.id, state: state)
                    }
                    return true
                }
            }
        }

        // Win32 dialog navigation (Tab/Shift-Tab across controls)
        if IsDialogMessageW(shellHwnd, &msg) {
            return true
        }

        return false
    }

    private static func cyclePane(forward: Bool, state: State) {
        let descs = state.filteredDescriptors.filter { ($0.badge?().placeholder ?? false) == false }
        guard !descs.isEmpty else { return }
        let curIdx = descs.firstIndex(where: { $0.id == state.selectedPaneID }) ?? 0
        let nextIdx: Int
        if forward {
            nextIdx = (curIdx + 1) % descs.count
        } else {
            nextIdx = (curIdx - 1 + descs.count) % descs.count
        }
        selectPane(paneID: descs[nextIdx].id, state: state)
    }

    private static func navigateSidebar(delta: Int, state: State) {
        let descs = state.filteredDescriptors.filter { ($0.badge?().placeholder ?? false) == false }
        guard !descs.isEmpty else { return }
        let curIdx = descs.firstIndex(where: { $0.id == state.selectedPaneID }) ?? 0
        let nextIdx = min(max(0, curIdx + delta), descs.count - 1)
        selectPane(paneID: descs[nextIdx].id, state: state)
    }

    private static func selectPane(paneID: String, state: State) {
        guard let nextEntry = state.panes.first(where: { $0.descriptor.id == paneID }) else {
            // If requested paneID not found, fallback to first general
            if let first = state.panes.first {
                selectPane(paneID: first.descriptor.id, state: state)
            }
            return
        }

        if let current = state.panes.first(where: { $0.descriptor.id == state.selectedPaneID }),
           current.descriptor.id != nextEntry.descriptor.id {
            current.pane.deactivate()
            // Anything still on a worker for the pane we are leaving must
            // not land on its now-hidden controls.
            current.ctx.invalidateResults()
            ShowWindow(current.hostHwnd, SW_HIDE)
        }

        state.selectedPaneID = nextEntry.descriptor.id
        _ = try? WinSettingsStore.update { $0.lastPaneID = nextEntry.descriptor.id }

        // Layout next pane container in content rect
        if let hwnd = state.hwnd {
            var rc = RECT()
            GetClientRect(hwnd, &rc)
            let m = state.metrics
            let contentX = m.sidebarWidth + 1
            let contentW = max(10, rc.right - contentX)
            let contentH = max(10, rc.bottom)

            MoveWindow(nextEntry.hostHwnd, contentX, 0, contentW, contentH, true)
            ShowWindow(nextEntry.hostHwnd, SW_SHOW)
            nextEntry.pane.layout(width: contentW, height: contentH)
            nextEntry.pane.activate()

            // Invalidate sidebar
            var sidebarRc = rc
            sidebarRc.right = m.sidebarWidth + 1
            InvalidateRect(hwnd, &sidebarRc, false)
        }
    }

    // MARK: - Class registration and window proc
    private static func buildFonts(hwnd: HWND, state: State) {
        if let f = state.font { DeleteObject(f) }
        if let f = state.boldFont { DeleteObject(f) }
        if let f = state.captionFont { DeleteObject(f) }
        if let f = state.iconFont { DeleteObject(f) }

        state.metrics = Metrics(hwnd: hwnd)
        let m = state.metrics

        let bodyHeight = -m.px(12)
        let boldHeight = -m.px(12)
        let captionHeight = -m.px(10)
        let iconHeight = -m.px(13)

        func createFont(height: Int32, weight: Int32, face: String) -> HFONT? {
            let wideFace = Array(face.utf16) + [0]
            return wideFace.withUnsafeBufferPointer { buf in
                CreateFontW(
                    height, 0, 0, 0,
                    weight, 0, 0, 0,
                    DWORD(DEFAULT_CHARSET),
                    DWORD(OUT_DEFAULT_PRECIS),
                    DWORD(CLIP_DEFAULT_PRECIS),
                    DWORD(CLEARTYPE_QUALITY),
                    DWORD(DEFAULT_PITCH | FF_DONTCARE),
                    buf.baseAddress
                )
            }
        }

        state.font = createFont(height: bodyHeight, weight: FW_NORMAL, face: "Segoe UI")
        state.boldFont = createFont(height: boldHeight, weight: FW_SEMIBOLD, face: "Segoe UI")
        state.captionFont = createFont(height: captionHeight, weight: FW_NORMAL, face: "Segoe UI")
        // Segoe Fluent Icons with Segoe MDL2 Assets fallback
        state.iconFont = createFont(height: iconHeight, weight: FW_NORMAL, face: "Segoe Fluent Icons")
            ?? createFont(height: iconHeight, weight: FW_NORMAL, face: "Segoe MDL2 Assets")
            ?? state.font

        if let s = state.searchHwnd {
            SendMessageW(s, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: state.font)), LPARAM(1))
        }

        for p in state.panes {
            p.ctx.metrics = m
            p.ctx.font = state.font
            p.ctx.boldFont = state.boldFont
            p.ctx.captionFont = state.captionFont
        }
    }

    private static func createPanes(hwnd: HWND, state: State, instance: HMODULE?) {
        // Descriptors mapping to SettingsCatalog
        // 10 General + 3 Engine + 1 Legacy
        let allDescriptors: [(PaneDescriptor, (PaneDescriptor) -> SettingsPane)] = [
            (
                DisplayPane.descriptor,
                { _ in DisplayPane() }
            ),
            (
                AccountsPane.descriptor,
                { _ in AccountsPane() }
            ),
            (
                ThemesPane.descriptor,
                { _ in ThemesPane() }
            ),
            (
                PushPane.descriptor,
                { _ in PushPane() }
            ),
            (
                UsagePane.descriptor,
                { _ in UsagePane() }
            ),
            (
                UtilizationPane.descriptor,
                { _ in UtilizationPane() }
            ),
            (
                StatsPane.descriptor,
                { _ in StatsPane() }
            ),
            (
                ActivityPane.descriptor,
                { _ in ActivityPane() }
            ),
            (
                DevicesPane.descriptor,
                { _ in DevicesPane() }
            ),
            (
                AboutPane.descriptor,
                { _ in AboutPane() }
            ),
            (
                CswapPane.descriptor,
                { _ in CswapPane() }
            ),
            (
                CLIProxyPane.descriptor,
                { _ in CLIProxyPane() }
            ),
            (
                NineRouterPane.descriptor,
                { _ in NineRouterPane() }
            )
        ]

        state.panes = []
        for (index, pair) in allDescriptors.enumerated() {
            let (desc, factory) = pair
            let idBase = PaneIDs.block(Int32(index))
            guard let hostHwnd = PaneHost.create(parent: hwnd, id: idBase, metrics: state.metrics, instance: instance) else {
                continue
            }
            let ctx = PaneContext(
                host: hostHwnd,
                shell: hwnd,
                instance: instance,
                metrics: state.metrics,
                font: state.font,
                boldFont: state.boldFont,
                captionFont: state.captionFont,
                idBase: idBase,
                paneIndex: Int32(index)
            )
            let pane = factory(desc)
            pane.attach(host: hostHwnd, ctx: ctx)
            let entry = PaneEntry(descriptor: desc, pane: pane, hostHwnd: hostHwnd, ctx: ctx)
            state.panes.append(entry)
        }

        filterSidebar(state: state, query: "")
    }

    private static func filterSidebar(state: State, query: String) {
        let all = state.panes.map(\.descriptor)
        state.filteredDescriptors = SettingsCatalogWin.filter(all, query: query)
        if let hwnd = state.hwnd {
            var rc = RECT()
            GetClientRect(hwnd, &rc)
            rc.right = state.metrics.sidebarWidth + 1
            InvalidateRect(hwnd, &rc, false)
        }
    }

    // MARK: - Row Placement & Hit-testing
    struct PlacedRow {
        let index: Int
        let descriptor: PaneDescriptor
        let rect: RECT
        let isEngine: Bool
    }

    private static func placeRows(state: State) -> (rows: [PlacedRow], enginesHeaderRect: RECT?, liveCount: Int) {
        let m = state.metrics
        let searchH = m.fieldHeight + m.px(4)
        var y: Int32 = m.px(14) + searchH + m.px(10)
        let rowH = m.settingsRowHeight
        let sidebarW = m.sidebarWidth

        var out: [PlacedRow] = []

        // General rows
        for (idx, d) in state.filteredDescriptors.enumerated() where d.section == .general {
            let r = RECT(left: m.px(8), top: y, right: sidebarW - m.px(8), bottom: y + rowH)
            out.append(PlacedRow(index: idx, descriptor: d, rect: r, isEngine: false))
            y += rowH
        }

        // Engine rows
        let engineDescs = state.filteredDescriptors.filter { $0.section == .engines }
        var enginesHeaderRect: RECT? = nil
        var liveCount = 0

        if !engineDescs.isEmpty {
            y += m.px(14)
            enginesHeaderRect = RECT(left: m.px(14), top: y, right: sidebarW - m.px(14), bottom: y + m.px(18))
            y += m.px(22)

            for (idx, d) in state.filteredDescriptors.enumerated() where d.section == .engines {
                let r = RECT(left: m.px(8), top: y, right: sidebarW - m.px(8), bottom: y + rowH)
                let isLive = d.badge?().live ?? false
                if isLive { liveCount += 1 }
                out.append(PlacedRow(index: idx, descriptor: d, rect: r, isEngine: true))
                y += rowH
            }
        }

        return (out, enginesHeaderRect, liveCount)
    }

    private static func hitTest(pt: POINT, state: State) -> PaneDescriptor? {
        let (placed, _, _) = placeRows(state: state)
        for r in placed {
            if pt.x >= r.rect.left && pt.x <= r.rect.right &&
               pt.y >= r.rect.top && pt.y <= r.rect.bottom {
                if r.descriptor.badge?().placeholder ?? false {
                    return nil
                }
                return r.descriptor
            }
        }
        return nil
    }

    // MARK: - Double buffered sidebar paint
    private static func paintSidebar(hwnd: HWND, state: State) {
        var ps = PAINTSTRUCT()
        guard let hdc = BeginPaint(hwnd, &ps) else { return }
        defer { EndPaint(hwnd, &ps) }

        var clientRc = RECT()
        GetClientRect(hwnd, &clientRc)
        let m = state.metrics
        let sidebarW = m.sidebarWidth

        guard let memDC = CreateCompatibleDC(hdc) else { return }
        defer { DeleteDC(memDC) }

        guard let memBitmap = CreateCompatibleBitmap(hdc, sidebarW + 1, clientRc.bottom) else { return }
        defer { DeleteObject(memBitmap) }

        let oldBmp = SelectObject(memDC, memBitmap)
        defer { if let oldBmp { SelectObject(memDC, oldBmp) } }

        // Background
        var sideRc = RECT(left: 0, top: 0, right: sidebarW, bottom: clientRc.bottom)
        if let bgBrush = WinDark.backgroundBrush {
            FillRect(memDC, &sideRc, bgBrush)
        }

        // Separator line
        var sepRc = RECT(left: sidebarW, top: 0, right: sidebarW + 1, bottom: clientRc.bottom)
        if let sepBrush = CreateSolidBrush(WinDark.separator) {
            FillRect(memDC, &sepRc, sepBrush)
            DeleteObject(sepBrush)
        }

        let (rows, enginesHeader, liveCount) = placeRows(state: state)

        if rows.isEmpty {
            // "No settings match"
            let oldFont = state.captionFont.map { SelectObject(memDC, $0) }
            SetBkMode(memDC, TRANSPARENT)
            SetTextColor(memDC, WinDark.faint)
            var noMatchRc = RECT(left: m.px(10), top: m.px(80), right: sidebarW - m.px(10), bottom: m.px(120))
            let noMatchStr = "No settings match"
            var wide = Array(noMatchStr.utf16) + [0]
            _ = DrawTextW(memDC, &wide, Int32(noMatchStr.utf16.count), &noMatchRc,
                          UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))
            if let oldFont { SelectObject(memDC, oldFont) }
        }

        // Engines header
        if var eh = enginesHeader {
            let oldFont = state.captionFont.map { SelectObject(memDC, $0) }
            SetBkMode(memDC, TRANSPARENT)
            SetTextColor(memDC, WinDark.dim)
            var titleWide = Array("Engines".utf16) + [0]
            _ = DrawTextW(memDC, &titleWide, Int32("Engines".utf16.count), &eh,
                          UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))

            let countStr = "\(liveCount) on"
            var countWide = Array(countStr.utf16) + [0]
            _ = DrawTextW(memDC, &countWide, Int32(countStr.utf16.count), &eh,
                          UINT(DT_RIGHT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))
            if let oldFont { SelectObject(memDC, oldFont) }
        }

        // Rows
        for row in rows {
            var r = row.rect
            let isSelected = row.descriptor.id == state.selectedPaneID
            let isHovered = (state.hoveredRow == row.index) && !isSelected

            if isSelected {
                if let brush = CreateSolidBrush(WinDark.selection) {
                    FillRect(memDC, &r, brush)
                    DeleteObject(brush)
                }
            } else if isHovered {
                if let brush = CreateSolidBrush(WinDark.hover) {
                    FillRect(memDC, &r, brush)
                    DeleteObject(brush)
                }
            }

            if !row.isEngine {
                // General row: rounded tinted tile
                let tileS = m.tileSide
                let tileY = r.top + (r.bottom - r.top - tileS) / 2
                let tileRc = RECT(left: r.left + m.px(4), top: tileY, right: r.left + m.px(4) + tileS, bottom: tileY + tileS)
                let c = row.descriptor.tintRGB
                let tint = WinDark.rgb(Int(c.r), Int(c.g), Int(c.b))
                WinDark.drawTile(dc: memDC, rect: tileRc, tint: tint, glyph: row.descriptor.glyph, font: state.iconFont)

                // Title
                let textRc = RECT(left: tileRc.right + m.px(8), top: r.top, right: r.right - m.px(4), bottom: r.bottom)
                var titleWide = Array(row.descriptor.title.utf16) + [0]
                let oldFont = state.font.map { SelectObject(memDC, $0) }
                SetBkMode(memDC, TRANSPARENT)
                SetTextColor(memDC, WinDark.text)
                var tr = textRc
                _ = DrawTextW(memDC, &titleWide, Int32(row.descriptor.title.utf16.count), &tr,
                              UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))
                if let oldFont { SelectObject(memDC, oldFont) }
            } else {
                // Engine row: glyph + title + badge
                let isPlaceholder = row.descriptor.badge?().placeholder ?? false
                let isLive = row.descriptor.badge?().live ?? false

                let glyphRc = RECT(left: r.left + m.px(6), top: r.top, right: r.left + m.px(24), bottom: r.bottom)
                var glyphWide = Array(row.descriptor.glyph.utf16) + [0]
                let oldIconFont = state.iconFont.map { SelectObject(memDC, $0) }
                SetBkMode(memDC, TRANSPARENT)
                SetTextColor(memDC, isPlaceholder ? WinDark.faint : WinDark.text)
                var gr = glyphRc
                _ = DrawTextW(memDC, &glyphWide, Int32(row.descriptor.glyph.utf16.count), &gr,
                              UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))
                if let oldIconFont { SelectObject(memDC, oldIconFont) }

                let textRc = RECT(left: glyphRc.right + m.px(8), top: r.top, right: r.right - m.px(24), bottom: r.bottom)
                var titleWide = Array(row.descriptor.title.utf16) + [0]
                let oldFont = state.font.map { SelectObject(memDC, $0) }
                SetBkMode(memDC, TRANSPARENT)
                SetTextColor(memDC, isPlaceholder ? WinDark.faint : (isSelected ? WinDark.text : WinDark.dim))
                var tr = textRc
                _ = DrawTextW(memDC, &titleWide, Int32(row.descriptor.title.utf16.count), &tr,
                              UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))
                if let oldFont { SelectObject(memDC, oldFont) }

                // Live green dot
                if isLive {
                    let dotSize = m.px(7)
                    let dotY = r.top + (r.bottom - r.top - dotSize) / 2
                    let dotX = r.right - m.px(14)
                    if let dotBrush = CreateSolidBrush(WinDark.liveDot),
                       let nullPen = GetStockObject(NULL_PEN) {
                        let oldB = SelectObject(memDC, dotBrush)
                        let oldP = SelectObject(memDC, nullPen)
                        Ellipse(memDC, dotX, dotY, dotX + dotSize, dotY + dotSize)
                        SelectObject(memDC, oldP)
                        SelectObject(memDC, oldB)
                        DeleteObject(dotBrush)
                    }
                }
            }
        }

        BitBlt(hdc, 0, 0, sidebarW + 1, clientRc.bottom, memDC, 0, 0, SRCCOPY)
    }

    private static func getState(_ hwnd: HWND) -> State? {
        let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA)
        guard ptr != 0 else { return nil }
        return Unmanaged<State>.fromOpaque(UnsafeMutableRawPointer(bitPattern: Int(ptr))!).takeUnretainedValue()
    }

    private static let shellWndProc: WNDPROC = { hwnd, msg, wParam, lParam in
        guard let hwnd else { return DefWindowProcW(hwnd, msg, wParam, lParam) }
        let msgInt = Int32(bitPattern: msg)

        // Pre-switch CTLCOLOR routing
        if let ctlColorResult = WinDark.controlColor(msg: msg, wParam: wParam) {
            return ctlColorResult
        }

        switch msgInt {
        case WM_NCCREATE:
            let cs = UnsafePointer<CREATESTRUCTW>(bitPattern: Int(lParam))!
            let ptr = cs.pointee.lpCreateParams
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, LONG_PTR(Int(bitPattern: ptr)))
            return 1

        case WM_CREATE:
            guard let state = getState(hwnd) else { return 0 }
            let instance = GetModuleHandleW(nil)
            buildFonts(hwnd: hwnd, state: state)

            // Search box child edit
            let m = state.metrics
            let searchY = m.px(14)
            let searchW = m.sidebarWidth - m.px(20)
            let searchH = m.fieldHeight + m.px(4)
            let editClass = Array("EDIT".utf16) + [0]
            state.searchHwnd = editClass.withUnsafeBufferPointer { ec in
                CreateWindowExW(
                    DWORD(WS_EX_CLIENTEDGE),
                    ec.baseAddress,
                    nil,
                    DWORD(WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL | WS_TABSTOP),
                    m.px(10), searchY, searchW, searchH,
                    hwnd,
                    HMENU(bitPattern: 100),
                    instance,
                    nil
                )
            }
            if let sHwnd = state.searchHwnd {
                SendMessageW(sHwnd, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: state.font)), LPARAM(1))
            }

            createPanes(hwnd: hwnd, state: state, instance: instance)
            return 0

        case WM_SIZE:
            guard let state = getState(hwnd) else { return 0 }
            var rc = RECT()
            GetClientRect(hwnd, &rc)
            let m = state.metrics

            // Reposition search box
            if let sHwnd = state.searchHwnd {
                let searchY = m.px(14)
                let searchW = m.sidebarWidth - m.px(20)
                let searchH = m.fieldHeight + m.px(4)
                MoveWindow(sHwnd, m.px(10), searchY, searchW, searchH, true)
            }

            // Reposition visible pane container
            let contentX = m.sidebarWidth + 1
            let contentW = max(10, rc.right - contentX)
            let contentH = max(10, rc.bottom)

            if let cur = state.panes.first(where: { $0.descriptor.id == state.selectedPaneID }) {
                MoveWindow(cur.hostHwnd, contentX, 0, contentW, contentH, true)
                cur.pane.layout(width: contentW, height: contentH)
            }

            var sideRc = rc
            sideRc.right = m.sidebarWidth + 1
            InvalidateRect(hwnd, &sideRc, false)
            return 0

        case WM_GETMINMAXINFO:
            guard let info = UnsafeMutablePointer<MINMAXINFO>(bitPattern: Int(lParam)) else { return 0 }
            let m = Metrics(hwnd: hwnd)
            info.pointee.ptMinTrackSize.x = LONG(m.px(900))
            info.pointee.ptMinTrackSize.y = LONG(m.px(620))
            return 0

        case WM_DPICHANGED:
            guard let state = getState(hwnd) else { return 0 }
            if let suggested = UnsafePointer<RECT>(bitPattern: Int(lParam)) {
                let r = suggested.pointee
                SetWindowPos(hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
            }
            buildFonts(hwnd: hwnd, state: state)
            var rc = RECT()
            GetClientRect(hwnd, &rc)
            let contentX = state.metrics.sidebarWidth + 1
            let contentW = max(10, rc.right - contentX)
            let contentH = max(10, rc.bottom)
            for p in state.panes {
                p.pane.layout(width: contentW, height: contentH)
            }
            InvalidateRect(hwnd, nil, true)
            return 0

        case WM_PAINT:
            guard let state = getState(hwnd) else { return 0 }
            paintSidebar(hwnd: hwnd, state: state)
            return 0

        case WM_ERASEBKGND:
            return 1

        case WM_MOUSEMOVE:
            guard let state = getState(hwnd) else { return 0 }
            if !state.trackingMouse {
                var tme = TRACKMOUSEEVENT()
                tme.cbSize = DWORD(MemoryLayout<TRACKMOUSEEVENT>.size)
                tme.dwFlags = DWORD(TME_LEAVE)
                tme.hwndTrack = hwnd
                TrackMouseEvent(&tme)
                state.trackingMouse = true
            }
            let pt = mousePoint(lParam)
            let hoveredDesc = hitTest(pt: pt, state: state)
            let newHoverIdx = hoveredDesc.flatMap { d in state.filteredDescriptors.firstIndex(where: { $0.id == d.id }) }
            if newHoverIdx != state.hoveredRow {
                state.hoveredRow = newHoverIdx
                var rc = RECT()
                GetClientRect(hwnd, &rc)
                rc.right = state.metrics.sidebarWidth + 1
                InvalidateRect(hwnd, &rc, false)
            }
            return 0

        case WM_MOUSELEAVE:
            guard let state = getState(hwnd) else { return 0 }
            state.trackingMouse = false
            if state.hoveredRow != nil {
                state.hoveredRow = nil
                var rc = RECT()
                GetClientRect(hwnd, &rc)
                rc.right = state.metrics.sidebarWidth + 1
                InvalidateRect(hwnd, &rc, false)
            }
            return 0

        case WM_LBUTTONUP:
            guard let state = getState(hwnd) else { return 0 }
            let pt = mousePoint(lParam)
            if let desc = hitTest(pt: pt, state: state) {
                selectPane(paneID: desc.id, state: state)
            }
            return 0

        case WM_MOUSEWHEEL:
            guard let state = getState(hwnd) else { return 0 }
            if let cur = state.panes.first(where: { $0.descriptor.id == state.selectedPaneID }) {
                SendMessageW(cur.hostHwnd, UINT(WM_MOUSEWHEEL), wParam, lParam)
            }
            return 0

        case WM_COMMAND:
            guard let state = getState(hwnd) else { return 0 }
            // Truncate, never convert: wParam is 64-bit and DWORD(_:) traps
            // on anything above UInt32.max.
            let cmdID = Int32(UInt16(truncatingIfNeeded: wParam))
            let code = UINT(UInt16(truncatingIfNeeded: wParam >> 16))
            let fromHwnd = HWND(bitPattern: Int(lParam))

            // Search box EN_CHANGE
            if fromHwnd == state.searchHwnd && code == UINT(EN_CHANGE) {
                let q = PaneControls.text(state.searchHwnd)
                filterSidebar(state: state, query: q)
                return 0
            }

            // Route to owning pane by id block
            if let pIdx = PaneIDs.paneIndex(for: cmdID), pIdx >= 0 && pIdx < state.panes.count {
                _ = state.panes[Int(pIdx)].pane.command(id: cmdID, code: code, from: fromHwnd)
                return 0
            }
            return 0

        case WM_NOTIFY:
            guard let state = getState(hwnd) else { return 0 }
            guard let nmhdr = UnsafePointer<NMHDR>(bitPattern: Int(lParam)) else { return 0 }
            let idFrom = Int32(nmhdr.pointee.idFrom)
            if let pIdx = PaneIDs.paneIndex(for: idFrom), pIdx >= 0 && pIdx < state.panes.count {
                if state.panes[Int(pIdx)].pane.notify(nmhdr) {
                    return 1
                }
            }
            return 0

        case WM_DRAWITEM:
            guard let state = getState(hwnd) else { return 0 }
            guard let dis = UnsafePointer<DRAWITEMSTRUCT>(bitPattern: Int(lParam)) else { return 0 }
            let ctlID = Int32(dis.pointee.CtlID)
            if let pIdx = PaneIDs.paneIndex(for: ctlID), pIdx >= 0 && pIdx < state.panes.count {
                if state.panes[Int(pIdx)].pane.drawItem(dis) {
                    return 1
                }
            }
            if WinDark.drawButton(dis) { return 1 }
            return 0

        case Int32(bitPattern: WM_APP_PANE_RESULT):
            guard let state = getState(hwnd) else { return 0 }
            let paneIdx = Int(wParam)
            let slotID = Int(lParam)
            guard let slot = popAsyncSlot(id: slotID) else { return 0 }
            guard paneIdx >= 0 && paneIdx < state.panes.count else { return 0 }
            let entry = state.panes[paneIdx]
            // Drop stale or hidden result
            if slot.generation == entry.ctx.currentGeneration() && entry.descriptor.id == state.selectedPaneID {
                slot.thunk()
            }
            return 0

        case WM_CLOSE:
            guard let state = getState(hwnd) else {
                DestroyWindow(hwnd)
                return 0
            }
            var rc = RECT()
            GetWindowRect(hwnd, &rc)
            let w = rc.right - rc.left
            let h = rc.bottom - rc.top
            _ = try? WinSettingsStore.update {
                $0.windowWidth = w
                $0.windowHeight = h
                $0.lastPaneID = state.selectedPaneID
            }
            DestroyWindow(hwnd)
            return 0

        case WM_DESTROY:
            let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA)
            if ptr != 0 {
                Unmanaged<State>.fromOpaque(UnsafeMutableRawPointer(bitPattern: Int(ptr))!).release()
                SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0)
            }
            openHwnd = nil
            currentShell = nil
            clearAsyncSlots()
            return 0

        default:
            return DefWindowProcW(hwnd, msg, wParam, lParam)
        }
    }
}


/// Mouse-message coordinates are SIGNED 16-bit words packed in lParam.
/// `DWORD(lParam)` traps on a negative lParam — which is exactly what
/// arrives once the mouse is captured and dragged above/left of the
/// client area (`FleetWindow` already uses the truncating form).
private func mousePoint(_ lParam: LPARAM) -> POINT {
    POINT(x: Int32(Int16(truncatingIfNeeded: lParam)),
          y: Int32(Int16(truncatingIfNeeded: lParam >> 16)))
}
