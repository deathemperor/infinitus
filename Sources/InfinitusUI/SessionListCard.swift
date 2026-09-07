import SwiftUI
import InfinitusCore

/// The sessions card's progress feed — the host reads Claude Code's own
/// session records + transcript tails (mac: SessionProgressModel). A host
/// without one leaves `byPid` empty and the rows keep their single line.
@MainActor
public protocol SessionProgressSource: ObservableObject {
    var byPid: [Int: SessionProgress] { get }
    /// The host's per-session facts (#223 phase 3) — the row's attention
    /// dot and word, and its shelf. Present only for leased sessions; a
    /// host without them leaves the map empty and the engine's status
    /// word decides.
    var facts: [Int: SessionFacts] { get }
    /// Fleet-wide output tokens per minute — the footer's ⚡ gauge.
    var tokenRate: TokenRate? { get }
    /// `sessions`: the engine's current per-session detail (busy-first,
    /// capped) — only those get matched to a transcript and read.
    func refresh(sessions: [SessionDetail])
}

public extension SessionProgressSource {
    var facts: [Int: SessionFacts] { [:] }
    func refresh(sessions: [SessionDetail]) {}
}

/// The brain chip's click-through: every live Claude Code session with
/// status, directory, and age ("can active session be clickable and show
/// something?" — this is the something).
public struct SessionListCard<P: SessionProgressSource>: View {
    let live: LiveSessions
    @ObservedObject var progress: P
    /// How Infinitus started each session (#163/#165) — a chip beside the
    /// name; empty on hosts that don't know.
    let births: [Int: SessionBirth]
    /// A host with a chat surface of its own (the Mac's window, #151)
    /// gets each row as a click-through; the phone routes rows itself
    /// and leaves this nil.
    let onOpen: ((SessionDetail) -> Void)?

    public init(live: LiveSessions, progress: P, births: [Int: SessionBirth] = [:],
                onOpen: ((SessionDetail) -> Void)? = nil) {
        self.live = live
        self.progress = progress
        self.births = births
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(SessionSummary.tooltip(live))
                .font(PopupFont.caption).foregroundStyle(.secondary)
            if let sessions = live.sessions, !sessions.isEmpty {
                Divider()
                ForEach(sessions, id: \.pid) { s in
                    let facts = progress.facts[s.pid]
                    let attention = SessionListPresentation.attention(facts, fallbackStatus: s.status)
                    let shelf = facts.flatMap(shelfWord)
                    let word = shelf ?? SessionListPresentation.statusWord(attention, raw: s.status)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(color(for: word))
                                .frame(width: 7, height: 7)
                            if attention == .approval || attention == .input {
                                Image(systemName: attention == .approval ? "hand.raised.fill" : "questionmark.circle.fill")
                                    .font(PopupFont.caption2).foregroundStyle(.yellow)
                            }
                            Text(SessionNaming.displayName(name: progress.byPid[s.pid]?.name, autoName: progress.byPid[s.pid]?.autoName, cwd: s.cwd))
                                .font(PopupFont.caption)
                                .lineLimit(1)
                                .truncationMode(.head)
                            if let birth = births[s.pid], let chip = birth.chip {
                                Text(chip)
                                    .font(PopupFont.caption2)
                                    .foregroundStyle(birth.isUnrestricted ? Color.orange : Color.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 12)
                            Text(word)
                                .font(PopupFont.caption).foregroundStyle(.secondary)
                            Text(age(s.startedAt))
                                .font(PopupFont.caption2).foregroundStyle(.tertiary)
                                .monospacedDigit()
                            if onOpen != nil {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(PopupFont.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        if let p = progress.byPid[s.pid], p.hasProgressSignal {
                            SessionProgressLine(progress: p)
                        }
                    }
                    .opacity(shelf == nil ? 1 : 0.55)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen?(s) }
                    .help(onOpen == nil ? tooltip(s, progress.byPid[s.pid])
                                        : tooltip(s, progress.byPid[s.pid]) + " · click to chat")
                }
            } else {
                Text("Session detail needs a newer cswap engine.")
                    .font(PopupFont.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: 340)
        .task(id: live.sessions?.map(\.pid)) {
            while !Task.isCancelled {
                progress.refresh(sessions: live.sessions ?? [])
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
            }
        }
    }

    private func color(for status: String) -> Color {
        switch status {
        case "busy": return .orange
        case "waiting": return .yellow
        case "idle": return .green
        case "shell": return .blue
        case "failed": return .red
        default: return .gray
        }
    }

    /// A shelved row's word in the status slot — the card is one line
    /// per session, so the shelf replaces the word rather than adding one.
    private func shelfWord(_ f: SessionFacts) -> String? {
        if SessionListPresentation.isSnoozed(f) { return "snoozed" }
        if SessionListPresentation.isSettled(f) { return "settled" }
        return nil
    }

    /// pid · kind · branch · model · cwd — the metadata the phone's row
    /// prints inline lives in the tooltip here, where the row stays one line.
    private func tooltip(_ s: SessionDetail, _ p: SessionProgress?) -> String {
        var parts = ["pid \(s.pid)", s.kind]
        if let branch = p?.gitBranch { parts.append("⎇ \(branch)") }
        if let model = p?.model { parts.append(model) }
        parts.append(s.cwd)
        return parts.joined(separator: " · ")
    }

    private func shortCwd(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func age(_ epochMs: Double) -> String {
        let started = Date(timeIntervalSince1970: epochMs / 1000)
        let s = Int(-started.timeIntervalSinceNow)
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}

public extension SessionProgress {
    /// False for the all-nil value `SessionProgress.read` returns when a
    /// transcript can't be matched or opened — that case keeps the row's
    /// existing single-line rendering, no placeholder second line.
    /// `public` (#9 native shell): the phone's Sessions tab gates its own
    /// native rows on the same signal.
    var hasProgressSignal: Bool {
        nowDoing != nil || todos != nil || retrying
            || (lastActivityAt.map { -$0.timeIntervalSinceNow > 120 } ?? false)
    }
}

/// The row's second line: what a session is doing right now, per
/// `SessionProgress` — zero-token, read from the transcript tail.
/// `public` (#9 native shell): the phone's Sessions tab puts this exact
/// line inside its own native rows.
public struct SessionProgressLine: View {
    let progress: SessionProgress

    public init(progress: SessionProgress) { self.progress = progress }

    private var quietMinutes: Int? {
        guard let last = progress.lastActivityAt else { return nil }
        let idle = -last.timeIntervalSinceNow
        guard idle > 120 else { return nil }
        return Int(idle / 60)
    }

    public var body: some View {
        HStack(spacing: 4) {
            statusText
            if let todos = progress.todos {
                TodoCapsule(done: todos.done, total: todos.total)
                Text(todoLabel(todos))
                    .font(PopupFont.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            } else if let phase = progress.phase {
                // Layer-1 heuristic; the agent's own todo list is the
                // better self-report whenever it exists (#13).
                Text(phase)
                    .font(PopupFont.caption2).foregroundStyle(.tertiary)
            }
            if let quiet = quietMinutes {
                Text("quiet \(quiet)m")
                    .font(PopupFont.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var statusText: some View {
        if progress.retrying {
            Text("retrying")
                .font(PopupFont.caption2).foregroundStyle(.orange)
        } else if let nowDoing = progress.nowDoing {
            Text(nowDoing)
                .font(PopupFont.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
        }
    }

    private func todoLabel(_ todos: SessionProgress.Todos) -> String {
        let counts = "\(todos.done)/\(todos.total)"
        guard let activeForm = todos.activeForm else { return counts }
        return "\(counts) · \(activeForm)"
    }
}

/// Tiny (~40pt) progress capsule for a session's TodoWrite completion.
/// `public` (#9 native shell) — same capsule in the phone's session rows.
public struct TodoCapsule: View {
    let done: Int
    let total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    private var fraction: CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(done) / CGFloat(total)
    }

    public var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.25))
            Capsule().fill(Color.accentColor)
                .frame(width: 40 * fraction)
        }
        .frame(width: 40, height: 4)
    }
}
