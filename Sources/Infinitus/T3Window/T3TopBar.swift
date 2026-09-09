import SwiftUI
import AppKit
import InfinitusCore
import InfinitusUI

/// The workspace window's real top bar (Task 8): `WorkspacePageHeader.tsx`'s
/// band + `WorkspaceBreadcrumb.tsx` inside `ChatHeader.tsx`'s action cluster
/// (`OpenInPicker.tsx`, `ProjectScriptsControl.tsx`, `GitActionsControl.tsx`),
/// plus the right-panel toggle upstream floats as `PanelLayoutControls.tsx`'s
/// `Toggle` (B renders it inline in the topbar's own flow instead of a
/// window-level fixed overlay — B has no `terminalOpen`/right-panel-sheet
/// mode to reconcile a fixed overlay against). The sidebar toggle
/// (`AppSidebarLayout.tsx`'s `SidebarControl`) is genuinely
/// window-level — a fixed sibling of the sidebar/main/panel row, not part
/// of any one column — so `T3Root` renders it, not this view; see
/// `leadingInset` below for the space this view still reserves for it.
/// Replaces Task 6's `T3TopBarPlaceholder`.
///
/// With no thread selected this band IS `NoActiveThreadState.tsx`'s own
/// `WorkspacePageHeader` (`className="border-b border-border"`) — the "No
/// active thread" text used to render as `T3NoActiveThreadState`'s own
/// stacked label row (Task 6); that row moves here. The `border-b` renders
/// only in that no-thread state — the with-thread `WorkspacePageHeader`
/// instance in `ChatView.tsx:8140` carries none (B-3 review; Task 8's first
/// pass had unified the border onto both states).
struct T3TopBar: View {
    @ObservedObject var model: T3WindowModel
    @ObservedObject var app: AppModel
    /// The main column's width, proposed by `T3Root` (window − sidebar −
    /// right panel). `ChatHeader.tsx:315-317` marks the header content div
    /// `@container/header-actions`, and that div fills the column, so this is
    /// what its container queries measure. Measuring it here with a
    /// `GeometryReader` instead would feed this view's own children's widths
    /// back into their own proposal.
    let columnWidth: Double
    @Environment(\.t3) private var t3

    /// Tailwind v4's `--container-3xl: 48rem` (`theme.css:341`): the one
    /// breakpoint `ChatHeader.tsx:408` and `OpenInPicker.tsx:283-291` query.
    private static let containerBreakpoint3xl: Double = 768
    private var wide: Bool { columnWidth >= Self.containerBreakpoint3xl }
    // Fix round 1 (task-8-fix1-brief.md R1): each menu-fronted control's
    // trigger button reports its own NSView here via `MenuAnchor`, so its
    // action closure can call `NSMenu.popUp(positioning:at:in:)` on it.
    @State private var addActionAnchor: NSView?
    @State private var commitPushAnchor: NSView?
    @State private var openInAnchor: NSView?
    @State private var commitPushMenuAnchor: NSView?

    private var project: T3ProjectGrouping.Project? {
        guard let thread = model.state.selectedThread else { return nil }
        return model.state.projects.first { $0.id == thread.projectId }
    }

    var body: some View {
        HStack(spacing: 0) {
            leadingInset
            if let thread = model.state.selectedThread {
                breadcrumb(thread: thread)
            } else {
                // NoActiveThreadState.tsx's isElectron branch: "text-xs text-muted-foreground/50".
                // `WorkspacePageHeader.tsx:19` is a plain `flex items-center`
                // row with padding — the label starts at the leading inset
                // and the controls stay at the trailing edge. Without this
                // the whole row is fixed-width and the outer
                // `.frame(maxWidth: .infinity)` centres it (B-3 review).
                Text("No active thread")
                    .font(T3Font.web(.xs))
                    .foregroundStyle(t3.web.mutedForeground.color.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // R2 (fix1 brief): the breadcrumb above is the row's ONLY
            // flexible member (its own `.frame(maxWidth: .infinity)`) — this
            // gap is fixed, not an expanding `Spacer`, so nothing else in
            // the row competes for leftover width. It is
            // `ChatHeader.tsx:316`'s `gap-2 sm:gap-3` on the header content
            // div — a VIEWPORT breakpoint the window's 840 pt minimum always
            // clears, so always 12, unlike the actions gap below.
            Color.clear.frame(width: 12)
            // `ChatHeader.tsx:408`: the actions div is `gap-2
            // @3xl/header-actions:gap-3` — a CONTAINER query, so the gap is 8
            // until the header itself reaches 768 pt and 12 above it. With
            // the right panel open at 840 the column is ~380 pt wide and the
            // 12 pt gaps overflowed it (B-3 review).
            HStack(spacing: wide ? 12 : 8) { actions }
            // R4 (fix1 brief): `ChatHeader.tsx:405-408`'s actions div is
            // `pr-16` (64pt) while the toggle shows (`pr-0` once the right
            // panel is open and the panel itself separates it — B has no
            // such conditional, this task's scope is the toggle-visible
            // case only); `index.css:110`'s `--workspace-controls-right`
            // (12pt) is the toggle's own trailing inset. 24 + 28 (toggle
            // width) + 12 = 64, so the actions cluster's trailing edge
            // still lands 64pt from the window's right edge.
            // Measured against the 2x reference with both toggles present:
            // the actions cluster's trailing edge sits 12 pt from the panel
            // controls (`ChatHeader.tsx:316`'s own `gap-3`), and the group's
            // 28 + 4 + 28 plus `index.css:110`'s 12 pt inset fill the rest.
            // The 24 here came from reading `pr-16` as the whole trailing
            // run while only ONE toggle stood in it.
            Color.clear.frame(width: 12)
            // `PanelLayoutControls.tsx:47-60`'s terminal-drawer `Toggle`,
            // `PanelBottomIcon size-4`, first in the group's own `gap-1`
            // (`:36`). B has no terminal drawer to open, and the reference's
            // header keeps the control's width whether or not it can be
            // pressed, so it renders in upstream's own `disabled` shape —
            // never pressed — and says where the drawer is.
            T3TopBarToggle(icon: .panelBottom, pressed: false,
                            tooltip: "The bottom panel arrives with the terminal") {}
            Color.clear.frame(width: 4)   // `PanelLayoutControls.tsx:36` gap-1
            // `PanelLayoutControls.tsx:61-80`'s right-panel `Toggle`.
            T3TopBarToggle(icon: .panelRight, pressed: model.state.rightPanelOpen,
                            tooltip: "Toggle right panel (\u{2318}J)") {
                withAnimation(.easeOut(duration: 0.2)) { model.toggleRightPanel() }
            }
            Color.clear.frame(width: 12)   // `index.css:110` --workspace-controls-right
        }
        .frame(height: T3Theme.Metrics.topbarHeight)
        .frame(maxWidth: .infinity)
        // `toolbarBackground` == `background`/`appChromeBackground` by value
        // (T3Theme.generated.swift) — WorkspacePageHeader itself carries no
        // background class of its own; ChatView's instance is "bg-background",
        // so the alias renders identically here.
        .background(t3.web.toolbarBackground.color)
        // Upstream borders only the no-thread header (`NoActiveThreadState.tsx:10`
        // `className="border-b border-border"`), not the with-thread bar
        // (`ChatView.tsx:8140` `className="relative bg-background"`, no
        // `border-b`) — B-3 review corrects Task 8's "unify onto both" call.
        .overlay(alignment: .bottom) {
            if model.state.selectedThread == nil {
                Rectangle().fill(t3.web.border.color).frame(height: 1)
            }
        }
    }

    // `ui/sidebar.tsx:169-170`'s `--workspace-titlebar-content-left` =
    // `--workspace-controls-left` (90 pt, `AppSidebarLayout.tsx:49`'s
    // `MACOS_TRAFFIC_LIGHTS_LEFT_INSET`) + `--workspace-titlebar-control-size`
    // (28 pt) + `--workspace-titlebar-control-gap` (12 pt, both
    // `index.css:112-113`) = 130 pt, applied only while the sidebar is
    // collapsed and its own lights sit over the main column instead of the
    // sidebar's brand row (`T3SidebarView.brandRow`, B-3 review). The 90 pt
    // slot itself is `T3Root`'s job (`AppSidebarLayout.tsx:258`'s
    // `<SidebarControl />`, a fixed sibling of `{children}`, not part of
    // either column) — this is just the topbar's own content clearing it.
    @ViewBuilder private var leadingInset: some View {
        if model.state.sidebarCollapsed {
            Spacer().frame(width: 130)
        } else {
            // `WorkspacePageHeader.tsx`'s own base inset, `sm:` breakpoint
            // (always active — the window's minimum width clears 640 px):
            // "sm:pl-[calc(env(safe-area-inset-left)+1.25rem)]" = 20 pt.
            Spacer().frame(width: 20)
        }
    }

    // MARK: - Breadcrumb

    // `WorkspaceBreadcrumb.tsx`: items `sm` medium; current thread title in
    // `foreground`, the project item in `mutedForeground`; separator "/" in
    // `iconMuted`; gap "gap-2 sm:gap-3" = 12 pt (the `sm:` breakpoint,
    // always active here too — Tailwind's `gap-3` is 0.75 rem, not the
    // literal digit 3). Both items are plain text — upstream's project item
    // opens "new thread in project" and the thread item opens a rename/action
    // menu, neither of which B wires yet (no `onNewThreadInProject` /
    // thread-rename plumbing in this task's scope).
    //
    // R2 (fix1 brief): `ChatHeader.tsx:329`'s project button is `max-w-40
    // truncate` (10rem = 160pt) with `className="shrink"` overriding the
    // breadcrumb item's default `shrink-0` — it's meant to cap AND shrink,
    // not hug its content. The Task 8 first pass's `.fixedSize` on the
    // icon+name pair defeated both (SwiftUI adopts the unconstrained ideal
    // width under `.fixedSize`, so a sibling `.frame(maxWidth:)` has no
    // proposal left to clamp) — removed; `CapToContent` below does the job.
    //
    // B-3 review: the priority was inverted. CSS gives the title item
    // `min-w-10 flex-1` (`:352`) — flex-basis 0, so it takes the leftover and
    // is the member that TRUNCATES — while the project item is `shrink` with
    // a content basis capped at 160 (`:332`,`:360`), so it keeps
    // min(content, 160) and only gives way under real squeeze. The title's
    // `.layoutPriority(1)` said the opposite (it made the title hold its
    // ideal width and the project cluster collapse), so it is gone: the two
    // siblings are equal-priority and SwiftUI serves the less flexible one —
    // `CapToContent`, whose range is [0, min(ideal, 160)] — first.
    @ViewBuilder private func breadcrumb(thread: T3Thread) -> some View {
        HStack(spacing: 12) {
            if let project {
                HStack(spacing: 6) {
                    // `ChatHeader.tsx:341`'s `<ProjectFavicon …
                    // className="size-3.5">` — the same automatic project
                    // glyph the sidebar rows draw (Task 7's `T3ProjectGlyph`),
                    // at 14 pt. `.fixedSize()`: the icon never
                    // shrinks/truncates.
                    T3ProjectGlyph(projectName: project.name, projectCwd: project.cwd, size: 14).fixedSize()
                    // Measured (fix1 brief's own literal R2 prescription,
                    // `/tmp/ours-fix1.png`): `.frame(maxWidth: 160)` alone,
                    // without `.fixedSize`, is flexible — it accepts
                    // whatever width the row offers (up to 160), so on this
                    // wide window it greedily filled to 160pt even for the
                    // short name "limitless" (name-end to "/" measured
                    // ~120pt apart, reproducing the exact round-1 bug this
                    // task already fixed once). `.fixedSize` alone hugs but
                    // never truncates (no cap). Neither modifier alone gets
                    // CSS's actual behavior here (`flex-shrink` hug, capped,
                    // truncate past the cap) — `CapToContent` below does:
                    // reports `min(ideal, 160)` upward (hug + cap) and
                    // proposes that same width down to the Text (so it
                    // truncates past 160). Untested past the fixture's short
                    // "limitless" name (no 160pt+ name available to capture).
                    CapToContent(maxWidth: 160) {
                        Text(project.name).lineLimit(1).truncationMode(.tail)
                    }
                }
                .font(T3Font.web(.sm, .medium))
                .foregroundStyle(t3.web.mutedForeground.color)
                Text("/")
                    .font(T3Font.web(.sm, .medium))
                    .foregroundStyle(t3.web.iconMuted.color)
            }
            Text(thread.title)
                .font(T3Font.web(.sm, .medium))
                .foregroundStyle(t3.web.foreground.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 40, alignment: .leading)   // `:352` "min-w-10 flex-1 truncate"
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    @ViewBuilder private var actions: some View {
        if let project {
            menuButton(icon: .plus, title: "Add action",
                       disabledMessage: "Project actions arrive with a later release", anchor: $addActionAnchor)
            openInControl(project: project)
            gitActionsControl
        }
    }

    // `GitActionsControl.tsx:1643-1694`'s `<Group aria-label="Git actions">`:
    // the quick action as an `xs` outline button, a `GroupSeparator`, and an
    // `icon-xs` outline `MenuTrigger` carrying `ChevronDownIcon size-4` — the
    // same joined pill `openInControl` builds, and unconditional once the
    // project is a repo. The first pass collapsed it to one pill, which left
    // the whole actions cluster 44 px narrower than the reference's and
    // therefore that much further right.
    //
    // B ships no git actions, so both segments open the same one-row disabled
    // menu (`showDisabledMenu`) rather than doing nothing quietly.
    private var gitActionsControl: some View {
        let radius = T3Theme.Metrics.controlRadius
        let h = T3ButtonMetrics.height(.xs)
        return HStack(spacing: 0) {
            Button { showDisabledMenu(Self.gitPending, from: commitPushAnchor) } label: {
                // `:1731`'s `ps-[8.5px]` and the label's own `ml-0.5` on top
                // of the button's `gap-1`.
                HStack(spacing: 6) { LucideIcon(.gitCommit, size: 14); Text("Commit & push").font(T3Font.web(.xs, .medium)) }
                    .padding(.leading, 8.5)
                    .padding(.trailing, T3ButtonMetrics.horizontalPadding(.xs))
            }
            .buttonStyle(.plain)
            .frame(height: h)
            .foregroundStyle(t3.web.foreground.color)
            .background(t3.web.popover.color, in: UnevenRoundedRectangle(
                topLeadingRadius: radius, bottomLeadingRadius: radius, bottomTrailingRadius: 0, topTrailingRadius: 0))
            .background(MenuAnchor(view: $commitPushAnchor))

            // `GroupSeparator`, `hidden @3xl/header-actions:block` (`:1746`).
            if wide { Rectangle().fill(t3.web.input.color).frame(width: 1, height: h) }

            Button { showDisabledMenu(Self.gitPending, from: commitPushMenuAnchor) } label: {
                LucideIcon(.chevronDown, size: 16)   // `:1753` "size-4"
                    .frame(width: h, height: h)
            }
            .buttonStyle(.plain)
            .foregroundStyle(t3.web.foreground.color)
            .background(t3.web.popover.color, in: UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: radius, topTrailingRadius: radius))
            .accessibilityLabel("Git action options")
            .background(MenuAnchor(view: $commitPushMenuAnchor))
        }
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(t3.web.input.color, lineWidth: 1))
    }

    private static let gitPending = "Git actions arrive with a later release"

    // `ProjectScriptsControl.tsx`'s zero-scripts branch, collapsed to one
    // `size="xs" variant="outline"` button + a one-row disabled menu (B ships no project-scripts backend
    // and no git actions — Task 16/F may add the latter). The disabled row's
    // copy ("Project actions arrive with a later release" /
    // "Git actions arrive with a later release") is B's OWN wording, not
    // transcribed from upstream's disabled-state copy — there is no
    // upstream "not implemented yet" string to transcribe here.
    //
    // R1 (fix1 brief): a real `NSMenu` (`showDisabledMenu`, below) replaces
    // the first pass's `.popover` — a `.popover` renders whatever content
    // view it's given, so it kept the button's outline chrome, but it has
    // none of a real menu's dismiss-on-outside-click, Esc, or arrow-key
    // semantics. `NSMenu.popUp(positioning:at:in:)` gets both real chrome
    // and real keyboard semantics; T3's own `dropdown-glass` blur/shadow
    // look (`menu.tsx:53-95`) is NOT reproduced by a plain `NSMenu` — a
    // documented parity gap, not attempted here.
    private func menuButton(icon: Lucide, title: String, disabledMessage: String, anchor: Binding<NSView?>) -> some View {
        Button {
            showDisabledMenu(disabledMessage, from: anchor.wrappedValue)
        } label: {
            // `size="xs"` at the `sm:` breakpoint is `h-6` (24 pt) `text-xs`
            // (`button.tsx:36`) — `ProjectScriptsControl.tsx:250`'s
            // "Add action" trigger and `GitActionsControl.tsx:1617`'s
            // "Commit & push" trigger both carry it.
            // `button.tsx:36`'s xs row is `h-7 gap-1 …` — gap-1 = 4 pt
            // between the leading glyph and the label, not 6.
            outline { HStack(spacing: 4) { LucideIcon(icon, size: 14); Text(title).font(T3Font.web(.xs, .medium)) } }
        }
        .buttonStyle(.plain)
        .background(MenuAnchor(view: anchor))
    }

    // R3 (fix1 brief): `OpenInPicker.tsx`'s split control is one joined
    // `<Group>` (`ui/group.tsx:10-11`) — zero gap between segments, each
    // segment rounded only on its own outer corner, a 1pt `GroupSeparator`
    // (`bg-input`) between them, one continuous 1pt outline around the
    // union. Chevron is `size-4` = 16pt (`OpenInPicker.tsx:299`), not 14.
    //
    // B-3 review: the primary segment is `disabled={!preferredEditor || …}`
    // (`OpenInPicker.tsx:275`), and `usePreferredEditor`
    // (`editorPreferences.ts:41-50`) resolves to the first AVAILABLE editor,
    // falling to `null` only when none is installed — so with no editor on
    // the machine the button is dead, not a shortcut to Finder. It opens
    // `preferredEditor` (`:276`), never Finder; Finder lives in the chevron
    // menu (`showOpenInMenu`) alongside every editor actually installed.
    private func openInControl(project: T3ProjectGrouping.Project) -> some View {
        let radius = T3Theme.Metrics.controlRadius
        // `OpenInPicker.tsx:273`: `size="xs"` on the "Open" segment;
        // `:293`: `size="icon-xs"` on the chevron — both 24 pt at the
        // `sm:` breakpoint (`button.tsx:36`).
        let h = T3ButtonMetrics.height(.xs)
        let preferred = preferredEditor
        return HStack(spacing: 0) {
            Button { if let preferred { openIn(bundleId: preferred.bundleId, cwd: project.cwd) } } label: {
                // `button.tsx:36`'s `gap-1` = 4 pt. `OpenInPicker.tsx:283-290`
                // wraps the label in `sr-only @3xl/header-actions:not-sr-only`:
                // below a 768 pt header the primary is icon-only.
                // `:277-282` renders the icon only when there IS a primary
                // option (`{primaryOption?.Icon && …}`) — with no editor
                // installed the disabled button is genuinely empty upstream.
                HStack(spacing: 4) {
                    if let preferred { LucideIcon(preferred.icon, size: 14) }
                    if wide { Text("Open").font(T3Font.web(.xs, .medium)) }
                }
                .padding(.horizontal, T3ButtonMetrics.horizontalPadding(.xs))
            }
            .buttonStyle(.plain)
            .disabled(preferred == nil)
            // `button.tsx:11` `disabled:opacity-64`.
            .opacity(preferred == nil ? 0.64 : 1)
            .frame(height: h)
            .foregroundStyle(t3.web.foreground.color)
            .background(t3.web.popover.color, in: UnevenRoundedRectangle(
                topLeadingRadius: radius, bottomLeadingRadius: radius, bottomTrailingRadius: 0, topTrailingRadius: 0))

            // `GroupSeparator`'s `bg-input`, itself `hidden
            // @3xl/header-actions:block` (`OpenInPicker.tsx:291`) — the two
            // segments merge into one pill below 768.
            if wide { Rectangle().fill(t3.web.input.color).frame(width: 1, height: h) }

            Button { showOpenInMenu(project: project, from: openInAnchor) } label: {
                LucideIcon(.chevronDown, size: 16)   // `OpenInPicker.tsx:299` "size-4"
                    .frame(width: h, height: h)
            }
            .buttonStyle(.plain)
            .foregroundStyle(t3.web.foreground.color)
            .background(t3.web.popover.color, in: UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: radius, topTrailingRadius: radius))
            .background(MenuAnchor(view: $openInAnchor))
        }
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(t3.web.input.color, lineWidth: 1))
    }

    /// `button.tsx`'s `variant="outline" size="xs"` chrome (`border-input
    /// bg-popover`, `text-foreground`) as a `Button` label — the two
    /// single-pill menu-fronted controls rebuild its look here directly
    /// (no hover state: a menu trigger's affordance is the click, not a
    /// hover fill; `T3Button` itself carries hover, which these
    /// deliberately don't need). `openInControl` above builds its own
    /// joined-pill chrome instead of using this helper (R3, fix1 brief).
    @ViewBuilder
    private func outline<Content: View>(square: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, square ? 0 : T3ButtonMetrics.horizontalPadding(.xs))
            .frame(minWidth: square ? T3ButtonMetrics.height(.xs) : nil)
            .frame(height: T3ButtonMetrics.height(.xs))
            .foregroundStyle(t3.web.foreground.color)
            .background(t3.web.popover.color, in: RoundedRectangle(cornerRadius: T3Theme.Metrics.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: T3Theme.Metrics.controlRadius).stroke(t3.web.input.color, lineWidth: 1))
    }

    // MARK: - Native menus (R1, fix1 brief)

    private func showDisabledMenu(_ message: String, from anchor: NSView?) {
        guard let anchor else { return }
        let menu = NSMenu()
        let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        // 4 pt below the trigger, per the fix brief; `nil` item places the
        // menu's top-left corner at `at:` (Apple's own documented behavior).
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: anchor)
    }

    private func showOpenInMenu(project: T3ProjectGrouping.Project, from anchor: NSView?) {
        guard let anchor else { return }
        let menu = NSMenu()
        for entry in openInEntries {
            let target = MenuActionTarget { [self] in openIn(bundleId: entry.bundleId, cwd: project.cwd) }
            let item = NSMenuItem(title: entry.title, action: #selector(MenuActionTarget.invoke), keyEquivalent: "")
            item.target = target
            // `NSMenuItem.target` is `weak` — a local array surviving only
            // for this call's stack frame would rely on `popUp` completing
            // its action dispatch before returning, which AppKit doesn't
            // document. `representedObject` holds a strong reference for
            // exactly as long as the item (and therefore the menu) is
            // alive, removing the timing dependency entirely.
            item.representedObject = target
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: anchor)
    }

    // `OpenInPicker.tsx`'s `resolveOptions` filtered to what the brief scopes
    // B to, in `EDITORS` order — gated on `NSWorkspace` actually finding the
    // app, never a static "is this installed" guess.
    private var installedEditors: [(title: String, icon: Lucide, bundleId: String)] {
        let candidates: [(title: String, icon: Lucide, bundleId: String)] = [
            ("VS Code", .code2, "com.microsoft.VSCode"),
            ("Cursor", .code2, "com.todesktop.230313mzl4w4u92"),
            ("Terminal", .terminal, "com.apple.Terminal"),
            ("iTerm", .terminal, "com.googlecode.iterm2"),
        ]
        return candidates.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleId) != nil }
    }

    /// `usePreferredEditor` (`editorPreferences.ts:41-50`): the remembered
    /// pick when it is still available, else the first available editor, else
    /// `null`. B persists no pick yet, so this is the fallback arm only.
    private var preferredEditor: (title: String, icon: Lucide, bundleId: String)? { installedEditors.first }

    /// The chevron menu (`OpenInPicker.tsx:295-320`), plus Finder — always
    /// present, and the only entry when no editor is installed.
    private var openInEntries: [(title: String, icon: Lucide, bundleId: String?)] {
        [("Finder", .folderClosed, nil)] + installedEditors.map { ($0.title, $0.icon, Optional($0.bundleId)) }
    }

    private func openIn(bundleId: String?, cwd: String) {
        let url = URL(fileURLWithPath: cwd)
        guard let bundleId, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            NSWorkspace.shared.open(url)   // Finder
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Task 8 fix brief's own ask, re-pointed by the B-3 review: a 60-char
/// project name and a 120-char thread title at a 900 pt width, so BOTH sides
/// of the breadcrumb's sizing show — the project cluster holding at its
/// 160 pt cap (`CapToContent`, `ChatHeader.tsx:350`'s `max-w-40`) while the
/// TITLE is the member that truncates (`:352`'s `min-w-10 flex-1`, no
/// `.layoutPriority` anywhere). Standing up a real `T3TopBar` here would need
/// a live `AppModel` (engine registration, a demo-script subprocess even
/// under `playground:`), wildly disproportionate for a layout check, so this
/// reproduces the breadcrumb's exact structure and spacing directly rather
/// than going through `T3WindowModel`/`AppModel`.
#Preview("Breadcrumb truncation") {
    let projectName = "a-project-name-so-long-it-must-truncate-under-the-cap-xxxxxx"   // 60 chars
    let threadTitle = "A thread title long enough to demonstrate truncation under the layout priority differential in the breadcrumb row xxxxxx"   // 120 chars
    HStack(spacing: 12) {
        HStack(spacing: 6) {
            T3ProjectGlyph(projectName: projectName, projectCwd: "/workspace/\(projectName)", size: 14).fixedSize()
            CapToContent(maxWidth: 160) {
                Text(projectName).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(T3Font.web(.sm, .medium))
        Text("/").font(T3Font.web(.sm, .medium))
        Text(threadTitle)
            .font(T3Font.web(.sm, .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(minWidth: 40, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(20)
    .frame(width: 900)
}

/// The SwiftUI idiom for CSS's default flex-item sizing (`flex-shrink: 1,
/// flex-grow: 0`) with a `max-width` cap (`ChatHeader.tsx`'s project button,
/// `max-w-40 truncate`): report `min(ideal, maxWidth, offered)` as this
/// view's own size — hugs short content when offered more than it needs
/// (never grows to fill), caps at `maxWidth`, AND shrinks below that under
/// squeeze (a narrow `proposal`, e.g. `.layoutPriority` losing out to a
/// sibling) so a genuinely tight row still truncates instead of clipping.
/// `.fixedSize` alone hugs but never shrinks or truncates; `.frame(maxWidth:)`
/// alone is flexible and fills any offered width up to the cap regardless of
/// content — see the breadcrumb's own comment above for the measured proof
/// neither works alone. `placeSubviews` proposes the actual allotted
/// `bounds.width` (not a recomputed ideal) so the child is laid out at the
/// same width `sizeThatFits` reported, and truncates rather than overflows
/// its slot when squeezed.
///
/// Not `private`: `T3RightPanel`'s tabs are `max-w-36` with the same CSS
/// semantics and hit the same SwiftUI trap.
struct CapToContent: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews[0].sizeThatFits(.unspecified)
        let width = min(ideal.width, maxWidth, proposal.width ?? .infinity)
        let height = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: ideal.height)).height
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// R1 (fix1 brief): reports its own backing `NSView` out through `view` so a
/// sibling SwiftUI `Button`'s action closure can hand it to
/// `NSMenu.popUp(positioning:at:in:)`. Sized by `.background(MenuAnchor(...))`
/// on the trigger button, so it always matches that button's own frame.
private struct MenuAnchor: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { view = v }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// `NSMenuItem.target`/`.action` needs an `NSObject`; this is the smallest
/// closure-holding adapter (R1, fix1 brief — SwiftUI's `T3TopBar` is a
/// value type and can't itself be a menu-item target).
private final class MenuActionTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}

/// `PanelLayoutControls.tsx`/`ui/sidebar.tsx`'s toggle chrome —
/// `ui/toggle.tsx`'s `ghost` variant: transparent, `hover:bg-accent`,
/// `data-pressed:bg-accent data-pressed:text-accent-foreground` (pressed
/// reads the same as hover, so one boolean stands in for AppKit, which has
/// no `[data-pressed]`). Tooltip text carries the shortcut inline —
/// `T3Tooltip` only wraps AppKit's plain-text `.help()` (no room for a
/// `T3Kbd` chip), matching `T3SidebarView`'s "New thread ⌘N" precedent.
/// The 28 pt box is not `size="icon"` (32): `ui/sidebar.tsx:328-331` forces
/// `size-[var(--workspace-titlebar-control-size)]!` over it, and
/// `index.css:112` sets that variable to 1.75rem — hence `.sm`, whose 28 is
/// the same number.
/// Not `private`: `T3Root` also renders one, for the sidebar toggle
/// (`AppSidebarLayout.tsx`'s window-level `SidebarControl`).
struct T3TopBarToggle: View {
    @Environment(\.t3) private var t3
    @State private var hover = false
    let icon: Lucide, pressed: Bool, tooltip: String, action: () -> Void

    var body: some View {
        T3Tooltip(tooltip) {
            Button(action: action) {
                LucideIcon(icon, size: 16)
                    .foregroundStyle(active ? t3.web.accentForeground.color : t3.web.foreground.color)
            }
            .buttonStyle(.plain)
            .frame(width: T3ButtonMetrics.height(.sm), height: T3ButtonMetrics.height(.sm))
            .background(active ? t3.web.accent.color : .clear, in: RoundedRectangle(cornerRadius: T3Theme.Metrics.controlRadius))
            .onHover { hover = $0 }
        }
    }

    private var active: Bool { pressed || hover }
}
