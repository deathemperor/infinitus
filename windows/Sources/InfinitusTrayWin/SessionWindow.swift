import Foundation
import InfinitusCore
import WinSDK

// MARK: - Win32 Named Pipe Client
// Duplicated from windows/Sources/InfinitusWin/NamedPipeClient.swift because
// InfinitusWin and InfinitusTrayWin are separate executable targets and
// SwiftPM does not permit importing executable targets into one another.

private enum PipeClient {
    /// Writes payload to the named pipe with retry on ERROR_PIPE_BUSY.
    static func write(_ payload: Data, to path: String, timeout: TimeInterval = 5) -> Bool {
        guard !path.isEmpty, !payload.isEmpty else { return false }
        let wide = Array(path.utf16) + [0]
        let deadline = Date().addingTimeInterval(timeout)
        var handle = INVALID_HANDLE_VALUE
        repeat {
            handle = CreateFileW(wide, DWORD(GENERIC_WRITE), 0, nil,
                                 DWORD(OPEN_EXISTING), 0, nil)
            if handle != INVALID_HANDLE_VALUE { break }
            guard GetLastError() == DWORD(ERROR_PIPE_BUSY),
                  WaitNamedPipeW(wide, DWORD(200)) || Date() < deadline
            else { return false }
        } while Date() < deadline
        guard handle != INVALID_HANDLE_VALUE else { return false }
        defer { CloseHandle(handle) }

        var written = 0
        let ok = payload.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            while written < buffer.count {
                var wrote: DWORD = 0
                guard WriteFile(handle, base.advanced(by: written),
                                DWORD(buffer.count - written), &wrote, nil),
                      wrote > 0
                else { return false }
                written += Int(wrote)
            }
            return true
        }
        guard ok else { return false }
        FlushFileBuffers(handle)
        return true
    }

    /// Delivers `text` to session inbox using `PeerSocket.frames`.
    static func send(text: String, record: ClaudeSessionRecord, claudeDir: URL,
                     timeout: TimeInterval = 5) -> Bool {
        let payload = PeerSocket.frames(
            text: text,
            token: PeerSocket.peerToken(pid: record.pid, claudeDir: claudeDir),
            from: ownAddress())
        return write(payload, to: record.messagingSocketPath, timeout: timeout)
    }

    /// Pipe address for this tray process.
    static func ownAddress(pid: Int32 = Int32(GetCurrentProcessId())) -> String {
        PeerSocket.escapeAddress("\\\\.\\pipe\\LOCAL\\infinitus-\(pid)")
    }
}

// MARK: - Session Window Controller

final class SessionWindowState {
    let pid: Int32
    var name: String
    var hwnd: HWND?
    var feedHwnd: HWND?
    var inputHwnd: HWND?
    var sendHwnd: HWND?
    var statusHwnd: HWND?
    var font: HFONT?
    var origEditProc: WNDPROC?

    var lastStamp: String?
    var feedText: String = ""

    init(pid: Int32, name: String) {
        self.pid = pid
        self.name = name
    }

    deinit {
        if let font { DeleteObject(font) }
    }
}

public enum SessionWindow {
    private static let windowClassName = "InfinitusSessionWindow"
    private static var isClassRegistered = false
    private static var activeWindows: [Int32: SessionWindowState] = [:]

    private static let refreshTimerId: UINT_PTR = 101
    private static let refreshIntervalMs: UINT = 3000

    private static let sendButtonId: Int32 = 1001
    private static let feedEditId: Int32 = 1002
    private static let inputEditId: Int32 = 1003
    private static let statusStaticId: Int32 = 1004

    /// Opens (or focuses an existing) window for this session.
    public static func open(pid: Int32, name: String) {
        if let existing = activeWindows[pid], let hwnd = existing.hwnd, IsWindow(hwnd) {
            if IsIconic(hwnd) { ShowWindow(hwnd, SW_RESTORE) }
            SetForegroundWindow(hwnd)
            return
        }

        registerClassIfNeeded()

        let state = SessionWindowState(pid: pid, name: name)
        activeWindows[pid] = state

        let title = "\(name) — Session \(pid)"
        let titleWide = Array(title.utf16) + [0]
        let classWide = Array(windowClassName.utf16) + [0]
        let instance = GetModuleHandleW(nil)

        let statePtr = Unmanaged.passRetained(state).toOpaque()

        let hwnd = CreateWindowExW(
            DWORD(WS_EX_APPWINDOW),
            classWide,
            titleWide,
            DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_CLIPCHILDREN),
            CW_USEDEFAULT, CW_USEDEFAULT, 700, 500,
            nil, nil, instance, statePtr
        )

        guard let hwnd else {
            activeWindows.removeValue(forKey: pid)
            _ = Unmanaged<SessionWindowState>.fromOpaque(statePtr).takeRetainedValue()
            return
        }

        state.hwnd = hwnd
        ShowWindow(hwnd, SW_SHOW)
        UpdateWindow(hwnd)
        SetForegroundWindow(hwnd)

        // Initial feed load
        refreshFeed(state: state)
        SetTimer(hwnd, refreshTimerId, refreshIntervalMs, nil)
    }

    private static func registerClassIfNeeded() {
        guard !isClassRegistered else { return }
        let classWide = Array(windowClassName.utf16) + [0]
        let instance = GetModuleHandleW(nil)

        var wc = WNDCLASSW()
        wc.lpfnWndProc = sessionWndProc
        wc.hInstance = instance
        wc.hbrBackground = HBRUSH(bitPattern: Int(COLOR_BTNFACE + 1))
        wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512)) // IDC_ARROW
        classWide.withUnsafeBufferPointer { buf in
            wc.lpszClassName = buf.baseAddress
            _ = RegisterClassW(&wc)
        }
        isClassRegistered = true
    }

    // MARK: - WndProc

    private static let sessionWndProc: @convention(c) (HWND?, UINT, WPARAM, LPARAM) -> LRESULT = { hwnd, msg, wParam, lParam in
        guard let hwnd else { return DefWindowProcW(hwnd, msg, wParam, lParam) }

        if msg == UINT(WM_NCCREATE) {
            let cs = UnsafePointer<CREATESTRUCTW>(bitPattern: Int(lParam))
            if let ptr = cs?.pointee.lpCreateParams {
                SetWindowLongPtrW(hwnd, GWLP_USERDATA, LONG_PTR(Int(bitPattern: ptr)))
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam)
        }

        // GetWindowLongPtrW, not a Set/Set dance: writing 0 and putting
        // the old value back leaves USERDATA zeroed for any message that
        // arrives in between — WM_CREATE landed on a nil state and the
        // window came up with no controls at all (blank, 2026-09-04).
        let rawState = GetWindowLongPtrW(hwnd, GWLP_USERDATA)
        guard rawState != 0,
              let statePtr = UnsafeMutableRawPointer(bitPattern: Int(rawState))
        else {
            return DefWindowProcW(hwnd, msg, wParam, lParam)
        }
        let state = Unmanaged<SessionWindowState>.fromOpaque(statePtr).takeUnretainedValue()

        // Int32(msg) TRAPS: Windows sends messages above Int32.max (WM_APP
        // and registered messages), and an EDIT control gets plenty —
        // "Not enough bits to represent the passed value" killed the
        // window on its first paint (2026-09-04). Truncate the bits.
        switch Int32(bitPattern: msg) {
        case WM_CREATE:
            onCreate(hwnd: hwnd, state: state)
            return 0

        case WM_SIZE:
            let width = Int32(lParam & 0xFFFF)
            let height = Int32((lParam >> 16) & 0xFFFF)
            layoutControls(state: state, width: width, height: height)
            return 0

        case WM_COMMAND:
            let cmdId = Int32(wParam & 0xFFFF)
            let code = UINT((wParam >> 16) & 0xFFFF)
            if cmdId == sendButtonId && code == UINT(BN_CLICKED) {
                sendMessage(state: state)
            }
            return 0

        case WM_TIMER:
            if wParam == refreshTimerId {
                refreshFeed(state: state)
            }
            return 0

        case WM_CTLCOLORSTATIC:
            let hdc = HDC(bitPattern: Int(wParam))
            let childHwnd = HWND(bitPattern: Int(lParam))
            if childHwnd == state.feedHwnd {
                SetBkColor(hdc, GetSysColor(COLOR_WINDOW))
                // A brush handle's high bit is often set, so the pointer
                // doesn't fit LRESULT's signed range: LRESULT(Int(...))
                // traps ("Not enough bits to represent the passed value"
                // — it killed the window on first paint, 2026-09-04).
                // Reinterpret the bits instead of range-checking them.
                return LRESULT(bitPattern: UInt64(UInt(bitPattern: GetSysColorBrush(COLOR_WINDOW))))
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam)

        case WM_DESTROY:
            KillTimer(hwnd, refreshTimerId)
            activeWindows.removeValue(forKey: state.pid)
            // Balance retain from CreateWindowExW
            _ = Unmanaged<SessionWindowState>.fromOpaque(statePtr).takeRetainedValue()
            return 0

        default:
            return DefWindowProcW(hwnd, msg, wParam, lParam)
        }
    }

    // MARK: - Input Subclassing for Enter key

    private static let inputSubclassProc: @convention(c) (HWND?, UINT, WPARAM, LPARAM) -> LRESULT = { hwnd, msg, wParam, lParam in
        guard let hwnd else { return 0 }
        // GetWindowLongPtrW, not a Set/Set dance: writing 0 and putting
        // the old value back leaves USERDATA zeroed for any message that
        // arrives in between — WM_CREATE landed on a nil state and the
        // window came up with no controls at all (blank, 2026-09-04).
        let rawState = GetWindowLongPtrW(hwnd, GWLP_USERDATA)
        guard rawState != 0,
              let statePtr = UnsafeMutableRawPointer(bitPattern: Int(rawState))
        else {
            return CallWindowProcW(nil, hwnd, msg, wParam, lParam)
        }
        let state = Unmanaged<SessionWindowState>.fromOpaque(statePtr).takeUnretainedValue()
        let origProc = state.origEditProc

        // Int32(msg) TRAPS: Windows sends messages above Int32.max (WM_APP
        // and registered messages), and an EDIT control gets plenty —
        // "Not enough bits to represent the passed value" killed the
        // window on its first paint (2026-09-04). Truncate the bits.
        switch Int32(bitPattern: msg) {
        case WM_KEYDOWN:
            if wParam == WPARAM(VK_RETURN) {
                sendMessage(state: state)
                return 0
            }
        case WM_CHAR:
            // Suppress beep on Enter
            if wParam == WPARAM(VK_RETURN) {
                return 0
            }
        default:
            break
        }

        return CallWindowProcW(origProc, hwnd, msg, wParam, lParam)
    }

    // MARK: - Control Creation & Layout

    private static func onCreate(hwnd: HWND, state: SessionWindowState) {
        let instance = GetModuleHandleW(nil)

        // Segoe UI font 9pt (~12px height)
        state.font = CreateFontW(
            -12, 0, 0, 0, FW_NORMAL, 0, 0, 0,
            DWORD(DEFAULT_CHARSET),
            DWORD(OUT_DEFAULT_PRECIS),
            DWORD(CLIP_DEFAULT_PRECIS),
            DWORD(CLEARTYPE_QUALITY),
            DWORD(DEFAULT_PITCH | FF_DONTCARE),
            Array("Segoe UI".utf16) + [0]
        )

        let editClass = Array("EDIT".utf16) + [0]
        let buttonClass = Array("BUTTON".utf16) + [0]
        let staticClass = Array("STATIC".utf16) + [0]

        // Feed EDIT control
        let feedHwnd = CreateWindowExW(
            DWORD(WS_EX_CLIENTEDGE),
            editClass,
            nil,
            DWORD(WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL | ES_READONLY),
            0, 0, 0, 0,
            hwnd, HMENU(bitPattern: Int(feedEditId)), instance, nil
        )
        state.feedHwnd = feedHwnd
        SendMessageW(feedHwnd, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: state.font)), LPARAM(1))

        // Input single-line EDIT
        let inputHwnd = CreateWindowExW(
            DWORD(WS_EX_CLIENTEDGE),
            editClass,
            nil,
            DWORD(WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL | WS_TABSTOP),
            0, 0, 0, 0,
            hwnd, HMENU(bitPattern: Int(inputEditId)), instance, nil
        )
        state.inputHwnd = inputHwnd
        SendMessageW(inputHwnd, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: state.font)), LPARAM(1))

        // Send BUTTON
        let sendText = Array("Send".utf16) + [0]
        let sendHwnd = CreateWindowExW(
            0,
            buttonClass,
            sendText,
            DWORD(WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON | WS_TABSTOP),
            0, 0, 0, 0,
            hwnd, HMENU(bitPattern: Int(sendButtonId)), instance, nil
        )
        state.sendHwnd = sendHwnd
        SendMessageW(sendHwnd, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: state.font)), LPARAM(1))

        // Status STATIC label
        let statusHwnd = CreateWindowExW(
            0,
            staticClass,
            nil,
            DWORD(WS_CHILD | WS_VISIBLE | SS_LEFT),
            0, 0, 0, 0,
            hwnd, HMENU(bitPattern: Int(statusStaticId)), instance, nil
        )
        state.statusHwnd = statusHwnd
        SendMessageW(statusHwnd, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: state.font)), LPARAM(1))

        // Subclass input edit for Enter key
        if let inputHwnd {
            let statePtr = Unmanaged.passUnretained(state).toOpaque()
            SetWindowLongPtrW(inputHwnd, GWLP_USERDATA, LONG_PTR(Int(bitPattern: statePtr)))
            let fnPtr = unsafeBitCast(inputSubclassProc, to: LONG_PTR.self)
            let oldProc = SetWindowLongPtrW(inputHwnd, GWLP_WNDPROC, fnPtr)
            state.origEditProc = unsafeBitCast(oldProc, to: WNDPROC.self)
        }
    }

    private static func layoutControls(state: SessionWindowState, width: Int32, height: Int32) {
        let padding: Int32 = 10
        let buttonWidth: Int32 = 75
        let rowHeight: Int32 = 26
        let statusHeight: Int32 = 18

        let bottomRowY = height - padding - rowHeight
        let statusY = bottomRowY - statusHeight - 4
        let feedHeight = statusY - padding - 4

        let feedWidth = width - 2 * padding
        let inputWidth = width - 3 * padding - buttonWidth
        let buttonX = width - padding - buttonWidth

        if let feed = state.feedHwnd {
            MoveWindow(feed, padding, padding, max(0, feedWidth), max(0, feedHeight), true)
        }
        if let status = state.statusHwnd {
            MoveWindow(status, padding, statusY, max(0, feedWidth), statusHeight, true)
        }
        if let input = state.inputHwnd {
            MoveWindow(input, padding, bottomRowY, max(0, inputWidth), rowHeight, true)
        }
        if let send = state.sendHwnd {
            MoveWindow(send, buttonX, bottomRowY, buttonWidth, rowHeight, true)
        }
    }

    // MARK: - Feed Rendering & Scroll Preservation

    private static func refreshFeed(state: SessionWindowState) {
        let claudeDir = ClaudeSessions.configHome()
        guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == state.pid }) else {
            setStatus(state: state, text: "Session \(state.pid) ended")
            return
        }

        let feedOpt = SessionFeedReader.read(record: record, claudeDir: claudeDir, limit: 40)
        guard let feed = feedOpt else { return }

        // Update status text
        let status = feed.status ?? record.status ?? "unknown"
        let permMode = feed.permissionMode.map { " (\($0))" } ?? ""
        setStatus(state: state, text: "Status: \(status)\(permMode)")

        // Only update feed control if stamp changed
        if let stamp = feed.stamp, stamp == state.lastStamp {
            return
        }
        state.lastStamp = feed.stamp

        let rendered = renderFeedItems(feed.items)
        guard rendered != state.feedText else { return }
        state.feedText = rendered

        guard let edit = state.feedHwnd else { return }

        // Query scroll position and line count to check if user was at bottom
        let firstVisibleLine = SendMessageW(edit, UINT(EM_GETFIRSTVISIBLELINE), 0, 0)
        let totalLines = SendMessageW(edit, UINT(EM_GETLINECOUNT), 0, 0)

        // Set text
        let wideText = Array(rendered.utf16) + [0]
        SetWindowTextW(edit, wideText)

        // If user was scrolled near bottom or initially, keep scrolled to bottom
        let wasAtBottom = (totalLines <= 1) || (firstVisibleLine + 25 >= totalLines)
        if wasAtBottom {
            SendMessageW(edit, UINT(EM_SETSEL), WPARAM(wideText.count), LPARAM(wideText.count))
            SendMessageW(edit, UINT(EM_SCROLLCARET), 0, 0)
            SendMessageW(edit, UINT(WM_VSCROLL), WPARAM(SB_BOTTOM), 0)
        } else {
            // Restore scroll line
            let linesToScroll = firstVisibleLine
            SendMessageW(edit, UINT(EM_LINESCROLL), 0, LPARAM(linesToScroll))
        }
    }

    public static func renderFeedItems(_ items: [SessionFeedItem]) -> String {
        var lines: [String] = []
        for item in items {
            let label: String
            switch item.kind {
            case .user: label = "user"
            case .assistant: label = "assistant"
            case .tool:
                let name = item.toolName ?? "tool"
                label = "tool (\(name))"
            case .question: label = "question"
            case .permission: label = "permission"
            case .result: label = "result"
            case .limit: label = "limit"
            case .agent:
                let name = item.toolName ?? "agent"
                label = "agent (\(name))"
            }

            // Normalise newlines to \r\n for Win32 EDIT control
            let body = item.text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n", with: "\r\n")

            lines.append("[\(label)] \(body)")
        }
        return lines.joined(separator: "\r\n\r\n")
    }

    private static func setStatus(state: SessionWindowState, text: String) {
        guard let statusHwnd = state.statusHwnd else { return }
        let wide = Array(text.utf16) + [0]
        SetWindowTextW(statusHwnd, wide)
    }

    // MARK: - Sending Messages

    private static func sendMessage(state: SessionWindowState) {
        guard let inputHwnd = state.inputHwnd else { return }

        let len = GetWindowTextLengthW(inputHwnd)
        guard len > 0 else { return }

        var buffer = [WCHAR](repeating: 0, count: Int(len + 1))
        GetWindowTextW(inputHwnd, &buffer, Int32(buffer.count))
        let text = String(decodingCString: buffer, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let claudeDir = ClaudeSessions.configHome()
        guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == state.pid }) else {
            setStatus(state: state, text: "Error: session \(state.pid) not found")
            return
        }

        guard !record.messagingSocketPath.isEmpty else {
            setStatus(state: state, text: "Error: session has no messaging pipe")
            return
        }

        // Deliver to named pipe
        let ok = PipeClient.send(text: text, record: record, claudeDir: claudeDir)
        if ok {
            // Clear input box
            let empty = [WCHAR](repeating: 0, count: 1)
            SetWindowTextW(inputHwnd, empty)

            // Append local line immediately
            appendLocalFeedLine(state: state, text: "[you] \(text)")
            setStatus(state: state, text: "Message sent")
        } else {
            setStatus(state: state, text: "Send failed: pipe write refused")
        }
    }

    private static func appendLocalFeedLine(state: SessionWindowState, text: String) {
        guard let edit = state.feedHwnd else { return }

        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")

        let addition = (state.feedText.isEmpty ? "" : "\r\n\r\n") + normalized
        state.feedText += addition

        let len = SendMessageW(edit, UINT(WM_GETTEXTLENGTH), 0, 0)
        SendMessageW(edit, UINT(EM_SETSEL), WPARAM(len), LPARAM(len))
        let wide = Array(addition.utf16) + [0]
        _ = wide.withUnsafeBufferPointer { buf in
            SendMessageW(edit, UINT(EM_REPLACESEL), 0, LPARAM(Int(bitPattern: buf.baseAddress)))
        }
        SendMessageW(edit, UINT(EM_SCROLLCARET), 0, 0)
        SendMessageW(edit, UINT(WM_VSCROLL), WPARAM(SB_BOTTOM), 0)
    }

    // MARK: - Testing / Helper Entrypoint

    /// Helper callable for manual testing or headless diagnostics.
    public static func testRun(pid: Int32) -> Int32 {
        let claudeDir = ClaudeSessions.configHome()
        guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == pid }) else {
            print("SessionWindow test: pid \(pid) not found")
            return 1
        }
        let feed = SessionFeedReader.read(record: record, claudeDir: claudeDir, limit: 40)
        print("SessionWindow test: pid \(pid), name: \(record.name ?? "nil"), stamp: \(feed?.stamp ?? "nil"), items: \(feed?.items.count ?? 0)")
        return 0
    }
}
