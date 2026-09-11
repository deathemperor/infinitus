import SwiftUI
import InfinitusCore
import InfinitusUI

/// T3's thread settings sheet (C-5, spec §5) with what a phone can do to
/// a session on the Mac: move its permission mode (#163 phase 2), settle
/// / snooze / pin it (#223 attention), stop the running turn. T3's model
/// picker and title regenerate need Mac routes the phone does not have
/// yet and are left out; archive maps to nothing a session has.
struct T3ThreadSettingsSheet: View {
    @ObservedObject var model: MirrorModel
    let session: SessionDetail
    var macId: String?
    let facts: SessionFacts?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.t3) private var t3
    @State private var busy = false
    @State private var note: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("Permission mode") {
                        ForEach(Array(SessionStart.hookModes.enumerated()), id: \.element.mode) { i, m in
                            if i > 0 { divider }
                            actionRow(m.label, detail: modeDetail(m.mode), glyph: modeGlyph(m.mode)) {
                                send(.init(kind: .mode, text: m.mode))
                            }
                        }
                    }
                    section("Attention") {
                        actionRow(facts?.settledAt == nil ? "Settle" : "Unsettle",
                                  detail: facts?.settledAt == nil ? "Mark it handled; it drops to the tail of the list" : "Bring it back into the live list",
                                  glyph: "checkmark.circle") {
                            attention(facts?.settledAt == nil ? .settle : .unsettle)
                        }
                        divider
                        if facts?.snoozedUntil != nil {
                            actionRow("Unsnooze", detail: "Wake it now", glyph: "bell") { attention(.unsnooze) }
                        } else {
                            actionRow("Snooze an hour", detail: "Quiet until then", glyph: "moon.zzz") {
                                attention(.snooze, until: Date().addingTimeInterval(3600))
                            }
                            divider
                            actionRow("Snooze until tomorrow", detail: "Quiet until 9 in the morning", glyph: "moon.zzz") {
                                attention(.snooze, until: Self.tomorrowMorning())
                            }
                        }
                        divider
                        actionRow(facts?.pinnedAt == nil ? "Pin" : "Unpin",
                                  detail: facts?.pinnedAt == nil ? "Keep it at the top of the list" : "Let it sort with the rest",
                                  glyph: "pin") {
                            attention(facts?.pinnedAt == nil ? .pin : .unpin)
                        }
                    }
                    if facts?.status == .running {
                        section("Turn") {
                            actionRow("Stop the current turn", detail: "Sends Escape; the session keeps its context", glyph: "stop.circle", danger: true) {
                                send(.init(kind: .key, text: "esc"))
                            }
                        }
                    }
                    if let note {
                        Text(note).font(T3Font.mobile(.xs)).foregroundStyle(t3.mobile.foregroundMuted.color).padding(.horizontal, 20)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(t3.mobile.sheet.color.ignoresSafeArea())
            .navigationTitle("Thread settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.fraction(0.7), .fraction(0.92)])
        .presentationDragIndicator(.visible)
    }

    private func modeDetail(_ mode: String) -> String {
        switch mode {
        case "acceptEdits": return "File edits go through; other tools still ask here"
        case "bypassPermissions": return "Nothing asks — only for folders you trust completely"
        default: return "Every tool asks, and the prompts show up on this phone"
        }
    }

    private func modeGlyph(_ mode: String) -> String {
        switch mode {
        case "acceptEdits": return "pencil.circle"
        case "bypassPermissions": return "bolt.circle"
        default: return "hand.raised.circle"
        }
    }

    static func tomorrowMorning(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    private func send(_ request: SessionInput.Request) {
        busy = true
        note = nil
        Task {
            defer { busy = false }
            do {
                let reply = try await model.mirror(for: macId).sessionInput(pid: Int32(session.pid), request: request)
                note = reply.outcome == "delivered" ? "Done" : SessionFeedScreen.describe(reply.outcome)
            } catch {
                note = "couldn't reach the Mac"
            }
        }
    }

    private func attention(_ action: AttentionStore.Action, until: Date? = nil) {
        busy = true
        note = nil
        Task {
            defer { busy = false }
            do {
                _ = try await model.mirror(for: macId).sessionAttention(
                    pid: Int32(session.pid), request: .init(action: action, until: until, commandId: UUID().uuidString))
                note = "Done"
                await model.refresh(macId: macId)
            } catch {
                note = "couldn't reach the Mac"
            }
        }
    }

    // MARK: T3 sheet furniture (`mx-4 rounded-2xl bg-card`)

    private func section<C: View>(_ title: String, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(T3Font.mobile(.sm, .medium)).foregroundStyle(t3.mobile.foregroundMuted.color)
                .padding(.horizontal, 20)
            VStack(spacing: 0) { rows() }
                .background(t3.mobile.card.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 16)
        }
    }

    private var divider: some View { Divider().overlay(t3.mobile.borderSubtle.color).padding(.leading, 52) }

    private func actionRow(_ title: String, detail: String, glyph: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: glyph).font(.system(size: 18))
                    .foregroundStyle(danger ? t3.mobile.dangerForeground.color : t3.mobile.iconMuted.color)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(T3Font.mobile(.base, .medium))
                        .foregroundStyle(danger ? t3.mobile.dangerForeground.color : t3.mobile.foreground.color)
                    Text(detail).font(T3Font.mobile(.sm)).foregroundStyle(t3.mobile.foregroundMuted.color)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

/// T3's git overview (`GitOverviewSheet.tsx`) as C's shell: the branch
/// as the title, the six rows with the subtitles they show before any
/// action runs. Review changes is live — it pushes the session's
/// checkpoint timeline (#167), the phone's turn diffs today; the git
/// actions light up in E when the Mac serves git facts, and say so.
struct T3GitSheet: View {
    let branch: String?
    /// The session whose checkpoints Review changes opens; nil (the
    /// render harness) keeps the row inert like the others.
    var session: SessionDetail? = nil
    var macId: String? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.t3) private var t3

    private static let rows: [(title: String, subtitle: String, glyph: String)] = [
        ("Commit", "Stage and commit the working tree", "checkmark.circle"),
        ("Push", "Push the branch to its upstream", "arrow.up.circle"),
        ("Create PR", "Open a pull request for this branch", "arrow.triangle.pull"),
        ("Pull latest", "Fetch and merge upstream changes", "arrow.down.circle"),
        ("Review changes", "Inspect turn diffs, worktree changes, and base branch diff", "doc.text.magnifyingglass"),
        ("Branches & worktrees", "Switch branch, create branch, or move to a worktree", "arrow.triangle.branch"),
    ]

    private static let reviewRow = 4

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(branch ?? "No branch").font(T3Font.mobile(.xxl, .bold)).foregroundStyle(t3.mobile.foreground.color)
                        Text(branch == nil ? "This session's folder is not on a git branch the Mac has reported."
                                           : "Review changes shows this session's turn diffs; the other git actions arrive with a later release, the Mac's terminal has them today.")
                            .font(T3Font.mobile(.sm)).foregroundStyle(t3.mobile.foregroundMuted.color)
                    }
                    .padding(.horizontal, 24).padding(.top, 28)
                    VStack(spacing: 0) {
                        ForEach(Array(Self.rows.enumerated()), id: \.offset) { i, row in
                            if i > 0 { Divider().overlay(t3.mobile.border.color).padding(.leading, 72) }
                            if i == Self.reviewRow, let session {
                                NavigationLink { CheckpointsScreen(session: session, macId: macId) } label: { label(row, live: true) }
                                    .buttonStyle(.plain)
                            } else {
                                label(row, live: false)
                            }
                        }
                    }
                    .background(t3.mobile.card.color, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 24)
            }
            .background(t3.mobile.sheet.color.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.fraction(0.55), .fraction(0.92)])
        .presentationDragIndicator(.visible)
    }

    /// One row; a live one reads in the foreground colours, an inert one
    /// stays muted.
    private func label(_ row: (title: String, subtitle: String, glyph: String), live: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: row.glyph).font(.system(size: 16))
                .foregroundStyle(live ? t3.mobile.icon.color : t3.mobile.iconMuted.color)
                .frame(width: 36, height: 36)
                .background(t3.mobile.subtle.color, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(T3Font.mobile(.lg, .bold))
                    .foregroundStyle(live ? t3.mobile.foreground.color : t3.mobile.foregroundMuted.color)
                Text(row.subtitle).font(T3Font.mobile(.sm))
                    .foregroundStyle(live ? t3.mobile.foregroundMuted.color : t3.mobile.foregroundTertiary.color)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(t3.mobile.chevron.color)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}
