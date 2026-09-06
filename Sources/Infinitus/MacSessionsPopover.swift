import SwiftUI
import InfinitusCore
import InfinitusUI

/// The brain chip's popover: the live sessions card, checkpoints, Start a
/// session, then a collapsed "Past sessions" list (#164) — the newest transcripts under
/// ~/.claude/projects, each resumable in a new terminal. The scan runs
/// only when the disclosure opens, never per snapshot, so an idle
/// pop-out stays idle.
struct MacSessionsPopover: View {
    @ObservedObject var model: AppModel
    let live: LiveSessions
    @State private var expanded = false
    @State private var past: [PastSession] = []
    @State private var loading = false
    @State private var note: String?

    private static let age: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SessionListCard(live: live, progress: model.sessionProgress, births: model.sessionBirths)
            Divider()
            CheckpointsSection(model: model, live: live)
            Divider()
            StartSessionSection(model: model)
            Divider()
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 4) {
                    if loading && past.isEmpty {
                        Text("Reading transcripts…").font(PopupFont.caption2).foregroundStyle(.tertiary)
                    } else if past.isEmpty {
                        Text("No past sessions.").font(PopupFont.caption2).foregroundStyle(.tertiary)
                    }
                    ForEach(past.prefix(12), id: \.sessionId) { session in
                        row(session)
                    }
                    if let note {
                        Text(note).font(PopupFont.caption2).foregroundStyle(.orange)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Past sessions").font(PopupFont.caption).foregroundStyle(.secondary)
            }
            .onChange(of: expanded) { _, open in if open { load() } }
        }
    }

    private func row(_ session: PastSession) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(session.repo).font(PopupFont.caption).lineLimit(1)
                    if session.live {
                        Text("live").font(PopupFont.caption2).foregroundStyle(.green)
                    }
                    Text(Self.age.localizedString(for: session.lastActivityAt, relativeTo: Date()))
                        .font(PopupFont.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
                Text(session.firstMessage)
                    .font(PopupFont.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if !session.live {
                Button("Resume") { resume(session) }
                    .buttonStyle(.borderless)
                    .font(PopupFont.caption)
            }
        }
        .help(session.cwd)
    }

    /// Off the main thread: a directory walk plus up to 30 transcript heads.
    private func load() {
        loading = true
        Task.detached(priority: .userInitiated) {
            let list = PastSessions.list(claudeDir: ClaudeSessions.configHome(), limit: 30)
                .filter { !$0.live }
            await MainActor.run {
                past = list
                loading = false
            }
        }
    }

    private func resume(_ session: PastSession) {
        note = nil
        let host = model.sessionHost
        let request = SessionStart.Request(cwd: session.cwd, resume: session.sessionId)
        Task.detached(priority: .userInitiated) {
            let reply = SessionLauncher.start(request, preferredHost: host)
            await MainActor.run {
                if reply.outcome == "started" {
                    // The row's "resumed" chip, as the phone's Resume gets.
                    if let pid = reply.pid, let birth = SessionBirth(request: request) { model.recordBirth(pid: pid, birth) }
                    model.sessionsShown = false
                } else {
                    note = reply.detail ?? reply.outcome
                }
            }
        }
    }
}
