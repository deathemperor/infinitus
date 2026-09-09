import SwiftUI
import InfinitusCore
import InfinitusUI

/// The composer's context strip (`ChatView.tsx:8168-8180` renders
/// `<BranchToolbar>` in a `relative z-0` / `pointer-events-auto` wrapper
/// directly under the composer card): the workspace on the left, the checked
/// out branch on the right.
///
/// `ComposerSurface.ContextStrip` (`chat/ComposerSurface.tsx:82-97`) is the
/// shell — `mx-auto -mt-4 w-[calc(100%-2*var(--chat-composer-drawer-inset))]`
/// (1.375 rem = 22 a side) `items-center gap-2 ps-1 pe-2 pt-5 pb-1`, over a
/// `before` outline rounded 16 at the bottom whose top 1 rem is masked away
/// (it runs up behind the card). `BranchToolbar.tsx:540-560` fills it at
/// `gap-1 text-xs font-normal text-muted-foreground/70`.
///
/// The two controls are the LOCKED forms this window can honour today:
/// `BranchToolbarEnvModeSelector`'s `envLocked` span
/// (`:52-75` — `FolderIcon size-3` + `resolveLockedWorkspaceLabel`, no
/// chevron) and `BranchToolbarBranchSelector`'s ghost `xs` trigger
/// (`:775-793` — `GitBranchIcon size-3 opacity-70`, the branch,
/// `ChevronDownIcon size-3 opacity-50`). Neither opens anything yet: this
/// window has no worktree mode and no branch switching, and a trigger that
/// silently did nothing would be worse than one that says so, so both carry
/// the tooltip instead.
struct T3BranchLine: View {
    /// The thread's project folder. The line only exists with one.
    let cwd: String
    /// Re-asks git when it changes — the thread switch, not a timer.
    let threadId: String
    let model: T3WindowModel
    @Environment(\.t3) private var t3
    @State private var branch: String?

    private static let drawerInset: Double = 1.375 * 16
    private static let pending = "Checkout and branch switching arrive with the git panel"

    var body: some View {
        HStack(spacing: 8) {
            control(icon: .folder, label: T3GitFacts.workspaceLabel(worktreePath: nil),
                    iconOpacity: 1, chevron: false)
            Spacer(minLength: 0)
            if let branch {
                control(icon: .gitBranch, label: branch, iconOpacity: 0.7, chevron: true)
            }
        }
        .padding(.leading, 4)      // `ps-1`
        .padding(.trailing, 8)     // `pe-2`
        .padding(.top, 4)          // `pt-5` less the `-mt-4` that tucks it under the card
        .padding(.bottom, 4)       // `pb-1`
        .background {
            // The `before` outline, minus the 1 rem the mask removes: the
            // sides and the 16-radius bottom, in `dark:before:border-white/7`.
            // Outline only: the dark `before` background (`:89`) is a 1 % white
            // wash the reference paints under a narrower strip, and filling
            // ours — which the window's own scale makes wider — measured
            // further from the reference than leaving it, so it stays off.
            UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16,
                                   style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
                .padding(.top, -16)
        }
        // `-mt-4` (`ComposerSurface.tsx:87`) tucks the strip back under the
        // card's own bottom margin — `T3ComposerView`'s `.padding(.bottom, 16)`
        // — so `pt-5` leaves the 4 upstream shows between the two. The 20
        // below is what the reference window keeps under the strip; upstream
        // gets it from a container this port has no counterpart for, so it is
        // set to the measured inset.
        .padding(.top, -16)
        .padding(.bottom, 20)
        .padding(.horizontal, Self.drawerInset)
        .task(id: threadId) {
            branch = model.cachedBranch(cwd: cwd)
            branch = await model.gitBranch(cwd: cwd, reload: true)
        }
    }

    private func control(icon: Lucide, label: String, iconOpacity: Double, chevron: Bool) -> some View {
        // `h-7 sm:h-6` with `gap-1`, `border border-transparent` and
        // `px-[calc(--spacing(2)-1px)]` (7).
        HStack(spacing: 4) {
            LucideIcon(icon, size: 12).opacity(iconOpacity)
            Text(label)
                .font(T3Font.web(.xs))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 240, alignment: .leading)
                .fixedSize()
            if chevron { LucideIcon(.chevronDown, size: 12).opacity(0.5) }
        }
        .foregroundStyle(t3.web.mutedForeground.color.opacity(0.7))
        .padding(.horizontal, 7)
        .frame(height: 24)
        .help(Self.pending)
    }
}
