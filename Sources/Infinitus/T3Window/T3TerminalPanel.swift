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
/// in this workspace.", shortcut T, `TerminalSquare`; its TITLE follows the
/// active terminal's label (`RightPanelTabs.tsx:598-602`).
///
/// The shell is the Mac's own `TerminalHost` (#507 step 3), reached in-process:
/// no HTTP hop, no mirror, the same host and the same terminal ids the phone
/// attaches to, so a session's terminals are shells BOTH ends share —
/// upstream's per-thread semantics, for free. The emulator is SwiftTerm on both
/// ends too (#507: "SwiftTerm both ends"), wearing the same palette the phone's
/// screen installs.
///
/// **Several terminals per thread, in groups.** A thread holds up to
/// `T3Terminal.maxTerminalsPerSession` shells: "+" opens the next free
/// `term-N` (`nextTerminalId`, `terminalLabels.ts:32-40`) in a group of its own
/// and the picker upstream draws as a 144 pt sidebar (`hasTerminalSidebar`,
/// `:1586-1709`, shown only from the second terminal on, `:1228`) switches and
/// closes them. With one terminal the controls float over the emulator instead
/// (`:1442-1486`, `!hasTerminalSidebar`).
///
/// **Splits.** The two split buttons (`:1444-1467` in the floating cluster,
/// `:1590-1611` in the strip header) grow the ACTIVE group instead: up to
/// `T3TerminalSurface.SplitGroup.maxPerGroup` = 4 shells
/// (`MAX_TERMINALS_PER_GROUP`, `types.ts:30`) side by side or stacked, over
/// `repeat(n, minmax(0, 1fr))` (`:1496-1556`). One orientation per group and no
/// nesting — a vertical split of a side-by-side pair stacks all three
/// (`terminalUiStateStore.ts:334-338`, the last split wins). Every member of
/// the active group is mounted at once, upstream's own arrangement
/// (`:1509-1555`, each gated by `visible`, `:468-471`); the other groups' stay
/// attached but unmounted, as a hidden terminal already did. A click in a pane
/// makes it active (`onMouseDown`, `:1523-1527`), the active pane takes the
/// keyboard and the tab's title, and a member whose shell ends collapses the
/// grid (`onSessionExited → onCloseTerminal`, `:1543`). The strip gains a header
/// per group — "Single" / "Stacked" / "Side by side" and the member count
/// (`:1638-1642`, `:1651-1667`) — from the moment there is more than one group,
/// so two lone terminals now carry one each (`showGroupHeaders`, `:1230-1232`).
/// Four idle panes measured 0.69% and 0.70% CPU over two 15 s windows against
/// B-36's 0.58-0.62% for three hidden — and against 0.68%/0.90% for this same
/// fixture with the tab switched away, i.e. inside its own noise.
///
/// **What upstream does on a switch — and what this does.** Upstream keeps the
/// SESSION alive server-side and remounts the client: outside a split group
/// exactly ONE `TerminalViewport` is mounted, keyed by the active id
/// (`:1559-1561` `key={resolvedActiveTerminalId}`), and its unmount disposes
/// the surface and drops the attach stream (`:890-894`, `:917-922`); only the
/// terminals of one split group are mounted together, each gated by `visible`
/// / `setVisible` (`:468-471`, `:1509-1555`). Ours mounts the active entry's
/// `TerminalView` alone, exactly like that — but it does NOT drop the hidden
/// terminals' ATTACHMENTS, because this host idle-closes an unattached
/// terminal after 30 minutes (`TerminalHost.idleTimeout`, a thing upstream has
/// no equivalent of: its only eviction is of already exited sessions,
/// `Manager.ts:1957-1977`). Detaching on every switch would let a shell the
/// strip still lists die under it. A hidden entry therefore keeps feeding its
/// off-hierarchy `TerminalView`, which is parse-only work with no window to
/// draw into — an idle shell emits nothing at all, so the tab with three
/// terminals open idles where one did (#519/#526's number). Measured on a
/// CHATTY hidden shell (`while :; do date; sleep 0.1; done`, ~10 lines/s):
/// 1.7%/2.3% over two 15 s windows with it hidden against 7.1% with the same
/// shell on screen — the ~4x gap is the repaint that a hidden entry does not
/// do, and the remainder is the pty read plus the parse into its ring.
///
/// The other mode (`:989` `mode: "drawer" | "panel"`) mounts the same
/// `T3TerminalSurfaceView` from `T3TerminalDrawerView.swift`.
///
/// Not ported this round, each with its upstream line:
/// - a split's keyboard shortcut (`splitShortcutLabel` /
///   `splitVerticalShortcutLabel`, `:1253-1262`): the tab binds none, so the
///   two labels are upstream's without the shortcut suffix.
/// - the selection actions (`observeSelectionActions`, `:1-53`) and "add
///   selection to chat" (`onAddTerminalContext`): the composer here takes no
///   terminal-context mention.
/// - `advancedTypography` (`:1080-1084`) and the font-size preference — the
///   kit's mono face at the code-block size is the one face.
/// - link opening (`requestOpenLink`, `:789-800`) beyond handing the URL to
///   the system opener, and the editor-preference resolution around it.
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
struct T3TerminalPanel: View {
    @Environment(\.t3) private var t3
    @ObservedObject var model: T3WindowModel

    var body: some View {
        Group {
            if let target = Self.target(in: model.state) {
                // A new (cwd, pid) is a new surface, the way the Files tab
                // keys on cwd (`ChatView.tsx:8078`). The registry behind it
                // keeps the emulators alive across this, so a thread switched
                // away from and back to still has its scrollback.
                T3TerminalSurfaceView(model: model, target: target, owner: .panel)
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

    /// The Diff tab's triple plus the live pid. A mirrored thread
    /// (`id: "pid:…"`, `T3ThreadBridge.swift:54`) has no shell of ours to
    /// open, and a thread whose session has ended has no pid to key one by.
    /// Static because the tab STRIP needs the same target to title itself with
    /// the active terminal's label (`T3RightPanel`).
    static func target(in state: T3WorkspaceState) -> T3TerminalTarget? {
        guard let thread = state.selectedThread,
              thread.environmentId == T3Thread.localEnvironmentId,
              let cwd = state.projects.first(where: { $0.id == thread.projectId })?.cwd,
              let pid = state.pid(of: thread.id)
        else { return nil }
        return T3TerminalTarget(cwd: cwd, pid: pid)
    }
}

/// Which session's terminals this tab is looking at. The pid is the CLAUDE
/// session's, not a shell's — that is the host's key, and one pid holds
/// several terminals.
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
struct T3TerminalMessage: View {
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

/// The emulator over one target, plus the controls — the piece BOTH of
/// upstream's modes render (`ThreadTerminalDrawer.tsx:1425-1710`; `mode`
/// decides only the container's sizing and the drag handle, `:1398-1440`). The
/// right panel's tab mounts it as `.panel`, the thread's drawer as `.drawer`.
///
/// The view is a shell around `T3TerminalGroup`: the group (and with it every
/// `TerminalView`, its scrollback and its attachment) lives on the window model,
/// so switching to Files and back re-attaches instead of restarting
/// (`ThreadTerminalDrawer.tsx` keeps its terminals mounted across tab switches;
/// `visible` only stops it focusing them, `:1114`).
struct T3TerminalSurfaceView: View {
    @ObservedObject var model: T3WindowModel
    let target: T3TerminalTarget
    /// Which of the two surfaces this is. Both may be mounted at once, and only
    /// one of them draws (`T3TerminalDrawer.Presenters`).
    let owner: T3TerminalDrawer.Owner
    @State private var group: T3TerminalGroup?

    var body: some View {
        Group {
            if let group {
                T3TerminalOwnedView(group: group, owner: owner)
            } else {
                // `DiffPanelShell`'s skeleton stands in as everywhere else in
                // this port. forkpty is a millisecond, so this only paints for
                // the frame between appear and the group — or, if the window
                // has already lost its `AppModel`, while the window closes.
                T3Spinner(size: 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            let group = model.terminals?.group(for: target)
            self.group = group
            group?.appear(as: owner)
        }
        .onDisappear { group?.disappear(as: owner) }
    }
}

/// The claim: this surface draws the shells only while it is the group's
/// current presenter, and says where they are otherwise.
///
/// Upstream partitions the terminals themselves — a terminal a right-panel
/// surface holds leaves the drawer's list (`ChatView.tsx:855-868`) — which
/// needs a "move to the panel" affordance this port has none of. Here the
/// partition is by surface, and it is not only a rule: one `TerminalView` is
/// one NSView, and an NSView has one superview.
private struct T3TerminalOwnedView: View {
    @ObservedObject var group: T3TerminalGroup
    let owner: T3TerminalDrawer.Owner

    var body: some View {
        if group.presenting == owner || group.presenting == nil {
            T3TerminalGroupView(group: group)
        } else if let other = group.presenting {
            T3TerminalMessage(text: T3TerminalDrawer.Presenters.elsewhere(other))
        }
    }
}

/// `:1488-1710`: the emulator on the left (`min-w-0 flex-1`), the terminal
/// picker on the right when the thread holds more than one
/// (`hasTerminalSidebar`, `:1228`), `gap-1.5` between them (`:1492`).
private struct T3TerminalGroupView: View {
    @Environment(\.t3) private var t3
    @ObservedObject var group: T3TerminalGroup
    /// The terminal a close is waiting on the user for — the trash and every
    /// strip row go through the same confirm (`confirmCloseTerminal`,
    /// `:1280-1288`).
    @State private var confirming: String?

    var body: some View {
        HStack(spacing: group.showsStrip ? 6 : 0) {
            surface
            if group.showsStrip {
                T3TerminalStrip(group: group, confirming: $confirming)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t3.web.terminalBackground.color)
        .confirmationDialog("", isPresented: Binding(get: { confirming != nil },
                                                     set: { if !$0 { confirming = nil } })) {
            Button("Close Terminal", role: .destructive) {
                if let id = confirming { group.close(id) }
                confirming = nil
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            // `terminalCloseConfirm.ts:24-27`, the single-terminal wording.
            Text("Close terminal \"\(T3TerminalSurface.label(terminalId: confirming ?? ""))\"?\nThis stops the running process and clears its history.")
        }
    }

    /// `:1496-1583`: the active group's members together when it holds more than
    /// one (`isSplitView`, `:1229`), the lone terminal keyed by its id
    /// otherwise (`:1561`).
    @ViewBuilder private var surface: some View {
        if let split = group.activeGroup, split.isSplit {
            // Keyed by the GROUP, not the active terminal: a click that moves
            // focus inside the grid must not remount four emulators.
            T3TerminalSplitGrid(group: group, split: split, confirming: $confirming)
                .id(split.id)
        } else if let entry = group.activeEntry {
            // Keyed by the terminal, upstream's own switch
            // (`:1561 key={resolvedActiveTerminalId}`): the pane remounts,
            // which is what hands the keyboard to the terminal switched TO.
            T3TerminalPane(group: group, entry: entry, confirming: $confirming)
                .id(entry.terminalId)
        } else {
            // Every terminal closed: the same skeleton the first open shows.
            T3Spinner(size: 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The split grid (`:1496-1556`): the active group's members over
/// `repeat(n, minmax(0, 1fr))` — columns when the group is `horizontal`, rows
/// when it is `vertical` (`:1500-1507`) — with no gap between them and a 1 pt
/// divider before every member but the first (`border-l first:border-l-0` /
/// `border-t first:border-t-0`, `:1514-1517`), `border` under the active pane
/// and `border/70` under the others (`:1519-1521`).
///
/// Every member is mounted at once, upstream's own arrangement for a split group
/// (`:1509-1555`, each `TerminalViewport` gated by `visible`, `:468-471`); the
/// other groups' terminals stay attached but unmounted, the way a hidden
/// terminal already did.
private struct T3TerminalSplitGrid: View {
    @Environment(\.t3) private var t3
    @ObservedObject var group: T3TerminalGroup
    let split: T3TerminalSurface.SplitGroup
    @Binding var confirming: String?

    private var stacked: Bool { split.orientation == .vertical }

    var body: some View {
        Group {
            if stacked {
                VStack(spacing: 0) { panes }
            } else {
                HStack(spacing: 0) { panes }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focusActive() }
        // `autoFocus={terminalId === resolvedActiveTerminalId}` (`:1546`): the
        // keyboard follows the active pane, and a click is what moves it.
        .onChange(of: group.activeId) { _, _ in focusActive() }
    }

    private var panes: some View {
        ForEach(Array(split.terminalIds.enumerated()), id: \.element) { index, id in
            pane(id, first: index == 0)
        }
    }

    @ViewBuilder private func pane(_ id: String, first: Bool) -> some View {
        if let entry = group.entry(id: id) {
            T3TerminalPane(group: group, entry: entry, confirming: $confirming)
                .overlay(alignment: stacked ? .top : .leading) {
                    if !first {
                        Rectangle()
                            .fill(t3.web.border.color.opacity(group.activeId == id ? 1 : 0.7))
                            .frame(width: stacked ? nil : 1, height: stacked ? 1 : nil)
                    }
                }
        }
    }

    private func focusActive() {
        guard let view = group.activeEntry?.view else { return }
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}

/// The active terminal's emulator, and — with only one terminal open — the
/// floating action cluster over it (`:1442-1486`).
private struct T3TerminalPane: View {
    @Environment(\.t3) private var t3
    @ObservedObject var group: T3TerminalGroup
    @ObservedObject var entry: T3TerminalEntry
    @Binding var confirming: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            T3TerminalEmulator(entry: entry)
            if !group.showsStrip {
                actions
                    .padding(.top, 8)
                    .padding(.trailing, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t3.web.terminalBackground.color)
        .onAppear {
            // `autoFocus` (`:1114`, `terminal.focus()` at `:545-547`): the tab
            // — and, after a switch, the terminal switched TO — is useless
            // until its emulator has the keyboard. In a split grid only the
            // ACTIVE pane takes it (`:1546`), and the grid moves it on a click.
            guard entry.terminalId == group.activeId else { return }
            DispatchQueue.main.async { entry.view.window?.makeFirstResponder(entry.view) }
        }
    }

    /// `:1443-1486`: an `inline-flex` of icon buttons in a rounded bordered box
    /// over the emulator's top-right corner, in upstream's order — split
    /// horizontal (`SquareSplitHorizontal`, `:1445-1455`), split vertical
    /// (`SquareSplitVertical`, `:1457-1467`), `Plus` "New Terminal"
    /// (`:1263-1265`) and `Trash2` "Close Terminal" (`:1266-1268`), a `w-px`
    /// `border/80` rule between each pair. A split at the limit wears
    /// `opacity-45` and takes no click (`:1446-1450`, `:1270`).
    private var actions: some View {
        HStack(spacing: 0) {
            T3FilesIconButton(help: group.splitHelp(.horizontal)) { group.split(.horizontal) } content: {
                LucideIcon(.squareSplitHorizontal, size: 13)
            }
            .opacity(group.canSplit ? 1 : 0.45)
            .allowsHitTesting(group.canSplit)
            separator
            T3FilesIconButton(help: group.splitHelp(.vertical)) { group.split(.vertical) } content: {
                LucideIcon(.squareSplitVertical, size: 13)
            }
            .opacity(group.canSplit ? 1 : 0.45)
            .allowsHitTesting(group.canSplit)
            separator
            T3FilesIconButton(help: group.newTerminalHelp) { group.newTerminal() } content: {
                LucideIcon(.plus, size: 13)
            }
            .opacity(group.canOpenMore ? 1 : 0.45)
            .allowsHitTesting(group.canOpenMore)
            separator
            T3FilesIconButton(help: "Close Terminal") { confirming = entry.terminalId } content: {
                LucideIcon(.trash2, size: 13)
            }
        }
        .background(t3.web.background.color, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(t3.web.border.color.opacity(0.8), lineWidth: 1)
        )
        .opacity(entry.finished ? 0 : 1)
        .allowsHitTesting(!entry.finished)
    }

    /// `<div className="h-4 w-px bg-border/80" />` (`:1456`).
    private var separator: some View {
        Rectangle()
            .fill(t3.web.border.color.opacity(0.8))
            .frame(width: 1, height: 16)
    }
}

/// The terminal picker (`:1586-1709`): `w-36 min-w-36 flex-col border
/// border-border/70 bg-muted/10`, a 22 pt header of right-aligned action
/// buttons over one block per split group — its header (`showGroupHeaders`,
/// `:1230-1232`) and one row per terminal in it, `pb-0.5` between blocks
/// (`:1650`).
private struct T3TerminalStrip: View {
    @Environment(\.t3) private var t3
    @ObservedObject var group: T3TerminalGroup
    @Binding var confirming: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            // "min-h-0 flex-1 overflow-y-auto px-1 py-1", one `pb-0.5` block per
            // group (`:1650`), each a header over "flex flex-col gap-0.5".
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(group.groups) { split in
                        VStack(spacing: 0) {
                            if group.showsGroupHeaders {
                                T3TerminalGroupHeader(group: group, split: split)
                            }
                            VStack(spacing: 2) {
                                ForEach(split.terminalIds, id: \.self) { id in
                                    T3TerminalStripRow(group: group, terminalId: id,
                                                       confirming: $confirming)
                                }
                            }
                        }
                        .padding(.bottom, 2)
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 144)
        .background(t3.web.muted.color.opacity(0.1))
        .overlay(Rectangle().stroke(t3.web.border.color.opacity(0.7), lineWidth: 1))
    }

    /// `:1588-1627`: "flex h-[22px] items-stretch justify-end border-b
    /// border-border/70", each button "inline-flex h-full items-center px-1"
    /// with a `border-l` between them — split horizontal, split vertical, "+"
    /// and the trash, upstream's order (`:1590-1625`).
    private var header: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            T3TerminalStripButton(help: group.splitHelp(.horizontal), enabled: group.canSplit,
                                  leadingBorder: false) {
                group.split(.horizontal)
            } content: {
                LucideIcon(.squareSplitHorizontal, size: 13)
            }
            T3TerminalStripButton(help: group.splitHelp(.vertical), enabled: group.canSplit,
                                  leadingBorder: true) {
                group.split(.vertical)
            } content: {
                LucideIcon(.squareSplitVertical, size: 13)
            }
            T3TerminalStripButton(help: group.newTerminalHelp, enabled: group.canOpenMore,
                                  leadingBorder: true) {
                group.newTerminal()
            } content: {
                LucideIcon(.plus, size: 13)
            }
            T3TerminalStripButton(help: "Close Terminal", enabled: true, leadingBorder: true) {
                confirming = group.activeId
            } content: {
                LucideIcon(.trash2, size: 13)
            }
        }
        .frame(height: 22)
        .overlay(alignment: .bottom) {
            Rectangle().fill(t3.web.border.color.opacity(0.7)).frame(height: 1)
        }
    }
}

/// One header button: full height, `px-1`, `hover:bg-accent/70`, and the
/// `border-l border-border/70` that separates it from the one before
/// (`:1601-1611`). Disabled wears upstream's `opacity-45` and no hover
/// (`:1592-1595`).
private struct T3TerminalStripButton<Content: View>: View {
    @Environment(\.t3) private var t3
    @State private var hover = false
    let help: String
    let enabled: Bool
    let leadingBorder: Bool
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            content
                .foregroundStyle(t3.web.foreground.color.opacity(0.9))
                .padding(.horizontal, 4)
                .frame(maxHeight: .infinity)
                .background(hover && enabled ? t3.web.accent.color.opacity(0.7) : .clear)
                .overlay(alignment: .leading) {
                    if leadingBorder {
                        Rectangle().fill(t3.web.border.color.opacity(0.7)).frame(width: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .allowsHitTesting(enabled)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// A split group's header in the picker (`:1651-1667`): a 22 pt row of the
/// orientation's own glyph (`Square` / `SquareSplitVertical` /
/// `SquareSplitHorizontal`, `:1643-1647`), the group's name — "Single",
/// "Stacked", "Side by side" (`:1638-1642`) — and its member count in
/// `tabular-nums`. The active group wears `bg-accent/50`; a click selects the
/// group's own active terminal (`:1659`).
private struct T3TerminalGroupHeader: View {
    @Environment(\.t3) private var t3
    @ObservedObject var group: T3TerminalGroup
    let split: T3TerminalSurface.SplitGroup
    @State private var hover = false

    private var isActive: Bool { split.terminalIds.contains(group.activeId) }

    var body: some View {
        Button { group.activateGroup(split) } label: {
            HStack(spacing: 4) {
                LucideIcon(icon, size: 12)
                Text(split.label)
                    .font(T3Font.webLiteral(11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(split.terminalIds.count)")
                    .font(T3Font.webLiteral(10))
                    .monospacedDigit()
                    .foregroundStyle(t3.web.mutedForeground.color.opacity(0.7))
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive || hover ? t3.web.foreground.color : t3.web.mutedForeground.color)
        .background(background, in: RoundedRectangle(cornerRadius: 4))
        .onHover { hover = $0 }
    }

    private var icon: Lucide {
        guard split.isSplit else { return .square }
        return split.orientation == .vertical ? .squareSplitVertical : .squareSplitHorizontal
    }

    private var background: SwiftUI.Color {
        if isActive { return t3.web.accent.color.opacity(0.5) }
        return hover ? t3.web.accent.color.opacity(0.4) : .clear
    }
}

/// One terminal in the picker (`:1676-1700`): "group/tab flex h-6 w-full
/// items-center gap-0.5 rounded-md pr-2 pl-1.5 text-xs", active `bg-accent
/// text-foreground`, inactive `text-muted-foreground hover:bg-accent/60
/// hover:text-foreground`. The leading glyph IS the close button
/// (`PanelTabCloseButton`, `panel-tab-close-button.tsx:19-31`): a `size-4`
/// button whose `size-3` icon becomes an `X` while the row is hovered.
private struct T3TerminalStripRow: View {
    @Environment(\.t3) private var t3
    @ObservedObject var group: T3TerminalGroup
    let terminalId: String
    @Binding var confirming: String?
    @State private var hover = false

    private var isActive: Bool { group.activeId == terminalId }
    private var label: String { T3TerminalSurface.label(terminalId: terminalId) }

    var body: some View {
        HStack(spacing: 2) {
            Button { confirming = terminalId } label: {
                // `TerminalSquare` (`ThreadTerminalDrawer.tsx:1691`) — a
                // deprecated lucide-react alias of `square-terminal`.
                LucideIcon(hover ? .x : .squareTerminal, size: 12)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close \(label)")
            Button { group.activate(terminalId) } label: {
                Text(label)
                    .font(T3Font.web(.xs))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(isActive || hover ? t3.web.foreground.color : t3.web.mutedForeground.color)
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: 24)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hover = $0 }
    }

    private var rowBackground: SwiftUI.Color {
        if isActive { return t3.web.accent.color }
        return hover ? t3.web.accent.color.opacity(0.6) : .clear
    }
}

/// SwiftTerm's view, hosted in a container. Nothing is created here — the entry
/// owns the `TerminalView`, which is what survives a tab switch and a switch to
/// another terminal.
///
/// The container is what makes the drawer/tab handover safe: an NSView has ONE
/// superview, and with two surfaces mounted over the same group SwiftUI runs
/// their dismantle and their insert in an undefined order. Returning
/// `entry.view` straight from `makeNSView` let the OUTGOING representable's
/// teardown pull the view out of the incoming one; re-parenting into a
/// per-representable container instead means the last insert always wins.
private struct T3TerminalEmulator: NSViewRepresentable {
    @Environment(\.t3) private var t3
    let entry: T3TerminalEntry

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 480, height: 320))
        container.autoresizesSubviews = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let view = entry.view
        if view.superview !== container {
            view.removeFromSuperview()
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        // Light/dark, and the first paint: the palette is idempotent.
        entry.applyTheme(t3)
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        // Only the view this container still holds: the other surface may
        // already have taken it (`T3TerminalDrawer.Presenters`).
        for subview in container.subviews where subview is TerminalView {
            subview.removeFromSuperview()
        }
    }
}

// MARK: - The group: one session's terminals, its strip and its active one

/// Every terminal one (cwd, pid) holds: the ordered ids the strip lists, which
/// one is active, and one `T3TerminalEntry` each. Upstream's per-thread
/// terminal UI state, minus the split groups
/// (`apps/web/src/terminalUiStateStore.ts`).
///
/// The id list is SEEDED from the host on every appear (`listTerminals`), so a
/// terminal the phone opened shows up here too; "+" then takes the lowest free
/// id over that same list. An entry whose shell ends leaves the strip the way
/// upstream's does (`onSessionExited → onCloseTerminal`, `:1543`/`:1573`),
/// except for the last one — which stays on its exited screen, so the tab
/// keeps the state it has always shown when a shell dies.
@MainActor
final class T3TerminalGroup: ObservableObject {
    let target: T3TerminalTarget
    /// The SPLIT groups, in the order the strip lists them — upstream's
    /// `resolvedTerminalGroups` (`:1160-1210`), which is also its flat
    /// `terminalIds` order (`:1200-1207` sorts the groups by it). One group per
    /// terminal until a split joins two.
    @Published private(set) var groups: [T3TerminalSurface.SplitGroup] = []
    @Published private(set) var activeId: String = T3Terminal.defaultTerminalId
    /// Which surface is drawing these shells, of the ones currently mounted
    /// (`T3TerminalDrawer.Presenters`). `nil` while neither is.
    @Published private(set) var presenting: T3TerminalDrawer.Owner?

    private let host: TerminalHost
    private var entries: [String: T3TerminalEntry] = [:]
    /// The surfaces this group is mounted in. The FIRST claim attaches every
    /// terminal and the LAST release detaches them all (the shells keep
    /// running) — a group shown in the drawer must not go dead because the
    /// right panel switched away from Terminal.
    private var presenters = T3TerminalDrawer.Presenters()
    private var visible: Bool { !presenters.isEmpty }

    init(target: T3TerminalTarget, host: TerminalHost) {
        self.target = target
        self.host = host
    }

    /// Every terminal this session holds, in strip order — upstream's
    /// `normalizedTerminalIds`, which its groups partition (`:1192-1207`).
    var terminalIds: [String] { groups.flatMap(\.terminalIds) }

    /// The group the active terminal is in (`resolvedActiveGroupIndex`,
    /// `:1212-1221`).
    var activeGroup: T3TerminalSurface.SplitGroup? {
        groups.first { $0.terminalIds.contains(activeId) } ?? groups.first
    }

    /// `hasTerminalSidebar` (`:1228`): the picker appears with the second
    /// terminal, and the floating cluster gives way to it (`:1442`).
    var showsStrip: Bool { terminalIds.count > 1 }

    /// `showGroupHeaders` (`:1230-1232`): from the moment there is more than one
    /// group, or any group holds more than one terminal — so two lone terminals
    /// each get a "Single" header, exactly as upstream.
    var showsGroupHeaders: Bool { groups.count > 1 || groups.contains(where: \.isSplit) }

    var activeEntry: T3TerminalEntry? { entries[activeId] }

    /// A listed terminal's entry. Never creates one: the grid draws over ids
    /// this group already opened (`appear`, `newTerminal`, `split`).
    func entry(id: String) -> T3TerminalEntry? { entries[id] }

    /// The tab's own title (`RightPanelTabs.tsx:598-602`).
    var activeLabel: String { T3TerminalSurface.label(terminalId: activeId) }

    var canOpenMore: Bool { terminalIds.count < T3Terminal.maxTerminalsPerSession }

    /// `newTerminalActionLabel` (`:1263-1265`); at the cap it names the cap the
    /// way upstream's split label does (`:1253-1254`).
    var newTerminalHelp: String {
        canOpenMore ? "New Terminal"
                    : "New Terminal (max \(T3Terminal.maxTerminalsPerSession) per session)"
    }

    /// `hasReachedSplitLimit` inverted (`:1233`) — plus this host's own
    /// per-session cap, which a split spends a slot of just as "+" does.
    var canSplit: Bool { canOpenMore && (activeGroup?.canSplit ?? false) }

    /// `splitTerminalActionLabel` / `splitTerminalVerticalActionLabel`
    /// (`:1253-1262`), verbatim — with the per-group limit named at the limit.
    /// (Upstream's shortcut suffix has no equivalent here: the tab binds no
    /// split shortcut.) At this host's own cap the sentence is
    /// `newTerminalHelp`'s.
    func splitHelp(_ orientation: T3TerminalSurface.SplitGroup.Orientation) -> String {
        let name = orientation == .vertical ? "Split Terminal Vertically"
                                           : "Split Terminal Horizontally"
        if activeGroup?.canSplit == false {
            return "\(name) (max \(T3TerminalSurface.SplitGroup.maxPerGroup) per group)"
        }
        if !canOpenMore { return "\(name) (max \(T3Terminal.maxTerminalsPerSession) per session)" }
        return name
    }

    // MARK: Lifecycle

    /// A surface appeared. It takes the shells over (the newest claim draws) and
    /// the ids are re-seeded from the host — a terminal the phone opened while
    /// this group was off screen shows up on the way back in.
    func appear(as owner: T3TerminalDrawer.Owner) {
        presenters.claim(owner)
        if presenting != presenters.current { presenting = presenters.current }
        // Whatever the host holds for this pid, plus whatever this group
        // already listed (an entry mid-open is not on the host's map yet).
        let held = host.listTerminals(pid: target.pid).map(\.terminalId)
        var ids = held
        for id in terminalIds where !ids.contains(id) { ids.append(id) }
        if ids.isEmpty { ids = [T3Terminal.defaultTerminalId] }
        reconcile(ids)
        let ordered = terminalIds
        if !ordered.contains(activeId), let first = ordered.first { activeId = first }
        // Every terminal stays attached, not just the visible ones: an
        // unattached terminal starts this host's 30-minute idle clock, and a
        // shell the strip lists must not die because its group was not the one
        // on screen.
        for id in ordered { entry(for: id).appear() }
    }

    /// One surface went away. The other, if it is still mounted, takes the
    /// shells back; only the LAST release detaches them.
    func disappear(as owner: T3TerminalDrawer.Owner) {
        presenters.release(owner)
        if presenting != presenters.current { presenting = presenters.current }
        guard presenters.isEmpty else { return }
        for entry in entries.values { entry.disappear() }
    }

    /// The window closed: every surface at once (`T3TerminalRegistry.detachAll`).
    func disappear() {
        for owner in T3TerminalDrawer.Owner.allCases { presenters.release(owner) }
        if presenting != nil { presenting = nil }
        for entry in entries.values { entry.disappear() }
    }

    func activate(_ id: String) {
        guard terminalIds.contains(id) else { return }
        activeId = id
    }

    /// A strip GROUP header (`:1631-1635`, `:1659`): the group's own active
    /// terminal when it holds it, its first otherwise.
    func activateGroup(_ group: T3TerminalSurface.SplitGroup) {
        guard !group.terminalIds.contains(activeId), let first = group.terminalIds.first
        else { return }
        activate(first)
    }

    /// "+" (`onNewTerminalAction`, `:1277-1279`): the lowest free `term-N` over
    /// the ids the HOST holds (the phone's included) and the ones this strip
    /// lists, opened and focused.
    func newTerminal() {
        guard canOpenMore, let id = freeTerminalId() else { return }
        // `"new"` mode (`terminalUiStateStore.ts:282-293`): its own group,
        // which is why "+" never joins the grid the active terminal is in.
        groups.append(Self.freshGroup(for: id, avoiding: groups))
        activeId = id
        entry(for: id).appear()
    }

    /// A split (`onSplitTerminalAction` / `onSplitTerminalVerticalAction`,
    /// `:1269-1276`): the SAME host path as "+" — a new shell on the next free
    /// id — joining the ACTIVE group right beside the active pane and setting
    /// that group's orientation (`upsertTerminalIntoGroups` in `"split"` mode).
    func split(_ orientation: T3TerminalSurface.SplitGroup.Orientation) {
        guard canSplit,
              let index = groups.firstIndex(where: { $0.terminalIds.contains(activeId) }),
              let id = freeTerminalId()
        else { return }
        var group = groups[index]
        guard group.split(active: activeId, orientation: orientation, newId: id) else { return }
        groups[index] = group
        activeId = id
        entry(for: id).appear()
    }

    /// The lowest free `term-N` over the ids the HOST holds (the phone's
    /// included) and the ones this surface lists (`nextTerminalId`,
    /// `terminalLabels.ts:32-40`); `nil` when that id is somehow already listed.
    private func freeTerminalId() -> String? {
        let held = host.listTerminals(pid: target.pid).map(\.terminalId)
        let id = T3TerminalSurface.nextTerminalId(held + terminalIds)
        return terminalIds.contains(id) ? nil : id
    }

    /// The groups after the host's own list: a member the host no longer holds
    /// leaves its group, an emptied group goes, and every id in no group becomes
    /// a group of one — `normalizeTerminalGroups`
    /// (`terminalUiStateStore.ts:99-140`, `:1192-1198`).
    private func reconcile(_ ids: [String]) {
        var next: [T3TerminalSurface.SplitGroup] = []
        var assigned = Set<String>()
        for group in groups {
            var kept: T3TerminalSurface.SplitGroup? = group
            for gone in group.terminalIds where !ids.contains(gone) {
                kept = kept?.removing(gone, active: activeId).group
            }
            guard let kept else { continue }
            next.append(kept)
            assigned.formUnion(kept.terminalIds)
        }
        for id in ids where !assigned.contains(id) {
            next.append(Self.freshGroup(for: id, avoiding: next))
            assigned.insert(id)
        }
        if next != groups { groups = next }
    }

    /// A group of one under `assignUniqueGroupId`'s rule
    /// (`terminalUiStateStore.ts:77-86`): `group-<id>`, and `-2`, `-3`… when
    /// that is taken — a group outlives the terminal it was named after.
    private static func freshGroup(for terminalId: String,
                                   avoiding existing: [T3TerminalSurface.SplitGroup])
        -> T3TerminalSurface.SplitGroup {
        let fresh = T3TerminalSurface.SplitGroup(terminalId: terminalId)
        guard existing.contains(where: { $0.id == fresh.id }) else { return fresh }
        var index = 2
        while existing.contains(where: { $0.id == "\(fresh.id)-\(index)" }) { index += 1 }
        return .init(id: "\(fresh.id)-\(index)", terminalIds: [terminalId])
    }

    /// The trash and every row's X, once confirmed. The entry leaves the strip
    /// when its shell reports `exited`/`closed`, not here — a close that the
    /// host refuses must not make the strip lie.
    func close(_ id: String) {
        entries[id]?.closeShell()
    }

    private func entry(for id: String) -> T3TerminalEntry {
        if let existing = entries[id] { return existing }
        let entry = T3TerminalEntry(target: target, terminalId: id, host: host) { [weak self] id, message in
            self?.entryFinished(id, message: message)
        }
        // `onMouseDown` (`:1523-1527`): a click anywhere in a pane makes that
        // pane the active terminal.
        entry.view.onMouseDown = { [weak self] in self?.activate(id) }
        entries[id] = entry
        return entry
    }

    /// A shell ended (or failed to start). Upstream drops the terminal from the
    /// list (`onSessionExited → onCloseTerminal(terminalId)`, `:1543`/`:1573`)
    /// and selects whoever took its slot (`terminalUiStateStore.ts:409-429`).
    /// The last one is the exception: it keeps its exited screen, and the next
    /// appear starts a fresh shell in it.
    private func entryFinished(_ id: String, message: String?) {
        guard terminalIds.count > 1,
              let index = groups.firstIndex(where: { $0.terminalIds.contains(id) })
        else { return }
        // Over the whole strip, for the case where the group goes with it.
        let acrossGroups = T3TerminalSurface.activeAfterClose(ids: terminalIds,
                                                             closing: id, active: activeId)
        // Inside the group: the grid collapses to the panes around it and the
        // one that took its slot is active — upstream picks the flat-order
        // neighbour instead (`terminalUiStateStore.ts:423-429`), which can land
        // in a group that is not even on screen; staying in the visible grid is
        // the one deliberate difference here.
        let removal = groups[index].removing(id, active: activeId)
        if let group = removal.group { groups[index] = group } else { groups.remove(at: index) }
        entries[id]?.disappear()
        entries[id] = nil
        if let next = removal.group == nil ? acrossGroups : removal.active { activeId = next }
        // An open that FAILED (the host is full, or the shell would not start)
        // takes its row with it — but never silently: the sentence lands on the
        // terminal the strip falls back to.
        if let message, let entry = activeEntry { entry.note(message) }
        if visible, let entry = activeEntry { entry.appear() }
    }
}

// MARK: - The entry: one shell, one emulator, one attachment

/// Everything about one terminal that must outlive the SwiftUI view: the
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
    let terminalId: String
    let view: T3TerminalPaneView
    /// The shell is gone (`exited`/`closed`): the actions hide and the next
    /// appear starts a new one.
    @Published private(set) var finished = false

    private let host: TerminalHost
    private let io = DispatchQueue(label: "run.infinitus.terminal-tab")
    /// The group's hook: this terminal's shell ended, with the sentence to say
    /// out loud if it never started at all.
    private let onFinish: (String, String?) -> Void
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

    init(target: T3TerminalTarget, terminalId: String, host: TerminalHost,
         onFinish: @escaping (String, String?) -> Void) {
        self.target = target
        self.terminalId = terminalId
        self.host = host
        self.onFinish = onFinish
        // `cursorStyle: .steadyBlock` — SwiftTerm's default `.blinkBlock` runs
        // a `repeatCount: .infinity` opacity CABasicAnimation on the caret
        // layer (`MacCaretView.swift:92-105`), i.e. a timer in an idle tab
        // (#507 ruling 6, and the repo's own no-continuous-motion rule).
        var options = TerminalOptions(cursorStyle: .steadyBlock)
        options.scrollback = T3Terminal.ringBytes / 80   // ~3200 lines, the ring's own depth
        view = T3TerminalPaneView(frame: CGRect(x: 0, y: 0, width: 480, height: 320),
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
                                    request: T3Terminal.OpenRequest(cols: size.cols, rows: size.rows,
                                                                    terminalId: id))
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
            markFinished(message: nil)
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
    /// so the next appear tries again. With other terminals open the group
    /// takes this row away and says the sentence in the one it falls back to.
    private func openFailed(_ error: TerminalHost.HostError) {
        opening = false
        let sentence = Self.sentence(error)
        note(sentence)
        markFinished(message: sentence)
    }

    /// A write that could not land — the pty's reader has stopped. Said out
    /// loud (never swallowed) but not fatal: the shell is still there.
    func note(_ message: String) {
        view.feed(text: T3TerminalSurface.systemMessage(message))
    }

    private static func sentence(_ error: TerminalHost.HostError) -> String {
        switch error {
        case .spawnFailed(let reason): return reason
        case .validation(.tooManyTerminals):
            return "this session already has \(T3Terminal.maxTerminalsPerSession) terminals"
        case .validation(.terminalIdInvalid): return "the terminal id was refused"
        case .validation(.colsOutOfRange), .validation(.rowsOutOfRange):
            return "the terminal size was refused"
        case .validation(.dataTooLarge): return "the input was too large"
        }
    }

    /// One exit per shell, and the group told once (`hasHandledExitRef`,
    /// `:299-306`).
    private func markFinished(message: String?) {
        guard !finished else { return }
        finished = true
        onFinish(terminalId, message)
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
                    note(T3TerminalSurface.exitedMessage)
                    markFinished(message: nil)
                }
            case .closed:
                if !finished {
                    note(T3TerminalSurface.closedMessage)
                    markFinished(message: nil)
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
                        note(T3TerminalSurface.exitedMessage)
                        markFinished(message: nil)
                    }
                case .error:
                    if !finished {
                        note("the shell failed to start")
                        markFinished(message: nil)
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

/// SwiftTerm's view plus upstream's `onMouseDown` (`:1523-1527`): a click
/// anywhere in a pane makes that pane the active terminal. A SwiftUI gesture
/// over the representable would never see it — `TerminalView` takes `mouseDown`
/// for its own selection.
final class T3TerminalPaneView: TerminalView {
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
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

/// The window's live terminals, one group per (cwd, pid) and one emulator per
/// terminal inside it. On the window model so a tab switch, a thread switch and
/// back, or a re-identified surface all find the same emulators, the same strip
/// and the same `since`.
@MainActor
final class T3TerminalRegistry {
    private weak var app: AppModel?
    private var groups: [T3TerminalTarget: T3TerminalGroup] = [:]

    init(app: AppModel?) { self.app = app }

    /// `nil` only once the window has outlived its `AppModel` — there is no
    /// host to open a shell on then, and nothing to show but the skeleton.
    func group(for target: T3TerminalTarget) -> T3TerminalGroup? {
        if let existing = groups[target] { return existing }
        guard let app else { return nil }
        let group = T3TerminalGroup(target: target, host: app.terminalHost)
        groups[target] = group
        return group
    }

    /// The group this target already has, if any — the tab STRIP titles itself
    /// from it (`RightPanelTabs.tsx:598-602`) and must never bring one into
    /// existence just by drawing a title.
    func existingGroup(for target: T3TerminalTarget) -> T3TerminalGroup? { groups[target] }

    /// The window closed (`T3WindowModel.stop`): detach every terminal, never
    /// close — the shells outlive the window, exactly as they outlive a tab
    /// switch, and `AppModel.terminalHost.closeAll()` is what ends them.
    func detachAll() {
        for group in groups.values { group.disappear() }
    }
}
