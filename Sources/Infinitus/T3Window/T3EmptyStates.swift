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
/// state before any project exists. `action` is `nil` until Task 15 wires
/// `model.startNewThread(projectId: nil)` — the button stays disabled.
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
