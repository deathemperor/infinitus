import SwiftUI
import AppKit
import SwiftTerm
import InfinitusCore
import InfinitusUI

/// The right panel's Terminal tab — `ThreadTerminalDrawer.tsx` in the
/// `mode="panel"` the right panel mounts it with (`:1079` `isPanel`,
/// `:1425-1431`: full height, `bg-background`, no drag handle, the action
/// cluster floating `absolute right-2 top-2` over the emulator). The tab
/// itself is `RightPanelTabs.tsx:323-332` — label "Terminal", "Start a shell
/// in this workspace.", shortcut T, `TerminalSquare`.
///
/// The shell is the Mac's own `TerminalHost` (#507 step 3), reached in-process:
/// no HTTP hop, no mirror, the same host and the same terminal id the phone
/// attaches to (`T3Terminal.defaultTerminalId`), so a session's terminal is ONE
/// shell shared by both ends — upstream's per-thread semantics, for free.
/// The emulator is SwiftTerm on both ends too (#507: "SwiftTerm both ends"),
/// wearing the same palette the phone's screen installs.
///
/// **Availability — a stated deviation.** Upstream offers a terminal whenever
/// a project is open, keyed by cwd. `TerminalHost` keys a terminal by the
/// SESSION's pid and takes its cwd from `ClaudeSessions.list`
/// (`AppModel.swift`'s `mirrorServer.terminal.set`), so this round the tab
/// needs a live session pid: the same triple the Diff tab gates on — a local
/// thread, its project's cwd, and `T3WorkspaceState.pid(of:)`. Without one the
/// tab shows the unavailable card with `RightPanelTabs.tsx:160`'s hint
/// verbatim. A cwd-keyed open (a terminal on a project with no session running)
/// is a later slice; it needs a second key in the host, not a change here.
///
/// Not ported this round, each with its upstream line — v1 is one terminal per
/// thread, which is what the host holds (`TerminalHost.swift`'s "v1 is one
/// terminal per session"):
/// - the drawer mode (`:989` `mode: "drawer" | "panel"`, the resize handle
///   `:1402-1410` and `clampDrawerHeight` `:100-104`): the right panel is the
///   only mount here.
/// - the split buttons (`:1444-1466`, `SquareSplitHorizontal` /
///   `SquareSplitVertical`) and the split grid (`:1500-1552`).
/// - "+" for a second terminal (`:1467-1473`, `nextTerminalId`
///   `terminalLabels.ts:31-38`) and the terminal picker / tab sidebar
///   (`hasTerminalSidebar`, `:1443`).
/// - the selection actions (`observeSelectionActions`, `:1-53`) and "add
///   selection to chat" (`onAddTerminalContext`): the composer here takes no
///   terminal-context mention.
/// - `advancedTypography` (`:1080-1084`) and the font-size preference — the
///   kit's mono face at the code-block size is the one face.
/// - link opening (`requestOpenLink`, `:789-800`) beyond handing the URL to
///   the system opener, and the editor-preference resolution around it.
struct T3TerminalPanel: View {
    @Environment(\.t3) private var t3
    @ObservedObject var model: T3WindowModel

    /// The Diff tab's triple plus the live pid. A mirrored thread
    /// (`id: "pid:…"`, `T3ThreadBridge.swift:54`) has no shell of ours to
    /// open, and a thread whose session has ended has no pid to key one by.
    private var target: T3TerminalTarget? {
        guard let thread = model.state.selectedThread,
              thread.environmentId == T3Thread.localEnvironmentId,
              let cwd = model.state.projects.first(where: { $0.id == thread.projectId })?.cwd,
              let pid = model.state.pid(of: thread.id)
        else { return nil }
        return T3TerminalTarget(cwd: cwd, pid: pid)
    }

    var body: some View {
        Group {
            if let target {
                // A new (cwd, pid) is a new surface, the way the Files tab
                // keys on cwd (`ChatView.tsx:8078`). The registry behind it
                // keeps the emulator alive across this, so a thread switched
                // away from and back to still has its scrollback.
                T3TerminalSurfaceView(model: model, target: target)
                    .id(target.key)
            } else if model.state.selectedThread == nil {
                // The launcher's disabled reason, `RightPanelTabs.tsx:138`.
                T3TerminalMessage(text: "Terminal surfaces are only available from a project thread.")
            } else {
                T3TerminalUnavailable()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t3.web.background.color)
    }
}

/// Which shell this tab is looking at. The pid is the CLAUDE session's, not the
/// shell's — that is the host's key.
struct T3TerminalTarget: Hashable {
    let cwd: String
    let pid: Int32
    var key: String { "\(cwd)\u{0}\(pid)" }
}

/// The unavailable state, the shape `T3FilesPanel`/`T3DiffPanel` give theirs:
/// upstream's one-line hint under the surface's name, `opacity-40`
/// (`RightPanelTabs.tsx:160`, rendered `:560-575`).
private struct T3TerminalUnavailable: View {
    @Environment(\.t3) private var t3
    var body: some View {
        VStack(spacing: 6) {
            Text("Terminal")
                .font(T3Font.web(.sm, .medium))
                .foregroundStyle(t3.web.foreground.color)
            Text("Available when a project is open.")
                .font(T3Font.web(.xs))
                .foregroundStyle(t3.web.mutedForeground.color)
        }
        .opacity(0.4)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A centred one-liner, `T3DiffMessage`'s shape.
private struct T3TerminalMessage: View {
    @Environment(\.t3) private var t3
    let text: String
    var body: some View {
        Text(text)
            .font(T3Font.web(.xs))
            .foregroundStyle(t3.web.mutedForeground.color.opacity(0.7))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The surface

/// The emulator over one target, plus the floating action cluster. The view is
/// a shell around `T3TerminalEntry`: the entry (and with it the `TerminalView`,
/// its scrollback and its attachment) lives on the window model, so switching
/// to Files and back re-attaches instead of restarting
/// (`ThreadTerminalDrawer.tsx` keeps its terminals mounted across tab
/// switches; `visible` only stops it focusing them, `:1114`).
private struct T3TerminalSurfaceView: View {
    @ObservedObject var model: T3WindowModel
    let target: T3TerminalTarget
    @State private var entry: T3TerminalEntry?

    var body: some View {
        Group {
            if let entry {
                T3TerminalPane(entry: entry)
            } else {
                // `DiffPanelShell`'s skeleton stands in as everywhere else in
                // this port. forkpty is a millisecond, so this only paints for
                // the frame between appear and the entry — or, if the window
                // has already lost its `AppModel`, while the window closes.
                T3Spinner(size: 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            let entry = model.terminals?.entry(for: target)
            self.entry = entry
            entry?.appear()
        }
        .onDisappear { entry?.disappear() }
    }
}

/// The emulator and the floating action cluster over it.
private struct T3TerminalPane: View {
    @Environment(\.t3) private var t3
    @ObservedObject var entry: T3TerminalEntry
    @State private var confirmingClose = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            T3TerminalEmulator(entry: entry)
            // `:1443-1487` — the cluster is only the trash this round.
            actions
                .padding(.top, 8)
                .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t3.web.terminalBackground.color)
        .onAppear {
            // `autoFocus` (`:1114`, `terminal.focus()` at `:545-547`): the tab
            // is useless until the emulator has the keyboard.
            DispatchQueue.main.async { entry.view.window?.makeFirstResponder(entry.view) }
        }
        .confirmationDialog("", isPresented: $confirmingClose) {
            Button("Close Terminal", role: .destructive) { entry.closeShell() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // `terminalCloseConfirm.ts:24-27`, the single-terminal wording.
            Text("Close terminal \"\(T3TerminalSurface.label(terminalId: entry.terminalId))\"?\nThis stops the running process and clears its history.")
        }
    }

    /// `:1443-1487`: an `inline-flex` of icon buttons in a rounded bordered box
    /// over the emulator's top-right corner. Ours holds the one control v1 has
    /// a meaning for — `Trash2`, "Close Terminal" (`:1266-1269`), confirmed
    /// first like upstream's.
    private var actions: some View {
        T3FilesIconButton(help: "Close Terminal") { confirmingClose = true } content: {
            LucideIcon(.trash2, size: 13)
        }
        .background(t3.web.background.color, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(t3.web.border.color.opacity(0.8), lineWidth: 1)
        )
        .opacity(entry.finished ? 0 : 1)
        .allowsHitTesting(!entry.finished)
    }
}

/// SwiftTerm's view, handed straight through. Nothing is created here — the
/// entry owns the view, which is what survives a tab switch.
private struct T3TerminalEmulator: NSViewRepresentable {
    @Environment(\.t3) private var t3
    let entry: T3TerminalEntry

    func makeNSView(context: Context) -> TerminalView { entry.view }

    func updateNSView(_ view: TerminalView, context: Context) {
        // Light/dark, and the first paint: the palette is idempotent.
        entry.applyTheme(t3)
    }
}

// MARK: - The entry: one shell, one emulator, one attachment

/// Everything about one target that must outlive the SwiftUI view: the
/// `TerminalView` (and with it the scrollback), the host attachment, and the
/// `since` offset a re-attach resumes from (`T3TerminalSurface.Attachment`).
///
/// Queues, all of them off the main actor except the last hop:
/// - `open` + `attach` run on a detached task — `forkpty` is a fork.
/// - the host's fan-out sink runs on the host's own serial queue and hops with
///   ONE `DispatchQueue.main.async` per batch: main is FIFO, so the chunks
///   reach the emulator in the order the pty produced them.
/// - keystrokes, resizes and the close go to `io`, a serial queue of this
///   entry's own. Never `DispatchQueue.global()` (concurrent: two keystrokes
///   could overtake each other) and never the main actor (`TerminalHost.write`
///   waits up to 5 s on a pty whose reader has stopped).
@MainActor
final class T3TerminalEntry: ObservableObject {
    let target: T3TerminalTarget
    let terminalId = T3Terminal.defaultTerminalId
    let view: TerminalView
    /// The shell is gone (`exited`/`closed`): the actions hide and the next
    /// appear starts a new one.
    @Published private(set) var finished = false

    private let host: TerminalHost
    private let io = DispatchQueue(label: "run.infinitus.terminal-tab")
    private var attachment: T3TerminalSurface.Attachment = .init()
    private var handle: TerminalHost.Attachment?
    /// The tab is on screen. An `open`/`attach` still in flight when the tab
    /// goes away has to detach the moment it lands — otherwise the host never
    /// arms its idle timer and a hidden view keeps being fed.
    private var wanted = false
    private var opening = false
    private var resizeDebounce: Task<Void, Never>?
    private var lastSize: (cols: Int, rows: Int)?
    private var delegate: T3TerminalDelegate?

    init(target: T3TerminalTarget, host: TerminalHost) {
        self.target = target
        self.host = host
        // `cursorStyle: .steadyBlock` — SwiftTerm's default `.blinkBlock` runs
        // a `repeatCount: .infinity` opacity CABasicAnimation on the caret
        // layer (`MacCaretView.swift:92-105`), i.e. a timer in an idle tab
        // (#507 ruling 6, and the repo's own no-continuous-motion rule).
        var options = TerminalOptions(cursorStyle: .steadyBlock)
        options.scrollback = T3Terminal.ringBytes / 80   // ~3200 lines, the ring's own depth
        view = TerminalView(frame: CGRect(x: 0, y: 0, width: 480, height: 320),
                            font: NSFont.monospacedSystemFont(ofSize: T3ChatMarkdown.codeFontSize,
                                                              weight: .regular),
                            options: options)
        // The shell is a shell, not a mouse app: upstream's panel reports no
        // mouse either (the surface takes selection instead).
        view.allowMouseReporting = false
        let delegate = T3TerminalDelegate(entry: self)
        self.delegate = delegate
        view.terminalDelegate = delegate
    }

    // MARK: Lifecycle

    /// The tab became visible: open the shell if it is not running, then
    /// attach from where this view last was.
    func appear() {
        wanted = true
        // A new shell for a finished one — upstream's zero-terminal state
        // offers the same thing behind a button (`:1411-1416`).
        if finished {
            finished = false
            attachment = .init()
            view.getTerminal().resetToInitialState()
        }
        // Already attached, or an open from a previous appear is still in
        // flight — that one binds the handle, and `wanted` is true again.
        guard handle == nil, !opening else { return }
        opening = true
        // Before the task: the host hands the opening frames to the sink
        // synchronously inside `attach`, and they can reach main first.
        attachment.attaching()
        let size = requestedSize()
        let host = host, target = target, id = terminalId
        let since = attachment.sequence
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = host.open(pid: target.pid, cwd: target.cwd,
                                    request: T3Terminal.OpenRequest(cols: size.cols, rows: size.rows))
            if case .failure(let error) = outcome {
                await MainActor.run { self?.openFailed(error) }
                return
            }
            let handle = host.attach(pid: target.pid, id: id, since: since) { frames in
                // The host's queue. One hop per batch, in order.
                DispatchQueue.main.async { self?.feed(frames) }
            }
            await MainActor.run { self?.attached(handle) }
        }
    }

    /// A tab switch, or the panel closing: **detach only** — the shell keeps
    /// running (upstream keeps its terminals across tab switches) and the
    /// host's 30-minute idle timer takes over.
    func disappear() {
        wanted = false
        resizeDebounce?.cancel()
        resizeDebounce = nil
        guard let handle else { return }
        self.handle = nil
        host.detach(handle)
    }

    /// The trash: the shell is signalled, and `exited` + `closed` come back
    /// through the attachment that is still open.
    func closeShell() {
        let host = host, pid = target.pid, id = terminalId
        io.async { _ = host.close(pid: pid, id: id) }
    }

    private func attached(_ handle: TerminalHost.Attachment?) {
        opening = false
        guard let handle else {
            // The terminal went away between open and attach (a close that
            // raced us): nothing is running, so let the next appear re-open.
            finished = true
            return
        }
        guard wanted else {
            // The tab left while we were forking. Out of the fan-out at once,
            // or the host never arms its idle timer.
            host.detach(handle)
            return
        }
        self.handle = handle
        // The size the view settled on while the fork was in flight.
        pushSize(requestedSize(), debounced: false)
    }

    /// The open failed: the sentence goes on the screen and there is no shell,
    /// so the next appear tries again.
    private func openFailed(_ error: TerminalHost.HostError) {
        opening = false
        note(Self.sentence(error))
        finished = true
    }

    /// A write that could not land — the pty's reader has stopped. Said out
    /// loud (never swallowed) but not fatal: the shell is still there.
    private func note(_ message: String) {
        view.feed(text: T3TerminalSurface.systemMessage(message))
    }

    private static func sentence(_ error: TerminalHost.HostError) -> String {
        switch error {
        case .spawnFailed(let reason): return reason
        case .validation: return "the terminal size was refused"
        }
    }

    // MARK: Frames

    private func feed(_ frames: [T3Terminal.Frame]) {
        for frame in frames {
            switch attachment.step(frame) {
            case .reset(let text):
                view.getTerminal().resetToInitialState()
                if !text.isEmpty { view.feed(text: text) }
            case .append(let text):
                view.feed(text: text)
            case .nothing:
                break
            }
            // `synchronizeTerminalStatus` (`:432-445`): one line per exit,
            // `exited` and `closed` never both — `finished` is upstream's
            // `hasHandledExitRef`.
            switch frame {
            case .exited:
                if !finished {
                    finished = true
                    note(T3TerminalSurface.exitedMessage)
                }
            case .closed:
                if !finished {
                    finished = true
                    note(T3TerminalSurface.closedMessage)
                }
                // `finish()` dropped every attachment on its way out.
                handle = nil
            case .error(let payload):
                note(payload.message)
            case .snapshot(let payload):
                // Attaching to a terminal that has ALREADY exited still runs
                // the exit handling once (`:540-545`: mount synchronization
                // starts from "closed", so only "exited" says anything).
                switch payload.status {
                case .exited:
                    if !finished {
                        finished = true
                        note(T3TerminalSurface.exitedMessage)
                    }
                case .error:
                    if !finished {
                        finished = true
                        note("the shell failed to start")
                    }
                case .starting, .running:
                    break
                }
            case .output:
                break
            }
        }
    }

    // MARK: Keystrokes, size, theme

    /// Called on the main actor by the delegate; the write itself is not.
    func send(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty, handle != nil else { return }
        let host = host, pid = target.pid, id = terminalId
        // `maxWriteBytes` is 64 KB and a paste can beat it — one write per
        // chunk, in order, on the serial queue.
        let chunks = stride(from: bytes.startIndex, to: bytes.endIndex, by: T3Terminal.maxWriteBytes)
            .map { start in
                Array(bytes[start..<min(start + T3Terminal.maxWriteBytes, bytes.endIndex)])
            }
        io.async { [weak self] in
            for chunk in chunks {
                let data = String(decoding: chunk, as: UTF8.self)
                let outcome = host.write(pid: pid, id: id, T3Terminal.WriteRequest(data: data))
                guard case .failure(let error) = outcome else { continue }
                // Never swallowed: a pty that stopped reading is the one
                // failure a typist has to be told about.
                Task { @MainActor in self?.note(T3TerminalEntry.sentence(error)) }
                return
            }
        }
    }

    func sizeChanged(cols: Int, rows: Int) {
        resizeDebounce?.cancel()
        resizeDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            self?.pushSize((cols: cols, rows: rows), debounced: true)
        }
    }

    private func pushSize(_ size: (cols: Int, rows: Int), debounced: Bool) {
        guard handle != nil else { return }
        let clamped = (cols: min(max(size.cols, T3Terminal.minCols), T3Terminal.maxCols),
                       rows: min(max(size.rows, T3Terminal.minRows), T3Terminal.maxRows))
        if let last = lastSize, last == clamped { return }
        lastSize = clamped
        let host = host, pid = target.pid, id = terminalId
        io.async {
            _ = host.resize(pid: pid, id: id,
                            T3Terminal.ResizeRequest(cols: clamped.cols, rows: clamped.rows))
        }
    }

    /// The emulator's own idea of its size, clamped into Core's caps: a view
    /// that has not been laid out yet reports whatever its init frame implied.
    private func requestedSize() -> (cols: Int, rows: Int) {
        let terminal = view.getTerminal()
        return (cols: min(max(terminal.cols, T3Terminal.minCols), T3Terminal.maxCols),
                rows: min(max(terminal.rows, T3Terminal.minRows), T3Terminal.maxRows))
    }

    /// `terminalThemeFromApp` (`ThreadTerminalDrawer.tsx:176-236`) reads the
    /// drawer's `--terminal-background` / `--terminal-foreground` /
    /// `--terminal-cursor` / `--terminal-selection-background`; those are the
    /// four tokens below. The 16 ANSI colours are upstream's Pierre palette
    /// (`terminalTheme.ts`) — the exact hex list the phone installs
    /// (`T3TerminalScreen.swift`), so both ends of #507 look the same.
    func applyTheme(_ t3: T3Environment) {
        let palette = t3.web
        let hex = t3.scheme == .dark
            ? ["141415", "ff2e3f", "0dbe4e", "ffca00", "009fff", "c635e4", "08c0ef", "c6c6c8",
               "141415", "ff2e3f", "0dbe4e", "ffca00", "009fff", "c635e4", "08c0ef", "c6c6c8"]
            : ["1F1F21", "ff2e3f", "0dbe4e", "ffca00", "009fff", "c635e4", "08c0ef", "c6c6c8",
               "1F1F21", "ff2e3f", "0dbe4e", "ffca00", "009fff", "c635e4", "08c0ef", "c6c6c8"]
        let colors = hex.map(Self.color)
        guard colors != installedColors else { return }
        installedColors = colors
        view.installColors(colors)
        // `installColors` resets the default fg/bg, so these follow it.
        view.nativeBackgroundColor = NSColor(palette.terminalBackground.color)
        view.nativeForegroundColor = NSColor(palette.terminalForeground.color)
        view.caretColor = NSColor(palette.terminalCursor.color)
        view.selectedTextBackgroundColor = NSColor(palette.terminalSelectionBackground.color)
    }
    private var installedColors: [SwiftTerm.Color]?

    private static func color(_ hex: String) -> SwiftTerm.Color {
        let value = UInt32(hex, radix: 16) ?? 0
        return SwiftTerm.Color(red8: UInt16((value >> 16) & 0xff),
                               green8: UInt16((value >> 8) & 0xff),
                               blue8: UInt16(value & 0xff))
    }
}

/// SwiftTerm's delegate. Separate from the entry because `TerminalViewDelegate`
/// is not main-actor-annotated: every callback lands on main (AppKit calls
/// them) and hops explicitly rather than pretending otherwise.
private final class T3TerminalDelegate: NSObject, TerminalViewDelegate {
    private weak var entry: T3TerminalEntry?
    init(entry: T3TerminalEntry) { self.entry = entry }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { entry?.send(data) }
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { entry?.sizeChanged(cols: newCols, rows: newRows) }
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func bell(source: TerminalView) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), url.scheme != nil else { return }
        NSWorkspace.shared.open(url)
    }
    func clipboardCopy(source: TerminalView, content: Data) {
        let text = String(decoding: content, as: UTF8.self)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    func clipboardRead(source: TerminalView) -> Data? {
        NSPasteboard.general.string(forType: .string).map { Data($0.utf8) }
    }
}

/// The window's live terminals, one entry per (cwd, pid). On the window model
/// so a tab switch, a thread switch and back, or a re-identified surface all
/// find the same emulator and the same `since`.
@MainActor
final class T3TerminalRegistry {
    private weak var app: AppModel?
    private var entries: [T3TerminalTarget: T3TerminalEntry] = [:]

    init(app: AppModel?) { self.app = app }

    /// `nil` only once the window has outlived its `AppModel` — there is no
    /// host to open a shell on then, and nothing to show but the skeleton.
    func entry(for target: T3TerminalTarget) -> T3TerminalEntry? {
        if let existing = entries[target] { return existing }
        guard let app else { return nil }
        let entry = T3TerminalEntry(target: target, host: app.terminalHost)
        entries[target] = entry
        return entry
    }

    /// The window closed (`T3WindowModel.stop`): detach every entry, never
    /// close — the shells outlive the window, exactly as they outlive a tab
    /// switch, and `AppModel.terminalHost.closeAll()` is what ends them.
    func detachAll() {
        for entry in entries.values { entry.disappear() }
    }
}
