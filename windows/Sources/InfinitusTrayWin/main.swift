// infinitus-tray-win — the notification-area companion to the mirror
// daemon. It shows what this box's Claude Code sessions are doing, and
// gets you to them: click a session to raise its terminal, copy the
// pairing URL for the phone, start or stop `infinitus-win serve`.
//
// Deliberately NOT a port of the Mac app: AppKit/SwiftUI don't exist
// here, so there is no shared view code — only InfinitusCore underneath.
// Accounts and usage stay out of this window; when a swap engine is
// installed the phone and `infinitus-win snapshot` already show them.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import InfinitusCore
import InfinitusWinUI
import WinSDK

/// Tray callback message (WM_APP+1) and the menu command id base.
let trayMessage = UINT(WM_APP) + 1
/// Posted by a background switch when the engine has answered, so the
/// balloon goes up on the thread that owns the window.
let engineReportMessage = UINT(WM_APP) + 2
/// Posted when background auto-update check discovers a new release.
let updateCheckMessage = UINT(WM_APP) + 3
let timerUpdateCheckID: UINT_PTR = 2
let timerUpdateCheckIntervalMs: UINT = 6 * 3600 * 1000 // 6 hours
let commandBase: UINT = 0x1000
/// Fixed command ids, above any session row.
let commandCopyPair: UINT = 0x0F01
let commandToggleServe: UINT = 0x0F02
let commandRefresh: UINT = 0x0F03
let commandExit: UINT = 0x0F04
let commandAutostart: UINT = 0x0F05
let commandRotate: UINT = 0x0F06
let commandAccountPanel: UINT = 0x0F07
let commandSettings: UINT = 0x0F08
/// Session row + this offset raises that session's terminal instead of
/// opening its window (the submenu's second entry).
let commandRaiseBase: UINT = 0x2000
/// Account row + this offset switches to that account. Above the session
/// range so the two can never collide.
let commandAccountBase: UINT = 0x3000
/// Re-read sessions this often. Every tick tails transcripts, so this is
/// the one knob that decides idle cost (CLAUDE.md: keep it near zero).
let refreshMilliseconds: UINT = 5000

/// One row in the menu: what the session is and how to reach it.
struct SessionRow {
    let pid: Int32
    let name: String
    let status: String
    let folder: String
}

/// Everything the window procedure needs. A single instance lives for the
/// process; Win32 callbacks are C function pointers, so it can't be
/// captured — hence a global rather than an object graph.
final class TrayState {
    var window: HWND?
    var icon: HICON?
    var rows: [SessionRow] = []
    var busy = 0
    /// Last tick's pid → status, so a balloon fires on a real change and
    /// not on every refresh. Empty until the first refresh has run.
    var lastStatuses: [Int32: String] = [:]
    /// The account each account-row command id switches to, rebuilt every
    /// time the menu opens (the list can change between opens).
    var accountCommands: [UINT: Int] = [:]
    /// Engine replies waiting to be shown, written by a worker thread and
    /// drained by the window procedure — hence the lock.
    let pending = NSLock()
    var pendingReports: [String] = []
    var pendingUpdateTag: String? = nil
    /// The `infinitus-win serve` child, when this tray started one. A
    /// daemon someone else started is not ours to stop.
    var daemon: Process?

    var serving: Bool { daemon?.isRunning == true }
}

let state = TrayState()

// MARK: - session reading

/// The live sessions, newest status first. Pure InfinitusCore: the same
/// records the daemon serves, so the tray can never disagree with the
/// phone about what is running.
func readSessions() -> ([SessionRow], busy: Int) {
    let claudeDir = ClaudeSessions.configHome()
    let records = ClaudeSessions.list(claudeDir: claudeDir)
    var rows: [SessionRow] = []
    var busy = 0
    for record in records {
        let status = record.status ?? "unknown"
        if status == "busy" { busy += 1 }
        let progress = SessionProgress.read(sessionId: record.sessionId, cwd: record.cwd,
                                            claudeDir: claudeDir, name: record.name)
        let folder = URL(fileURLWithPath: record.cwd).lastPathComponent
        rows.append(SessionRow(pid: record.pid,
                               name: progress.name ?? record.name ?? "session \(record.pid)",
                               status: status, folder: folder))
    }
    // Busy first, then waiting, then the rest — the Mac's panel order.
    let rank = { (status: String) -> Int in
        switch status {
        case "busy": return 0
        case "waiting": return 1
        default: return 2
        }
    }
    rows.sort { rank($0.status) < rank($1.status) }
    return (rows, busy)
}

// MARK: - raising a session's terminal

/// Brings the window of the process that owns `pid` to the front, walking
/// up to its console host when the session itself owns none. Returns
/// false when there is nothing to raise — the caller stays silent rather
/// than claiming it worked.
func raiseWindow(pid: Int32) -> Bool {
    final class Search {
        let wanted: DWORD
        var found: HWND?
        init(wanted: DWORD) { self.wanted = wanted }
    }
    let search = Search(wanted: DWORD(UInt32(bitPattern: pid)))
    let callback: @convention(c) (HWND?, LPARAM) -> WindowsBool = { window, param in
        guard let window, IsWindowVisible(window) else { return true }
        guard let raw = UnsafeMutableRawPointer(bitPattern: Int(param)) else { return false }
        let search = Unmanaged<Search>.fromOpaque(raw).takeUnretainedValue()
        var owner: DWORD = 0
        GetWindowThreadProcessId(window, &owner)
        guard owner == search.wanted else { return true }
        search.found = window
        return false
    }
    let pointer = Unmanaged.passUnretained(search).toOpaque()
    EnumWindows(callback, LPARAM(Int(bitPattern: pointer)))
    guard let window = search.found else { return false }
    if IsIconic(window) { ShowWindow(window, SW_RESTORE) }
    return SetForegroundWindow(window)
}

// MARK: - the daemon child

/// Starts `infinitus-win serve` beside this binary. The tray only ever
/// stops a daemon it started itself.
func startDaemon() {
    guard state.daemon?.isRunning != true else { return }
    // Someone else's daemon may already hold the port — one started by
    // hand, or an installed copy at login. Starting a second one lets it
    // steal the listening socket, and the survivor is whichever bound
    // last: that is how a `--auto-resume` daemon got silently replaced by
    // one without it (2026-09-04). Refuse instead.
    if daemonAlreadyServing() {
        postEngineReport("a mirror daemon is already serving port \(defaultMirrorPort)")
        return
    }
    let binary = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent()
        .appendingPathComponent("infinitus-win.exe")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else { return }
    let process = Process()
    process.executableURL = binary
    process.arguments = ["serve"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return }
    state.daemon = process
}

func stopDaemon() {
    guard let daemon = state.daemon, daemon.isRunning else { return }
    daemon.terminate()
    state.daemon = nil
}

/// The mirror port the daemon serves by default — matched to
/// `defaultMirrorPort` in the daemon's own main.swift (separate targets,
/// so the constant can't be shared without moving it into core).
let defaultMirrorPort: UInt16 = 47824

/// Whether something already listens on the mirror port.
///
/// Read from the IP helper's TCP table rather than by connecting: this
/// target never calls WSAStartup (only the daemon's WinHTTPServer does),
/// so a socket() here returns INVALID_SOCKET and every probe would answer
/// "nothing is serving" — the silent false negative that let a second
/// daemon start. GetTcpTable2 needs no Winsock init.
func daemonAlreadyServing(port: UInt16 = defaultMirrorPort) -> Bool {
    var size: ULONG = 0
    // First call sizes the buffer; ERROR_INSUFFICIENT_BUFFER is expected.
    _ = GetTcpTable2(nil, &size, false)
    guard size > 0 else { return false }
    let buffer = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size), alignment: MemoryLayout<MIB_TCPTABLE2>.alignment)
    defer { buffer.deallocate() }
    let table = buffer.assumingMemoryBound(to: MIB_TCPTABLE2.self)
    guard GetTcpTable2(table, &size, false) == NO_ERROR else { return false }

    let count = Int(table.pointee.dwNumEntries)
    // dwTable is a 1-element tail array; walk it as `count` rows.
    return withUnsafePointer(to: &table.pointee.table) { rows in
        let base = UnsafeRawPointer(rows).assumingMemoryBound(to: MIB_TCPROW2.self)
        for index in 0..<count {
            let row = base[index]
            // dwLocalPort is in network byte order.
            let localPort = UInt16(truncatingIfNeeded: row.dwLocalPort).byteSwapped
            if row.dwState == UInt32(MIB_TCP_STATE_LISTEN.rawValue), localPort == port {
                return true
            }
        }
        return false
    }
}

// MARK: - tray icon plumbing

func notifyData(_ window: HWND, tip: String? = nil) -> NOTIFYICONDATAW {
    var data = NOTIFYICONDATAW()
    data.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
    data.hWnd = window
    data.uID = 1
    data.uFlags = UINT(NIF_ICON | NIF_MESSAGE | NIF_TIP)
    data.uCallbackMessage = trayMessage
    data.hIcon = state.icon
    if let tip {
        // szTip is a fixed 128-WCHAR tuple; fill it through a buffer.
        withUnsafeMutableBytes(of: &data.szTip) { raw in
            let slot = raw.bindMemory(to: WCHAR.self)
            let text = Array(tip.utf16.prefix(slot.count - 1)) + [0]
            for (index, unit) in text.enumerated() { slot[index] = unit }
        }
    }
    return data
}

/// Re-reads sessions, then repaints icon and tooltip.
func refresh() {
    let (rows, busy) = readSessions()
    state.rows = rows
    state.busy = busy
    guard let window = state.window else { return }

    // Announce only what the user would want pulled away for: a session
    // now waiting on them, or one that died mid-turn.
    let settings = WinSettingsStore.load()
    let statuses = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0.status) })
    let names = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0.name) })
    if settings.trayBalloonsEnabled {
        for line in TrayNotify.transitions(previous: state.lastStatuses,
                                           current: statuses, names: names) {
            TrayNotify.balloon(window, title: "Infinitus", body: line)
        }
    }
    state.lastStatuses = statuses

    // Keep Windows awake while sessions are working
    if settings.keepAwake {
        if busy > 0 {
            SetThreadExecutionState(DWORD(ES_CONTINUOUS | ES_SYSTEM_REQUIRED))
        } else {
            SetThreadExecutionState(DWORD(ES_CONTINUOUS))
        }
    } else {
        SetThreadExecutionState(DWORD(ES_CONTINUOUS))
    }
    let wasBusy = state.icon != nil && busy > 0
    if let fresh = TrayIcon.make(busy: busy > 0) {
        let previous = state.icon
        state.icon = fresh
        if previous != nil { DestroyIcon(previous) }
        _ = wasBusy
    }
    let tip = busy > 0 ? "\(rows.count) sessions · \(busy) busy"
                       : "\(rows.count) sessions · idle"
    var data = notifyData(window, tip: tip)
    Shell_NotifyIconW(DWORD(NIM_MODIFY), &data)
}

/// Right-click menu: a row per session, then the actions.
func showMenu(_ window: HWND) {
    guard let menu = CreatePopupMenu() else { return }
    defer { DestroyMenu(menu) }
    if state.rows.isEmpty {
        AppendMenuW(menu, UINT(MF_STRING | MF_GRAYED), 0, "no live sessions".wide)
    }
    for (index, row) in state.rows.enumerated() {
        let label = "\(row.name) — \(row.status) — \(row.folder)"
        // Each session is a submenu: open its window, or jump to the
        // terminal it is already running in.
        if let submenu = CreatePopupMenu() {
            AppendMenuW(submenu, UINT(MF_STRING),
                        UINT_PTR(commandBase + UINT(index)), "Open session window".wide)
            AppendMenuW(submenu, UINT(MF_STRING),
                        UINT_PTR(commandRaiseBase + UINT(index)), "Show its terminal".wide)
            AppendMenuW(menu, UINT(MF_STRING | MF_POPUP),
                        UINT_PTR(UInt(bitPattern: Int(bitPattern: submenu))), label.wide)
        } else {
            AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(commandBase + UINT(index)), label.wide)
        }
    }
    // Accounts, when a swap engine is installed. Absent engine means no
    // section at all rather than a row of zeros. Clicking a row asks the
    // engine to switch to it — the engine decides, we forward and report.
    state.accountCommands = [:]
    if TrayFleet.hasEngine() {
        AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
        var slot: UINT = 0
        for line in TrayFleet.menuLines() {
            var id: UINT_PTR = 0
            if line.enabled, let account = line.account {
                let command = commandAccountBase + slot
                state.accountCommands[command] = account
                id = UINT_PTR(command)
                slot += 1
            }
            AppendMenuW(menu, UINT(MF_STRING | (line.enabled ? MF_ENABLED : MF_GRAYED)),
                        id, line.text.wide)
        }
        // Rotation target is the engine's own next pick, not ours.
        AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(commandRotate),
                    "Switch to next account".wide)
    }
    // The panel is offered whatever the engine situation, OUTSIDE the
    // block above: with no engine or no accounts it is the thing that
    // explains why (FleetLayout's empty states say what to run), and
    // hiding it exactly when the user has nothing to look at is the
    // wrong way round.
    AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
    AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(commandAccountPanel),
                "Open accounts panel\u{2026}".wide)
    AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(commandSettings),
                "Settings\u{2026}".wide)
    AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
    AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(commandCopyPair), "Copy pairing URL".wide)
    AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(commandToggleServe),
                (state.serving ? "Stop mirror daemon" : "Start mirror daemon").wide)
    AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(commandRefresh), "Refresh".wide)
    let autostart = TrayAutostart.isEnabled()
    AppendMenuW(menu, UINT(MF_STRING | (autostart ? MF_CHECKED : MF_UNCHECKED)),
                UINT_PTR(commandAutostart), "Start with Windows".wide)
    AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
    AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(commandExit), "Exit".wide)

    var point = POINT()
    GetCursorPos(&point)
    // Required so the menu dismisses when focus goes elsewhere.
    SetForegroundWindow(window)
    TrackPopupMenu(menu, UINT(TPM_RIGHTBUTTON), point.x, point.y, 0, window, nil)
    PostMessageW(window, UINT(WM_NULL), 0, 0)
}

/// Asks the engine to switch and balloons whatever it answers. The shell
/// out runs off the UI thread — `cswap switch` may refresh a token, and a
/// blocked window procedure would freeze the whole tray.
///
/// The reply comes back by POSTING a message, not via DispatchQueue.main:
/// this process pumps a Win32 `GetMessageW` loop and never drains the
/// main queue, so a dispatched block would simply never run.
func switchAccount(to account: Int?) {
    TrayFleet.requestSwitch(to: account) { message in
        postEngineReport(message)
    }
}

/// Hands an engine reply to the tray window for display. Called from
/// worker threads (the menu's switch, the account panel's), so it queues
/// the text under a lock and POSTS — this process pumps a Win32
/// GetMessageW loop and never drains DispatchQueue.main, so a dispatched
/// block would simply never run.
func checkUpdateAsync(window: HWND) {
    let settings = WinSettingsStore.load()
    let now = Date().timeIntervalSince1970
    guard UpdateLogicWin.shouldCheck(lastCheck: settings.appUpdateLastCheck, now: now, enabled: settings.updateAutoCheck) else {
        return
    }

    Thread.detachNewThread {
        guard let url = URL(string: "https://api.github.com/repos/deathemperor/infinitus/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Infinitus-Win/\(InfinitusVersion.current)", forHTTPHeaderField: "User-Agent")

        let sema = DispatchSemaphore(value: 0)
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: req) { data, response, _ in
            defer { sema.signal() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else { return }
            struct Release: Decodable { let tag_name: String }
            guard let rel = try? JSONDecoder().decode(Release.self, from: data) else { return }
            let tag = UpdateLogicWin.normalizeTag(rel.tag_name)
            let curr = InfinitusVersion.current
            let s = WinSettingsStore.load()
            if UpdateLogicWin.isUpdateAvailable(current: curr, latest: tag) &&
               UpdateLogicWin.shouldNotify(latest: tag, lastNotified: s.appUpdateNotifiedVersion) {
                state.pending.lock()
                state.pendingUpdateTag = tag
                state.pending.unlock()
                PostMessageW(window, updateCheckMessage, 0, 0)
            }
            _ = try? WinSettingsStore.update {
                $0.appUpdateLastCheck = Date().timeIntervalSince1970
            }
        }
        task.resume()
        sema.wait()
    }
}

func postEngineReport(_ message: String) {
    state.pending.lock()
    state.pendingReports.append(message)
    state.pending.unlock()
    if let window = state.window {
        PostMessageW(window, engineReportMessage, 0, 0)
    }
}

func handleCommand(_ id: UINT) {
    switch id {
    case commandExit:
        DestroyWindow(state.window)
    case commandRefresh:
        refresh()
    case commandCopyPair:
        if let url = WinPairing.pairingURL() { WinPairing.setClipboardText(url) }
    case commandToggleServe:
        state.serving ? stopDaemon() : startDaemon()
    case commandAutostart:
        TrayAutostart.setEnabled(!TrayAutostart.isEnabled())
    case commandRotate:
        switchAccount(to: nil)
    case commandAccountPanel:
        FleetWindow.show()
    case commandSettings:
        SettingsWindow.show()
    case commandAccountBase..<(commandAccountBase + 0x1000):
        guard let account = state.accountCommands[id] else { return }
        switchAccount(to: account)
    case commandRaiseBase..<(commandRaiseBase + 0x1000):
        let index = Int(id - commandRaiseBase)
        if index >= 0, index < state.rows.count {
            _ = raiseWindow(pid: state.rows[index].pid)
        }
    default:
        let index = Int(id - commandBase)
        guard index >= 0, index < state.rows.count else { return }
        let row = state.rows[index]
        // The session window is the point of the desktop app: the feed
        // and a composer, without reaching for a phone.
        SessionWindow.open(pid: row.pid, name: row.name)
    }
}

// MARK: - window procedure

let windowProc: @convention(c) (HWND?, UINT, WPARAM, LPARAM) -> LRESULT = {
    window, message, wParam, lParam in
    // Bit-truncate rather than range-check: Windows sends messages above
    // Int32.max (WM_APP+, registered messages) and Int32(_:) traps on
    // them — the same crash that killed the session window's EDIT.
    switch Int32(bitPattern: message) {
    case Int32(trayMessage):
        // A right-click (or the keyboard context key) opens the menu; a
        // left-click refreshes so the list is current before you look.
        let event = Int32(lParam & 0xFFFF)
        if event == WM_RBUTTONUP || event == WM_CONTEXTMENU {
            if let window { showMenu(window) }
        } else if event == WM_LBUTTONUP {
            refresh()
            if let window { showMenu(window) }
        }
        return 0
    case Int32(engineReportMessage):
        // An engine reply landed. Show it, and refresh so the menu's
        // active marker matches what just happened.
        state.pending.lock()
        let reports = state.pendingReports
        state.pendingReports = []
        state.pending.unlock()
        if let window {
            for report in reports {
                TrayNotify.balloon(window, title: "Infinitus", body: report)
            }
        }
        if !reports.isEmpty { refresh() }
        return 0
    case Int32(updateCheckMessage):
        state.pending.lock()
        let newTag = state.pendingUpdateTag
        state.pendingUpdateTag = nil
        state.pending.unlock()
        if let window, let tag = newTag {
            TrayNotify.balloon(window, title: "Infinitus", body: "Infinitus \(tag) is available")
            _ = try? WinSettingsStore.update {
                $0.appUpdateNotifiedVersion = tag
            }
        }
        return 0
    case WM_COMMAND:
        handleCommand(UINT(wParam & 0xFFFF))
        return 0
    case WM_TIMER:
        if wParam == timerUpdateCheckID {
            if let window { checkUpdateAsync(window: window) }
            return 0
        }
        refresh()
        // Engine data refreshes off the same tick, in the background —
        // the menu must never wait on a subprocess to open.
        TrayFleet.refresh()
        // The account panel rides this tick rather than running a timer
        // of its own, and only while it is actually on screen: an idle
        // panel must cost nothing (CLAUDE.md's idle-CPU rule).
        if FleetWindow.isOpen { FleetWindow.refresh() }
        return 0
    case WM_DESTROY:
        // Never leave a ghost icon behind.
        if let window {
            var data = notifyData(window)
            Shell_NotifyIconW(DWORD(NIM_DELETE), &data)
        }
        stopDaemon()
        PostQuitMessage(0)
        return 0
    default:
        return DefWindowProcW(window, message, wParam, lParam)
    }
}

// MARK: - entry

extension String {
    /// A null-terminated UTF-16 buffer for the W APIs. Valid for the
    /// duration of the call it is passed to.
    var wide: [WCHAR] { Array(utf16) + [0] }
}

let infinitusTrayWinVersion = InfinitusVersion.current

func run() -> Int32 {
    let firstArg = CommandLine.arguments.dropFirst().first
    if firstArg == "--version" || firstArg == "-V" {
        print("infinitus-tray-win \(infinitusTrayWinVersion)")
        return 0
    }

    // 1. DPI awareness as first statement before any CreateWindowExW
    _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)

    // 2. InitCommonControlsEx for modern controls
    var icc = INITCOMMONCONTROLSEX()
    icc.dwSize = DWORD(MemoryLayout<INITCOMMONCONTROLSEX>.size)
    icc.dwICC = DWORD(ICC_STANDARD_CLASSES | ICC_UPDOWN_CLASS | ICC_PROGRESS_CLASS | ICC_LISTVIEW_CLASSES)
    _ = InitCommonControlsEx(&icc)

    // `--probe` reports what the tray can build and exits — the icon and
    // the shell call are invisible from another session, so this is how
    // a failure gets diagnosed without a human watching the taskbar.
    // `--session <pid>` opens one session window and runs its own message
    // loop — the tray's own path without the tray, so the window can be
    // exercised (and seen) directly.
    if CommandLine.arguments.dropFirst().first == "--session" {
        guard let pidText = CommandLine.arguments.dropFirst(2).first,
              let pid = Int32(pidText) else {
            print("usage: infinitus-tray-win --session <pid>")
            return 2
        }
        let (rows, _) = readSessions()
        guard let row = rows.first(where: { $0.pid == pid }) else {
            print("no live session with pid \(pid)")
            return 1
        }
        SessionWindow.open(pid: row.pid, name: row.name)
        var message = MSG()
        while GetMessageW(&message, nil, 0, 0) {
            TranslateMessage(&message)
            DispatchMessageW(&message)
        }
        return 0
    }
    // `--settings [paneID]` opens the settings window alone, with its own message loop.
    if CommandLine.arguments.dropFirst().first == "--settings" {
        let targetPane = CommandLine.arguments.dropFirst(2).first
        SettingsWindow.show(paneID: targetPane)
        var message = MSG()
        while GetMessageW(&message, nil, 0, 0) {
            if SettingsShell.handles(&message) { continue }
            TranslateMessage(&message)
            DispatchMessageW(&message)
        }
        return 0
    }
    // `--panel` opens the accounts panel alone, with its own message
    // loop — the tray's path without the tray, so the window can be
    // exercised (and screenshotted) directly.
    if CommandLine.arguments.dropFirst().first == "--panel" {
        FleetWindow.show()
        var message = MSG()
        while GetMessageW(&message, nil, 0, 0) {
            TranslateMessage(&message)
            DispatchMessageW(&message)
        }
        return 0
    }
    if CommandLine.arguments.dropFirst().first == "--probe" {
        let icon = TrayIcon.make(busy: true)
        print("icon: \(icon == nil ? "FAILED" : "ok")")
        if let icon { DestroyIcon(icon) }
        let (rows, busy) = readSessions()
        print("sessions: \(rows.count) (\(busy) busy)")
        print("pair url: \(WinPairing.pairingURL() ?? "none — run `infinitus-win pair` first")")
        print("autostart: \(TrayAutostart.isEnabled() ? "on" : "off")")
        // The balloon rules, exercised — this decides when the user gets
        // interrupted, and the target can't be unit tested (executables
        // can't be imported by a test target).
        let names: [Int32: String] = [1: "alpha", 2: "beta"]
        let cases: [(String, [Int32: String], [Int32: String], Int)] = [
            ("first tick stays silent", [:], [1: "waiting", 2: "busy"], 0),
            ("idle → waiting announces", [1: "idle"], [1: "waiting"], 1),
            ("busy → idle stays silent", [1: "busy"], [1: "idle"], 0),
            ("still waiting stays silent", [1: "waiting"], [1: "waiting"], 0),
            ("busy → gone announces", [1: "busy"], [:], 1),
            ("idle → gone stays silent", [1: "idle"], [:], 0),
            ("new session already waiting stays silent", [2: "idle"], [1: "waiting", 2: "idle"], 0),
        ]
        var failures = 0
        for (label, previous, current, expected) in cases {
            let lines = TrayNotify.transitions(previous: previous, current: current, names: names)
            let ok = lines.count == expected
            if !ok { failures += 1 }
            print("  [\(ok ? "ok" : "FAIL")] \(label) → \(lines.count) (want \(expected)) \(lines)")
        }
        print("transitions: \(failures == 0 ? "all pass" : "\(failures) FAILED")")
        _ = TrayFleet.menuLines()
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.5)
            if let list = TrayFleet.cached(), !list.accounts.isEmpty { break }
        }
        print("engine: \(TrayFleet.engineIndicator()?.text ?? "none")")
        let lines = TrayFleet.menuLines()
        print("tray menu lines: \(lines.count)")
        for l in lines { print("  \(l.text) (enabled=\(l.enabled), account=\(String(describing: l.account)))") }
        // The panel over every fleet the engine holds — with 9Router that
        // is one section per provider, each with its own header, which is
        // what the flattened single-list probe used to hide.
        let fleets = TrayFleet.cachedFleets()
        print("fleets: \(fleets.count)")
        let cachedPanel = FleetLayout.panel(fleets: fleets, live: nil,
                                            engineInstalled: TrayFleet.hasEngine(),
                                            engine: TrayFleet.engineIndicator())
        print("panel sections: \(cachedPanel.sections.count) rows: \(cachedPanel.rows.count)")
        print("panel footer: \(cachedPanel.footer)")
        for section in cachedPanel.sections {
            print("  [\(section.key)] \(section.label.text) active=\(String(describing: section.activeNumber))")
            for r in section.rows {
                print("    #\(r.number) \(r.name) (\(r.email)) active=\(r.active) gauges=\(r.gauges.count)")
                for g in r.gauges {
                    print("      [\(g.label)] \(g.usedPct)% remaining=\(g.remaining)% reset=\(g.reset ?? "nil")")
                }
            }
        }
        // Probe settings catalogue and config store
        print("settings catalog entries: \(SettingsCatalog.entries.count)")
        for e in SettingsCatalog.entries {
            print("  [\(e.id)] \(e.title) (engine=\(e.engine), keywords=\(e.keywords.count))")
        }
        let settingsURL = WinSettingsStore.url
        print("settings path: \(settingsURL.path)")
        let exists = FileManager.default.fileExists(atPath: settingsURL.path)
        print("settings file exists: \(exists)")
        let s = WinSettingsStore.load()
        print("settings parsed ok: lastPane=\(s.lastPaneID), titlePct=\(s.titlePct)")
        return failures == 0 ? 0 : 1
    }
    let instance = GetModuleHandleW(nil)
    let className = "InfinitusTrayWindow".wide
    var windowClass = WNDCLASSW()
    windowClass.lpfnWndProc = windowProc
    windowClass.hInstance = instance
    windowClass.lpszClassName = UnsafePointer(className)
    guard RegisterClassW(&windowClass) != 0 else { return 1 }

    // A message-only window: no chrome, never shown, just a target for
    // the tray callback and the timer.
    // HWND_MESSAGE isn't exported to Swift; it is the documented
    // message-only parent value (-3).
    let messageOnlyParent = HWND(bitPattern: -3)
    guard let window = CreateWindowExW(0, className, "Infinitus".wide, 0, 0, 0, 0, 0,
                                       messageOnlyParent, nil, instance, nil)
    else { return 1 }
    state.window = window
    state.icon = TrayIcon.make(busy: false)

    let (rows, busy) = readSessions()
    state.rows = rows
    state.busy = busy
    var data = notifyData(window, tip: "\(rows.count) sessions")
    guard Shell_NotifyIconW(DWORD(NIM_ADD), &data) else { return 1 }
    let initialSettings = WinSettingsStore.load()
    TrayFleet.cacheSeconds = TimeInterval(initialSettings.refreshIntervalSeconds)
    refresh()
    SetTimer(window, 1, refreshMilliseconds, nil)
    SetTimer(window, timerUpdateCheckID, timerUpdateCheckIntervalMs, nil)
    checkUpdateAsync(window: window)

    var message = MSG()
    // Swift maps GetMessageW's BOOL to Bool: false is WM_QUIT (and the
    // -1 error case, which only a bad HWND produces — ours is ours).
    while GetMessageW(&message, nil, 0, 0) {
        if SettingsShell.handles(&message) { continue }
        TranslateMessage(&message)
        DispatchMessageW(&message)
    }
    if let icon = state.icon { DestroyIcon(icon) }
    return Int32(message.wParam)
}

exit(run())
