import SwiftUI
import InfinitusCore
import InfinitusUI

/// The web/desktop look of T3's `<Empty>` primitives (`ui/empty.tsx`):
/// `EmptyTitle` `xl` semibold over `EmptyDescription` `sm` muted. The kit's
/// `T3EmptyState` is the phone's component (`T3TypeScale.Mobile`, the
/// mobile palette) so the workspace window gets its own copy here.
struct T3WebEmpty: View {
    @Environment(\.t3) private var t3
    let title: String
    let message: String

    var body: some View {
        // `mt-2` between title and description (`NoProjectsHero.tsx:21`,
        // `NoActiveThreadState.tsx:26`).
        VStack(spacing: 8) {
            Text(title)
                .font(T3Font.web(.xl, .bold))
                .foregroundStyle(t3.web.foreground.color)
            if !message.isEmpty {
                Text(message)
                    .font(T3Font.web(.sm))
                    .foregroundStyle(t3.web.mutedForeground.color.opacity(0.78))
            }
        }
        .multilineTextAlignment(.center)
        // `px-8` on the wrapper div (`NoProjectsHero.tsx:16`,
        // `NoActiveThreadState.tsx:23`).
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// T3's `<NoProjectsHero>` (`NoProjectsHero.tsx`): the workspace's empty
/// state before any project exists. `action` stays `nil`: upstream's button
/// opens the command palette's add-project flow (`openCommandPalette({ open:
/// "add-project" })`), which B has no host for, and a new thread needs a
/// project to start in anyway (`T3WindowModel.startNewThread` guards on one).
struct T3NoProjectsHero: View {
    @Environment(\.t3) private var t3
    let action: (() -> Void)?

    var body: some View {
        // `mt-2` between title and description (`NoProjectsHero.tsx:21`).
        VStack(spacing: 8) {
            // `NoProjectsHero.tsx` "text-2xl sm:text-3xl" — the kit renders
            // the `sm:` breakpoint (T3ButtonMetrics' own rule); `xxl` in
            // `T3TypeScale.Web` tops out at 24, short of the 30 the `sm:`
            // class needs, so this is `webLiteral`.
            Text("What should we work on?")
                .font(T3Font.webLiteral(30, .bold))
                .foregroundStyle(t3.web.foreground.color)
            Text("Add a project to start your first thread.")
                .font(T3Font.web(.sm))
                .foregroundStyle(t3.web.mutedForeground.color.opacity(0.78))
            // "mt-6" (24) on the button wrapper, minus the stack's own 8.
            T3Button("Add project", size: .sm, icon: .plus) { action?() }
                .disabled(action == nil)
                .padding(.top, 16)
        }
        .multilineTextAlignment(.center)
        // `px-8` on the wrapper div (`NoProjectsHero.tsx:16`).
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// T3's `<NoActiveThreadState>` (`NoActiveThreadState.tsx`): shown once a
/// project exists but no thread is selected. Upstream's "No active thread"
/// text sits inside its own `WorkspacePageHeader` (a full `topbarHeight`
/// band with `border-b`) — `T3Root`'s top bar (`T3TopBar`, Task 8) renders
/// that band unconditionally now, so this view is only the `<Empty>` body
/// below it.
struct T3NoActiveThreadState: View {
    var body: some View {
        T3WebEmpty(
            title: "Pick a thread to continue",
            message: "Select an existing thread or create a new one to get started.")
    }
}

/// T3's `<DraftHeroHeadline>` (`DraftHeroHeadline.tsx:197-207`): the one `h1`
/// over an empty draft, whose project name is itself the project picker
/// (`:110-186`). Upstream's three forms, verbatim from that ternary:
/// "What should we build in {project}?" once a project is resolved,
/// "{picker} to start" when one can be chosen, and "Add a project to start"
/// when there is none.
///
/// There is **no rotating headline list** upstream — the headline is a function
/// of the draft's project, which is why it needs no `draftId` hash to stay
/// stable across captures.
///
/// Not ported: the menu's "New project" item (`:181-184` opens the command
/// palette's add-project flow, which B has no host for) and the tooltip over a
/// truncated name.
struct T3DraftHeroHeadline: View {
    @Environment(\.t3) private var t3
    /// The draft's project as the sidebar's grouping names it, nil when the
    /// draft has no resolvable project.
    let projectName: String?
    /// What the picker can move the draft to — the same logical groups the
    /// sidebar's scope row lists (`buildSidebarProjectPickerEntries` upstream).
    let groups: [T3ProjectGrouping.Group]
    let onPick: (T3ProjectGrouping.Group) -> Void

    var body: some View {
        // `h1 … text-2xl sm:text-3xl` — the Mac renders the `sm:` half, 30,
        // `font-normal` with `tracking-tight` (−0.025em = −0.75 at 30).
        // `max-w-5xl mx-auto text-center` (`:198`).
        HStack(spacing: 0) {
            if projectName != nil {
                text("What should we build in ")
                picker
                text("?")
            } else if !groups.isEmpty {
                picker
                text(" to start")
            } else {
                text("Add a project to start")
            }
        }
        .frame(maxWidth: 1024)
        .frame(maxWidth: .infinity)
    }

    private func text(_ value: String) -> some View {
        Text(value)
            .font(T3Font.webLiteral(30))
            .tracking(-0.75)
            .foregroundStyle(t3.web.foreground.color)
    }

    /// `:110-127`'s trigger: the name under a dotted `border-b`, `text-foreground`
    /// while a project is resolved, `muted-foreground/60` while it is the
    /// "choose one" prompt (`:191`), truncated at `max-w-64` (256).
    private var picker: some View {
        Menu {
            ForEach(groups) { group in
                Button(group.displayName) { onPick(group) }
            }
        } label: {
            Text(projectName ?? "Choose a project")
                .font(T3Font.webLiteral(30))
                .tracking(-0.75)
                .underline(true, pattern: .dot)
                .foregroundStyle(projectName == nil
                                 ? t3.web.mutedForeground.color.opacity(0.6)
                                 : t3.web.foreground.color)
                .lineLimit(1)
                .frame(maxWidth: 256)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(groups.isEmpty)
        .accessibilityLabel(projectName == nil ? "Choose a project" : "Change project")
    }
}
