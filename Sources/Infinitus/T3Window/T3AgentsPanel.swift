import SwiftUI
import InfinitusCore
import InfinitusUI

/// The right panel's Agents tab (`AgentsPanel.tsx` at the pinned sha
/// 6c583620f, tab `RightPanelTabs.tsx:364-373`): the thread's sub-agent fleet,
/// and the only place the roster renders. The model is `T3Agents.Panel`, derived
/// on the feed's own thread (`T3TimelineStore.agents`).
///
/// Upstream's three visualization rules hold: spawn order is stable, activity
/// and completion update rows in place, and a row reserves three fixed lines
/// (`h-[3.875rem]` over `1.25rem / 1.125rem / 1rem`) so changing data never
/// changes its height.
///
/// Not ported, each with its upstream line:
/// - `AgentElapsed`'s `setInterval(1000)` (`:92-104`). A running row's elapsed
///   is measured to `panel.derivedAt` and moves only when the feed pumps —
///   #18's rule: no TimelineView, no repeatForever, no Timer. Opening the tab
///   asks for one fresh read (`T3TimelineStore.refreshAgents`), because a
///   sub-agent's own writes never move the parent transcript's stamp.
/// - `PhaseRail` (`:215-265`) and `PhaseSection` (`:319-376`): a real workflow
///   run directory carries no phase data (see `T3Agents`), so every member is
///   an `unphasedMembers` row.
/// - `WorkflowScriptView` (`:267-312`) and the `{} script` button (`:408-420`):
///   they need `runHandles.scriptPath` off the orchestration RPC, which nothing
///   on disk carries.
/// - the footer's "N idle" (`:578`) and a row's `run N` metadata segment
///   (`:155`): `idle` and `activationCount` are not knowable from a transcript.
struct T3AgentsPanel: View {
    @Environment(\.t3) private var t3
    @ObservedObject var model: T3WindowModel

    var body: some View {
        Group {
            if let store = model.timelineStore {
                T3AgentsSurface(store: store)
            } else {
                T3AgentsUnavailable()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t3.web.background.color)
    }
}

/// The unavailable state. Upstream only offers Agents from its surface
/// launcher, where the card greys out with its hint (`RightPanelTabs.tsx:164`,
/// rendered `:560-575` — `opacity-40`, the label over `text-muted-foreground
/// text-xs`) and carries the longer reason as its title
/// (`SURFACE_DISABLED_REASONS.agents`, `:142`); B's tab strip is fixed, so the
/// tab itself carries both.
private struct T3AgentsUnavailable: View {
    @Environment(\.t3) private var t3
    var body: some View {
        VStack(spacing: 6) {   // "mt-1.5" under the label
            Text("Agents")
                .font(T3Font.web(.sm, .medium))
                .foregroundStyle(t3.web.foreground.color)
            Text("Available from a thread.")
                .font(T3Font.web(.xs))
                .foregroundStyle(t3.web.mutedForeground.color)
        }
        .opacity(0.4)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help("Agents are only available from a thread.")
    }
}

/// `AgentsPanel` itself (`:525-585`): the empty state, or the scroller over the
/// workflow sections and the direct spawns with the counts footer under it.
private struct T3AgentsSurface: View {
    @Environment(\.t3) private var t3
    @ObservedObject var store: T3TimelineStore
    /// A workflow's expansion is presentation state, not a status derivative
    /// (`WorkflowSection`, `:502-523`): seeded once per run from whether it was
    /// live when first seen, so a run that settles keeps the shape it had.
    @State private var open: [String: Bool] = [:]

    var body: some View {
        Group {
            if store.agents.hasAgents { list } else { empty }
        }
        .onAppear {
            seed()
            store.refreshAgents()
        }
        .onChange(of: store.agents.workflows.map(\.id)) { _, _ in seed() }
    }

    private func seed() {
        for workflow in store.agents.workflows where open[workflow.id] == nil {
            open[workflow.id] = workflow.isLive
        }
    }

    // "flex h-full flex-col items-center justify-center gap-2 p-6 text-center"
    private var empty: some View {
        VStack(spacing: 8) {
            LucideIcon(.bot, size: 24)
                .foregroundStyle(t3.web.mutedForeground.color.opacity(0.6))
            Text("No agents yet")
                .font(T3Font.web(.sm, .medium))
                .foregroundStyle(t3.web.foreground.color)
            Text("When this thread spawns subagents or runs a workflow, they show up here with live status, activity, and token usage.")
                .font(T3Font.web(.xs))
                .foregroundStyle(t3.web.mutedForeground.color)
                .frame(maxWidth: 224)   // "max-w-56"
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        VStack(spacing: 0) {
            ScrollView {
                // "flex flex-col gap-2 p-2"
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.agents.workflows) { workflow in
                        T3AgentsWorkflowSection(
                            workflow: workflow, panel: store.agents,
                            open: open[workflow.id] ?? workflow.isLive,
                            setOpen: { open[workflow.id] = $0 })
                    }
                    if !store.agents.directAgents.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            // "px-1.5 pt-1 text-[.65rem] font-medium uppercase
                            // tracking-wider text-muted-foreground"
                            Text("DIRECT SPAWNS")
                                .font(T3Font.webLiteral(10.4, .medium))
                                .tracking(0.5)
                                .foregroundStyle(t3.web.mutedForeground.color)
                                .padding(.horizontal, 6)
                                .padding(.top, 4)
                            ForEach(store.agents.directAgents) { agent in
                                T3AgentRow(agent: agent, panel: store.agents)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            footer
        }
    }

    /// "border-t border-border/60 px-3 py-1.5 font-mono text-[.7rem]
    /// text-muted-foreground" (`:571-582`).
    private var footer: some View {
        HStack(spacing: 8) {
            if store.agents.liveCount > 0 {
                Text("● \(store.agents.liveCount) working")
                    .foregroundStyle(t3.web.infoForeground.color)
            }
            if store.agents.settledCount > 0 {
                Text("\(store.agents.settledCount) settled")
            }
            Spacer(minLength: 8)
            Text("Σ \(T3Agents.tokenCount(store.agents.totalTokens)) tok")
                .monospacedDigit()
        }
        .font(T3Font.webLiteral(11.2).monospaced())
        .foregroundStyle(t3.web.mutedForeground.color)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            t3.web.border.color.opacity(0.6).frame(height: 1)
        }
    }
}

/// One workflow run: expanded (`ExpandedWorkflowSection`, `:379-453`) or
/// collapsed to a summary line (`CollapsedWorkflowSection`, `:459-500`).
private struct T3AgentsWorkflowSection: View {
    @Environment(\.t3) private var t3
    let workflow: T3Agents.Workflow
    let panel: T3Agents.Panel
    let open: Bool
    let setOpen: (Bool) -> Void
    @State private var hover = false

    var body: some View {
        if open { expanded } else { collapsed }
    }

    /// The run's own dot: a failed member colours the whole run (`:486`); with
    /// no coordinator agent, live-or-settled comes from the members.
    private var status: T3Agents.Status {
        if workflow.failedCount > 0 { return .failed }
        return workflow.isLive ? .running : .completed
    }

    // "rounded-lg border border-border/50 bg-card/30 p-1.5"
    private var expanded: some View {
        VStack(alignment: .leading, spacing: 0) {
            // "flex items-center gap-2 px-1.5 pt-0.5 text-[.65rem] font-medium
            // uppercase tracking-wider text-muted-foreground"
            HStack(spacing: 8) {
                T3AgentStatusDot(status: status)
                Text(workflow.title.uppercased())
                    .font(T3Font.webLiteral(10.4, .medium))
                    .tracking(0.5)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(t3.web.mutedForeground.color)
                Spacer(minLength: 8)
                Text("\(workflow.members.filter { $0.status.isSettled }.count)/\(workflow.members.count) settled")
                    .font(T3Font.webLiteral(10.4).monospaced())
                    .foregroundStyle(t3.web.mutedForeground.color.opacity(0.8))
                // "size=icon-micro variant=ghost-muted", aria "Collapse workflow"
                Button { setOpen(false) } label: {
                    LucideIcon(.chevronDown, size: 12)
                        .foregroundStyle(t3.web.mutedForeground.color)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse workflow")
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)
            ForEach(workflow.members) { member in
                T3AgentRow(agent: member, panel: panel)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t3.web.card.color.opacity(0.3),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))   // `rounded-lg` = `--radius`
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(t3.web.border.color.opacity(0.5), lineWidth: 1)
        }
    }

    // "flex w-full items-center gap-2 rounded-md px-1.5 py-1 hover:bg-accent/40"
    private var collapsed: some View {
        Button { setOpen(true) } label: {
            HStack(spacing: 8) {
                T3AgentStatusDot(status: status)
                Text(workflow.title)
                    .font(T3Font.web(.sm))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(t3.web.foreground.color)
                Spacer(minLength: 8)
                HStack(spacing: 6) {   // "gap-1.5"
                    if workflow.failedCount > 0 {
                        Text("\(workflow.failedCount) failed")
                            .foregroundStyle(t3.web.destructiveForeground.color)
                    }
                    Text("\(workflow.members.count) agents")
                    Text("· \(T3Agents.tokenCount(workflow.totalTokens)) tok").monospacedDigit()
                    if let elapsed = collapsedElapsed {
                        Text("· \(elapsed)").monospacedDigit()
                    }
                    LucideIcon(.chevronRight, size: 12)
                }
                .font(T3Font.webLiteral(11.2).monospaced())
                .foregroundStyle(t3.web.mutedForeground.color.opacity(0.8))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover ? t3.web.accent.color.opacity(0.4) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))   // `rounded-md`
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var collapsedElapsed: String? {
        guard let started = workflow.startedAt, let completed = workflow.completedAt else { return nil }
        return T3Agents.elapsed(from: started, to: completed)
    }
}

/// `StatusDot` (`:52-59`): "size-1.5 shrink-0 rounded-full" over
/// `STATUS_VISUALS[status].dotClass` — `bg-info` for every in-flight state,
/// `bg-success` completed, `bg-destructive` failed. (`muted-foreground/50` for
/// `idle` and `/60` for the stopped pair are unreachable here: a transcript
/// never proves those states, so `T3Agents.Status` has no case for them.)
private struct T3AgentStatusDot: View {
    @Environment(\.t3) private var t3
    let status: T3Agents.Status
    var body: some View {
        Circle().fill(fill).frame(width: 6, height: 6)
    }
    private var fill: Color {
        switch status {
        case .running: return t3.web.info.color
        case .completed: return t3.web.success.color
        case .failed: return t3.web.destructive.color
        }
    }
}

/// `AgentRow` (`:141-193`): a flat, non-interactive status line on a fixed
/// three-line grid — `h-[3.875rem]` (62), columns `0.375rem` (6) / `1fr` /
/// `auto` with `gap-x-2` (8), rows `1.25rem` (20) / `1.125rem` (18) / `1rem`
/// (16), `px-1.5 py-1` (6 / 4). Lines two and three span columns 2–3, so they
/// start 14 in from the content edge (the dot column plus its gap).
private struct T3AgentRow: View {
    @Environment(\.t3) private var t3
    let agent: T3Agents.Agent
    let panel: T3Agents.Panel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            identity.frame(height: 20)
            activity.frame(height: 18)
            metadata.frame(height: 16)
        }
        .frame(height: 62, alignment: .center)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        // "<span className='sr-only'>{statusLabel}</span>"
        .accessibilityValue(T3Agents.statusLabel(agent.status))
    }

    private var identity: some View {
        HStack(spacing: 8) {
            T3AgentStatusDot(status: agent.status).frame(width: 6)
            // "flex min-w-0 items-baseline gap-2"
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(agent.title)
                    .font(T3Font.web(.sm, .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(t3.web.foreground.color)
                if let role = T3Agents.visibleRole(agent) { rolePill(role) }
            }
            Spacer(minLength: 8)
            // "min-w-14 text-right font-mono text-[.7rem] text-muted-foreground/80"
            HStack(spacing: 4) {
                Text(T3Agents.elapsed(of: agent, panel: panel))
                    .monospacedDigit()
                if agent.status == .completed {
                    LucideIcon(.check, size: 12).foregroundStyle(t3.web.success.color)
                }
            }
            .font(T3Font.webLiteral(11.2).monospaced())
            .foregroundStyle(t3.web.mutedForeground.color.opacity(0.8))
            .frame(minWidth: 56, alignment: .trailing)
        }
    }

    /// "max-w-28 shrink-0 truncate rounded-sm border border-border/60 px-1
    /// font-mono text-[.65rem] text-muted-foreground". `max-w-28` caps a
    /// content-sized pill, so it goes through `CapToContent` — a plain
    /// `.frame(maxWidth:)` would be flexible and eat the title's room.
    private func rolePill(_ role: String) -> some View {
        CapToContent(maxWidth: 112) {
            Text(role)
                .font(T3Font.webLiteral(10.4).monospaced())
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(t3.web.mutedForeground.color)
                .padding(.horizontal, 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)   // `rounded-sm` = `calc(var(--radius) - 4px)`
                .strokeBorder(t3.web.border.color.opacity(0.6), lineWidth: 1)
        }
    }

    /// "block truncate text-xs", `text-destructive-foreground` on a failed row
    /// (`:179-186`). Falls back to the status label when there is no activity.
    private var activity: some View {
        Text(T3Agents.activityText(agent) ?? T3Agents.statusLabel(agent.status))
            .font(T3Font.web(.xs))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(agent.status == .failed
                             ? t3.web.destructiveForeground.color : t3.web.mutedForeground.color)
            .padding(.leading, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "truncate font-mono text-[.7rem] tabular-nums text-muted-foreground/70".
    private var metadata: some View {
        Text(T3Agents.metadataLine(agent))
            .font(T3Font.webLiteral(11.2).monospaced())
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(t3.web.mutedForeground.color.opacity(0.7))
            .padding(.leading, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
