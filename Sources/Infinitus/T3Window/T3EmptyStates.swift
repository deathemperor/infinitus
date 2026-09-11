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
                .font(T3Font.web(.xl, .semibold))
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
                .font(T3Font.webLiteral(30, .semibold))
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

/// T3's `<DraftHeroHeadline>` (`DraftHeroHeadline.tsx:204-214`): the one `h1`
/// over an empty draft, whose project name is itself the project picker
/// (`:111-193`). Upstream's three forms, verbatim from that ternary:
/// "What should we build in {project}?" once a project is resolved,
/// "{picker} to start" when one can be chosen, and "Add a project to start"
/// when there is none.
///
/// There is **no rotating headline list** upstream — the headline is a function
/// of the draft's project, which is why it needs no `draftId` hash to stay
/// stable across captures.
///
/// Not ported: the menu's "New project" item (`:194-197` opens the command
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
                // `:168-183`: the group's own favicon, `size-4 shrink-0`,
                // before a `gap-2` and the name. The item's picture is a
                // `Label`'s icon, which AppKit draws as the menu item's image
                // — its gap to the title, and upstream's `min-w-0 truncate`
                // on the name, are AppKit's own and have no knob here.
                Button { onPick(group) } label: {
                    Label {
                        Text(group.displayName)
                    } icon: {
                        // `<ProjectFavicon project={group}>` classifies over
                        // the group's representative, the same member
                        // `T3ThreadView` retargets a draft into.
                        if let glyph = T3ProjectMenuGlyph.image(name: group.representative.name,
                                                                cwd: group.representative.cwd, t3: t3) {
                            Image(nsImage: glyph).renderingMode(.original)
                        }
                    }
                }
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

/// `T3ProjectGlyph` in the form a menu item can hold: SwiftUI hands a `Label`'s
/// icon to AppKit as an `NSImage`, and the kit's Lucide glyph is a stroked
/// `Shape`, which an `NSMenuItem` cannot host — so it is rasterised once.
///
/// Cached on what the picture actually depends on, the selected icon and the
/// scheme, never on the project: `selectProjectIcon` maps every name onto one
/// of 22 glyphs, so the cache tops out at 44 images and re-rendering the
/// headline draws none of them again.
@MainActor
enum T3ProjectMenuGlyph {
    private static var cache: [String: NSImage] = [:]

    static func image(name: String, cwd: String, t3: T3Environment, size: Double = 16) -> NSImage? {
        let key = "\(T3ProjectIcon.select(name: name, cwd: cwd).rawValue)\u{0}\(t3.scheme)\u{0}\(size)"
        if let hit = cache[key] { return hit }
        let renderer = ImageRenderer(content: T3ProjectGlyph(projectName: name, projectCwd: cwd, size: size)
            .frame(width: size, height: size)
            .environment(\.t3, t3))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }
        // Never a template: the automatic icon's whole point is its colour
        // (`PROJECT_ICON_COLOR_BY_NAME`), which a template image would drop.
        image.isTemplate = false
        cache[key] = image
        return image
    }
}
