import SwiftUI
import AppKit
import InfinitusCore
import InfinitusUI

/// The right panel's Pull request tab (`RightPanelTabs.tsx:359`'s `pr` surface
/// over `apps/web/src/components/pullRequest/`): the project's open pull
/// requests as a list, and one of them opened as a detail — its header and its
/// description through the chat's own markdown (`PullRequestMarkdown.tsx:39-52`
/// hands the body to `ChatMarkdown`, which is `T3ChatMarkdown` here).
///
/// Upstream reads these through its server, which reads them from `gh`
/// (`apps/server/src/pullRequest/GitHubPullRequestCli.ts`); this port asks `gh`
/// itself, in `InfinitusCore.T3PullRequests`. One read per project cwd, cached
/// on the window model the way the Files listing and the Diff ladder are
/// (`T3WindowModel.pullRequests(cwd:reload:)`) — the refresh control and a
/// thread switch are what ask again, nothing polls, and no timer runs while the
/// tab sits open.
///
/// Not ported this round, each with its upstream line (the Core file's header
/// lists the rest):
/// - the review threads, comments and reactions
///   (`PullRequestTimelineTab.tsx`, `PullRequestReactions.tsx`).
/// - every action: merge, ready/draft, close/reopen, update-branch,
///   auto-merge, revert, approve-workflows (`PullRequestDetailPanel.tsx:1742-1879`'s
///   menu) and the checkout command (`:2054-2070`).
/// - title and description editing (`:2004-2045`, `PullRequestMarkdownEditor.tsx`).
/// - the list's search, filters and labels (`PullRequestListFilters.tsx`,
///   `PullRequestRow.tsx:26-59`), its per-row `+N -N` stat
///   (`pullRequestPresentation.tsx:344-366`) and the file/commit/checks tabs
///   under the detail header (`PullRequestCodeTab.tsx`,
///   `PullRequestChecksPopover.tsx`).
/// - the upload cards a body's attachments get (`PullRequestMarkdown.tsx:69-90`):
///   the body goes through the markdown renderer alone.
/// - the list's `BranchMark` drawing (`PullRequestListEmptyState.tsx:29-70`),
///   which is an SVG at its own viewBox; the empty state wears the tab's own
///   glyph instead.
struct T3PullRequestPanel: View {
    @Environment(\.t3) private var t3
    @ObservedObject var model: T3WindowModel

    /// The selected thread's project. Nothing selected — or a thread whose
    /// project is gone — is "no project open", the way Files gates
    /// (`T3FilesPanel.swift:33-38`, `RightPanelTabs.tsx:339`).
    private var project: T3ProjectGrouping.Project? {
        guard let thread = model.state.selectedThread else { return nil }
        return model.state.projects.first { $0.id == thread.projectId }
    }

    var body: some View {
        Group {
            if let project {
                // A project switch is a new surface, never the old list
                // re-filtered (`ChatView.tsx:8370`'s `key`).
                T3PullRequestSurface(model: model, cwd: project.cwd)
                    .id(project.cwd)
            } else {
                T3PullRequestsTabUnavailable(hint: "Available when a project is open.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t3.web.background.color)
    }
}

/// The unavailable state. Upstream only offers this surface from its launcher,
/// where the card greys out under a one-line hint
/// (`RightPanelTabs.tsx:161-168`, rendered `:560-575` — `opacity-40`, the label
/// over `text-muted-foreground text-xs`); B's tab strip is fixed, so the tab
/// itself carries that copy, the shape Files and Diff already use.
///
/// `SURFACE_UNAVAILABLE_HINTS.pullRequest` (`:163`) is "No pull request on this
/// branch yet.", which is about a thread's own branch rather than about a
/// project — so the hint here comes from the sibling surface whose condition
/// this is (`files`, `:162` "Available when a project is open."). A project
/// that gh cannot be asked about gets the card below instead, which names the
/// fix in words.
private struct T3PullRequestsTabUnavailable: View {
    @Environment(\.t3) private var t3
    let hint: String
    var body: some View {
        VStack(spacing: 6) {   // "mt-1.5" under the label
            Text("Pull request")
                .font(T3Font.web(.sm, .medium))
                .foregroundStyle(t3.web.foreground.color)
            Text(hint)
                .font(T3Font.web(.xs))
                .foregroundStyle(t3.web.mutedForeground.color)
        }
        .opacity(0.4)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The tab's own surface: a subheader over either the list or one pull
/// request's detail.
private struct T3PullRequestSurface: View {
    @Environment(\.t3) private var t3
    @ObservedObject var model: T3WindowModel
    let cwd: String

    @State private var load = T3WindowModel.PullRequestLoad()
    @State private var pending = true
    /// False until this project's list has been read from gh once.
    @State private var read = false
    /// The opened pull request, `null` while the list is the surface.
    @State private var selected: T3PullRequests.Entry?

    /// The list as it is shown: the checked-out branch's pull request first,
    /// then the rest in gh's own order. Ours — upstream's list spans the whole
    /// workspace and has no branch to pin — and the reason the tab is worth
    /// opening from a thread at all.
    private var rows: [T3PullRequests.Entry] {
        guard let current = load.current else { return load.entries }
        return [current] + load.entries.filter { $0.number != current.number }
    }

    var body: some View {
        Group {
            if load.unavailable, let failure = load.failure {
                T3PullRequestsTabUnavailable(hint: failure)
            } else {
                VStack(spacing: 0) {
                    header
                    content
                }
            }
        }
        .task {
            if let cached = model.cachedPullRequests(cwd: cwd) { load = cached }
            // The project's first look re-reads gh behind the cached list; the
            // surface is re-identified per cwd, so `read` is false again after
            // a project switch (`T3DiffPanel.swift:228-234`).
            await reload(force: !read)
            read = true
        }
    }

    // MARK: - The subheader

    /// The shape the sibling panels' subheaders share
    /// (`DiffPanelShell.tsx:10-19`: "flex items-center justify-between gap-2
    /// px-2" over "h-10 min-h-10 shrink-0 border-b border-border/60
    /// bg-background").
    private var header: some View {
        HStack(spacing: 8) {
            if selected != nil {
                backButton
            } else {
                // The count only once there is one: a read still in flight
                // has no number to report, and "0" would be an answer.
                Text(rows.isEmpty ? "Pull requests" : countLabel)
                    .font(T3Font.web(.xs, .medium))
                    .foregroundStyle(t3.web.mutedForeground.color)
            }
            Spacer(minLength: 0)
            T3FilesIconButton(help: pending ? "Refreshing pull requests…" : "Refresh pull requests") {
                Task { await reload(force: true) }
            } content: {
                if pending { T3Spinner(size: 14) } else { LucideIcon(.refreshCw, size: 14) }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(t3.web.background.color)
        .overlay(alignment: .bottom) {
            Rectangle().fill(t3.web.border.color.opacity(0.6)).frame(height: 1)
        }
    }

    private var countLabel: String {
        rows.count == 1 ? "1 open pull request" : "\(rows.count) open pull requests"
    }

    private var backButton: some View {
        Button { selected = nil } label: {
            HStack(spacing: 4) {
                LucideIcon(.chevronLeft, size: 14)
                Text("Pull requests").font(T3Font.web(.xs, .medium))
            }
            .foregroundStyle(t3.web.mutedForeground.color)
            .padding(.horizontal, 4)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Back to the list")
    }

    // MARK: - The body

    @ViewBuilder private var content: some View {
        if let selected {
            T3PullRequestDetailView(model: model, cwd: cwd, entry: selected)
                .id(selected.number)
        } else if let failure = load.failure {
            T3PullRequestsErrorCard(error: failure, refreshing: pending) {
                Task { await reload(force: true) }
            }
        } else if rows.isEmpty {
            if pending {
                // The first read of a project, with nothing cached to paint.
                T3PullRequestsGhost()
            } else {
                T3PullRequestsEmpty(refreshing: pending) { Task { await reload(force: true) } }
            }
        } else {
            list
        }
    }

    /// "flex flex-col gap-0.5 px-2 py-2" over the scroller upstream gives the
    /// rows (`PullRequestListPanel`'s body, `pullRequestList.logic.ts`'s
    /// consumer in `PullRequestsRoute`).
    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(rows, id: \.number) { entry in
                    T3PullRequestRowView(entry: entry,
                                         isCurrentBranch: entry.number == load.current?.number,
                                         now: model.now) { selected = entry }
                }
            }
            .padding(8)
        }
    }

    private func reload(force: Bool) async {
        pending = true
        load = await model.pullRequests(cwd: cwd, reload: force)
        // A row the refresh dropped must not stay open behind the detail.
        if let open = selected {
            selected = rows.first { $0.number == open.number } ?? open
        }
        pending = false
    }
}

// MARK: - One row

/// `PullRequestRow.tsx:63-200`: the state glyph, the title, the verdict and
/// checks on the right, the `#number · author` meta line under it and the
/// relative time at the end. The labels, the provider glyph, the search
/// "matched elsewhere" pill and the diff stat are the parts this round leaves
/// out (see the panel's header).
private struct T3PullRequestRowView: View {
    @Environment(\.t3) private var t3
    @State private var hover = false
    let entry: T3PullRequests.Entry
    /// The checked-out branch's own pull request, which this list pins first.
    let isCurrentBranch: Bool
    let now: Date
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // "grid w-full grid-cols-[auto_minmax(0,1fr)] items-center gap-3
            // rounded-lg px-3 py-3 text-left" (`:98-109`).
            HStack(alignment: .center, spacing: 12) {
                T3PullRequestStateGlyph(state: entry.state, isDraft: entry.isDraft, size: 16)
                VStack(alignment: .leading, spacing: 6) {   // "gap-y-1.5"
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(entry.title)
                            .font(T3Font.web(.sm, .medium))
                            .foregroundStyle(t3.web.foreground.color)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        verdict
                        if let state = entry.checksState {
                            T3PullRequestChecksGlyph(state: state)
                        }
                    }
                    HStack(spacing: 6) {
                        metaLine
                        Spacer(minLength: 0)
                        // "text-[11px] text-muted-foreground/70 tabular-nums" (`:186-192`).
                        Text(T3RelativeTime.agoLabel(from: entry.updatedAt, now: now))
                            .font(T3Font.webLiteral(11))
                            .foregroundStyle(t3.web.mutedForeground.color.opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover ? t3.web.accent.color.opacity(0.6) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    /// `PullRequestMetaLine` (`pullRequestPresentation.tsx:379-404`): dot
    /// separators only between the segments that survive.
    private var metaLine: some View {
        HStack(spacing: 6) {
            Text("#\(entry.number)")
            separator
            Text(entry.author?.login ?? "ghost")   // GitHub's own word for a deleted account
                .lineLimit(1)
                .truncationMode(.tail)
            if isCurrentBranch {
                separator
                Text("this branch")
            }
        }
        .font(T3Font.web(.xs))
        .foregroundStyle(t3.web.mutedForeground.color.opacity(0.7))
    }

    private var separator: some View {
        Text("·").foregroundStyle(t3.web.mutedForeground.color.opacity(0.5))
    }

    /// Only a verdict somebody has actually given: "review required" is the
    /// absence of one (`PullRequestRow.tsx:119-135`).
    @ViewBuilder private var verdict: some View {
        switch entry.reviewDecision {
        case .approved:
            Text("Approved")
                .font(T3Font.web(.xs))
                .foregroundStyle(T3PullRequestTone.approved.color(t3.scheme))
                .lineLimit(1)
        case .changesRequested:
            Text("Changes requested")
                .font(T3Font.web(.xs))
                .foregroundStyle(T3PullRequestTone.changesRequested.color(t3.scheme))
                .lineLimit(1)
        case .reviewRequired, nil:
            EmptyView()
        }
    }
}

// MARK: - The detail

/// `PullRequestDetailPanel.tsx:2029-2179`'s header, and the body under it. The
/// number is the "open on host" affordance upstream makes it
/// (`:1376-1394`: the number in the state's own tone with a `size-2.5`
/// external-link glyph, tooltip `openOnHostLabel` — "Open on GitHub").
private struct T3PullRequestDetailView: View {
    @Environment(\.t3) private var t3
    @ObservedObject var model: T3WindowModel
    let cwd: String
    let entry: T3PullRequests.Entry

    @State private var body_: Result<String, T3PullRequests.LoadError>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().overlay(t3.web.border.color.opacity(0.6))
                    .padding(.vertical, 12)
                description
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            if let cached = model.cachedPullRequestBody(cwd: cwd, number: entry.number) {
                body_ = cached
                return
            }
            body_ = await model.pullRequestBody(cwd: cwd, number: entry.number)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            // "text-base font-semibold leading-snug" (`:1987-1990`).
            Text(entry.title)
                .font(T3Font.web(.base, .semibold))
                .foregroundStyle(t3.web.foreground.color)
                .fixedSize(horizontal: false, vertical: true)
            // "mt-2 flex items-center gap-2 text-xs text-muted-foreground"
            // (`:2047-2053`): the author, then when it last moved.
            HStack(spacing: 6) {
                number
                Text("·").foregroundStyle(t3.web.mutedForeground.color.opacity(0.5))
                Text(entry.author?.login ?? "ghost").font(T3Font.web(.xs, .medium))
                Text("·").foregroundStyle(t3.web.mutedForeground.color.opacity(0.5))
                Text("updated \(T3RelativeTime.agoLabel(from: entry.updatedAt, now: model.now))")
                    .font(T3Font.web(.xs))
            }
            .foregroundStyle(t3.web.mutedForeground.color)
            // "mt-4 … font-mono text-xs text-muted-foreground/70" (`:2074-2118`):
            // the base branch, an arrow that reads "receives changes from",
            // and the head branch.
            HStack(spacing: 6) {
                Text(entry.baseBranch).lineLimit(1).truncationMode(.middle)
                LucideIcon(.arrowLeft, size: 14).opacity(0.6)
                Text(entry.headBranch).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: T3TypeScale.Web.xs.step.size, design: .monospaced))
            .foregroundStyle(t3.web.mutedForeground.color.opacity(0.7))
            .padding(.top, 8)
            checks
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The state's glyph and label beside the number, which carries the link.
    private var number: some View {
        Button {
            guard let url = URL(string: entry.url) else { return }
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 4) {
                T3PullRequestStateGlyph(state: entry.state, isDraft: entry.isDraft, size: 14)
                Text("#\(entry.number)").font(T3Font.web(.xs, .medium))
                LucideIcon(.externalLink, size: 10)
            }
            .foregroundStyle(T3PullRequestTone.state(entry.state, isDraft: entry.isDraft)
                .color(t3.scheme))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open on GitHub")
        .accessibilityLabel("Open pull request #\(entry.number) on host")
    }

    /// `summarizePullRequestChecks` under the rollup's own glyph
    /// (`pullRequestPresentation.tsx:421-446`, `PullRequestDetailPanel.tsx:1359`).
    @ViewBuilder private var checks: some View {
        if let state = entry.checksState {
            HStack(spacing: 6) {
                T3PullRequestChecksGlyph(state: state)
                Text(T3PullRequests.summarize(checks: entry.checks))
                    .font(T3Font.web(.xs))
                    .foregroundStyle(t3.web.mutedForeground.color)
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder private var description: some View {
        switch body_ {
        case .none:
            HStack(spacing: 8) {
                T3Spinner(size: 14)
                Text("Loading description…")
                    .font(T3Font.web(.xs))
                    .foregroundStyle(t3.web.mutedForeground.color)
            }
        case .success(let text) where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            // "No description provided." (`PullRequestSummaryTab.tsx`'s empty body).
            Text("No description provided.")
                .font(T3Font.web(.sm))
                .foregroundStyle(t3.web.mutedForeground.color.opacity(0.7))
        case .success(let text):
            T3ChatMarkdown(text: text)
        case .failure(let error):
            // `PullRequestActivityUnavailableState` in words
            // (`PullRequestActivityUnavailableState.tsx:24-26`).
            VStack(alignment: .leading, spacing: 4) {
                Text("Could not load pull request activity")
                    .font(T3Font.web(.sm, .medium))
                    .foregroundStyle(t3.web.foreground.color)
                Text(error.message)
                    .font(T3Font.web(.xs))
                    .foregroundStyle(t3.web.mutedForeground.color)
            }
        }
    }
}

// MARK: - The states with nothing to show

/// `PullRequestsUnavailableState.tsx:28-64`: the tab's glyph over "Could not
/// load pull requests" and the message the caller was given — the one that
/// names the fix — with a Retry beneath it. Upstream's second button opens the
/// repository on GitHub; a failed read here has no url to open, so it is left
/// out rather than pointed at a guess.
private struct T3PullRequestsErrorCard: View {
    @Environment(\.t3) private var t3
    let error: String
    let refreshing: Bool
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            LucideIcon(.gitPullRequest, size: 20)
                .foregroundStyle(t3.web.mutedForeground.color)
            VStack(spacing: 4) {
                Text("Could not load pull requests")
                    .font(T3Font.web(.sm, .medium))
                    .foregroundStyle(t3.web.foreground.color)
                Text(error)
                    .font(T3Font.web(.xs))
                    .foregroundStyle(t3.web.mutedForeground.color)
            }
            T3Button("Retry", variant: .outline, size: .sm, icon: .refreshCw, action: retry)
                .disabled(refreshing)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .padding(.vertical, 64)          // "px-4 py-16"
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// `PullRequestListEmptyState.tsx:150-176`'s last branch, with no filters and
/// no search to clear. Its description names the workspace upstream's list
/// spans; this list is one project's repository, so it says that instead.
private struct T3PullRequestsEmpty: View {
    @Environment(\.t3) private var t3
    let refreshing: Bool
    let refresh: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            LucideIcon(.gitPullRequest, size: 20)
                .foregroundStyle(t3.web.mutedForeground.color.opacity(0.6))
            VStack(spacing: 4) {
                Text("No pull requests")
                    .font(T3Font.web(.sm, .medium))
                    .foregroundStyle(t3.web.foreground.color)
                Text("Pull requests from this project's repository appear here.")
                    .font(T3Font.web(.xs))
                    .foregroundStyle(t3.web.mutedForeground.color)
            }
            T3Button(refreshing ? "Checking..." : "Check again", variant: .outline, size: .sm,
                     icon: .refreshCw, action: refresh)
                .disabled(refreshing)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .padding(.vertical, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// `PullRequestListGhost` (`PullRequestGhosts.tsx`): the rows' own shape while
/// the first read is in flight, rather than a spinner in an empty panel.
private struct T3PullRequestsGhost: View {
    @Environment(\.t3) private var t3
    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { _ in
                HStack(alignment: .center, spacing: 12) {
                    bar(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 6) {
                        bar(width: 220, height: 12)
                        bar(width: 120, height: 10)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
    }

    private func bar(width: Double, height: Double) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(t3.web.accent.color.opacity(0.6))
            .frame(width: width, height: height)
    }
}

// MARK: - Tones and glyphs

/// `resolvePullRequestState` and `CHECK*_PRESENTATION`'s ink
/// (`pullRequestPresentation.tsx:41-83`, `:118-181`), read from the generated
/// tailwindcss stops — the light `-600`/`-500` and the dark `-300`/`-400` of
/// each pair, never hand-typed.
enum T3PullRequestTone {
    case open, merged, closed, draft, approved, changesRequested, failing, pending

    static func state(_ state: T3PullRequests.State, isDraft: Bool) -> T3PullRequestTone {
        switch state {
        case .merged: return .merged
        case .closed: return .closed
        case .open: return isDraft ? .draft : .open
        }
    }

    func color(_ scheme: ColorScheme) -> Color {
        let dark = scheme == .dark
        switch self {
        case .open, .approved: return (dark ? T3Tailwind.emerald300 : T3Tailwind.emerald600).color
        // "text-violet-600 dark:text-violet-300/90":
        case .merged: return (dark ? T3Tailwind.violet300 : T3Tailwind.violet600).color
        case .closed, .failing: return (dark ? T3Tailwind.red300 : T3Tailwind.red600).color
        case .changesRequested, .pending: return (dark ? T3Tailwind.amber400 : T3Tailwind.amber600).color
        // "text-zinc-500 dark:text-zinc-400/80":
        case .draft: return (dark ? T3Tailwind.zinc400 : T3Tailwind.zinc500).color
        }
    }
}

/// `PullRequestStateGlyph` (`pullRequestPresentation.tsx:86-117`) without the
/// conflict case: `gh pr list` reports no mergeability, so a row here never
/// claims a branch collides with its base.
private struct T3PullRequestStateGlyph: View {
    @Environment(\.t3) private var t3
    let state: T3PullRequests.State
    let isDraft: Bool
    let size: Double

    var body: some View {
        LucideIcon(glyph, size: size)
            .foregroundStyle(tint)
            .help(T3PullRequests.stateLabel(state: state, isDraft: isDraft))
            .accessibilityLabel(T3PullRequests.stateLabel(state: state, isDraft: isDraft))
    }

    private var glyph: Lucide {
        switch state {
        case .merged: return .gitMerge
        case .closed: return .gitPullRequestClosed
        case .open: return isDraft ? .gitPullRequestDraft : .gitPullRequest
        }
    }

    private var tint: Color {
        T3PullRequestTone.state(state, isDraft: isDraft)
            .color(t3.scheme)
    }
}

/// The rollup a row wears (`CHECKS_STATE_PRESENTATION`,
/// `pullRequestPresentation.tsx:165-181`): one glyph, GitHub's own wording on
/// the hover.
private struct T3PullRequestChecksGlyph: View {
    @Environment(\.t3) private var t3
    let state: T3PullRequests.ChecksState

    var body: some View {
        LucideIcon(glyph, size: 14)
            .foregroundStyle(tone.color(t3.scheme))
            .help(T3PullRequests.checksStateLabel(state))
            .accessibilityLabel(T3PullRequests.checksStateLabel(state))
    }

    private var glyph: Lucide {
        switch state {
        case .passing: return .circleCheck
        case .failing: return .xCircle      // lucide's `circle-x`, via its own alias
        case .pending: return .circleDot
        }
    }

    private var tone: T3PullRequestTone {
        switch state {
        case .passing: return .open
        case .failing: return .failing
        case .pending: return .pending
        }
    }
}
