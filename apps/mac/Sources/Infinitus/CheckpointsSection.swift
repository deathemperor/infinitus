import SwiftUI
import InfinitusCore
import InfinitusUI

/// The sessions popover's checkpoint timeline (#167 phase 2): pick a live
/// session, see its per-prompt checkpoints newest first, open one's diff
/// against now, Restore one behind a confirm. Nothing is read until the disclosure opens; every
/// git call runs off the main thread.
struct CheckpointsSection: View {
    @ObservedObject var model: AppModel
    let live: LiveSessions
    @State private var expanded = false
    @State private var pid: Int?
    @State private var checkpoints: [Checkpoint] = []
    @State private var loading = false
    @State private var note: String?
    @State private var confirming: Checkpoint?
    /// The checkpoint whose diff against now is open under its row.
    @State private var diffing: Int?
    @State private var diff: Checkpoints.Diff?
    @State private var diffLoading = false

    private static let age: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private var sessions: [SessionDetail] { live.sessions ?? [] }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                if sessions.isEmpty {
                    Text("No live session.").font(PopupFont.caption2).foregroundStyle(.tertiary)
                } else {
                    Picker("Session", selection: Binding(get: { pid ?? sessions[0].pid }, set: { pid = $0; load() })) {
                        ForEach(sessions, id: \.pid) { s in
                            Text(model.sessionRows().first { $0.pid == s.pid }?.name ?? (s.cwd as NSString).lastPathComponent)
                                .tag(s.pid)
                        }
                    }
                    .font(PopupFont.caption)
                    if loading && checkpoints.isEmpty {
                        Text("Reading checkpoints…").font(PopupFont.caption2).foregroundStyle(.tertiary)
                    } else if checkpoints.isEmpty {
                        Text(model.checkpointsEnabled
                             ? "None yet — one is recorded at each prompt, with the Claude Code plugin installed."
                             : "Off — Display › Checkpoint the repository at every prompt.")
                            .font(PopupFont.caption2).foregroundStyle(.tertiary)
                    }
                    ForEach(checkpoints.reversed(), id: \.n) { c in
                        row(c)
                        if diffing == c.n { diffView(c) }
                    }
                }
                if let note {
                    Text(note).font(PopupFont.caption2).foregroundStyle(.orange)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Checkpoints").font(PopupFont.caption).foregroundStyle(.secondary)
        }
        .onChange(of: expanded) { _, open in if open { load() } }
        .confirmationDialog("Restore checkpoint \(confirming?.subject ?? "")?",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { c in
            Button("Restore", role: .destructive) { restore(c) }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: { c in
            Text("Every file in \((c.root as NSString).lastPathComponent) goes back to how it was then; "
                 + "files created since are removed. The current state is saved as a checkpoint first.")
        }
    }

    private func row(_ c: Checkpoint) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(c.subject).font(PopupFont.caption2).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Text(Self.age.localizedString(for: c.at, relativeTo: Date()))
                .font(PopupFont.caption2).foregroundStyle(.tertiary).monospacedDigit()
            Button(diffing == c.n ? "Hide" : "Diff") { toggleDiff(c) }
                .buttonStyle(.borderless)
                .font(PopupFont.caption2)
            Button("Restore") { confirming = c }
                .buttonStyle(.borderless)
                .font(PopupFont.caption2)
        }
        .help("\(c.sha.prefix(8)) · \(c.root)")
    }

    /// The checkpoint against the working tree now: the stat, and the
    /// patch a copy away (it can be long; the popover is not the place).
    @ViewBuilder private func diffView(_ c: Checkpoint) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if diffLoading {
                Text("Diffing…").font(PopupFont.caption2).foregroundStyle(.tertiary)
            } else if let diff {
                if diff.stat.isEmpty {
                    Text("No changes since this checkpoint.").font(PopupFont.caption2).foregroundStyle(.tertiary)
                } else {
                    Text(diff.stat)
                        .font(PopupFont.caption2.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(14).textSelection(.enabled)
                    HStack(spacing: 8) {
                        Button("Copy patch") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(diff.patch, forType: .string)
                        }
                        .buttonStyle(.borderless).font(PopupFont.caption2)
                        if diff.truncated {
                            Text("patch cut at \(Checkpoints.patchCap / 1024) KB; the stat is complete")
                                .font(PopupFont.caption2).foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .padding(.leading, 12)
    }

    private func toggleDiff(_ c: Checkpoint) {
        guard diffing != c.n else { diffing = nil; diff = nil; return }
        guard let session = sessions.first(where: { $0.pid == (pid ?? sessions.first?.pid) }),
              let record = ClaudeSessions.list(claudeDir: ClaudeSessions.configHome()).first(where: { Int($0.pid) == session.pid })
        else { return }
        diffing = c.n
        diff = nil
        diffLoading = true
        Task.detached(priority: .userInitiated) {
            let result = Result { try Checkpoints.diff(cwd: record.cwd, sessionId: record.sessionId, from: c.n, to: nil) }
            await MainActor.run {
                guard diffing == c.n else { return }
                switch result {
                case .success(let d): diff = d
                case .failure(let error): note = "diff failed: \(error)"; diffing = nil
                }
                diffLoading = false
            }
        }
    }

    private func load() {
        guard let session = sessions.first(where: { $0.pid == (pid ?? sessions.first?.pid) }),
              let record = ClaudeSessions.list(claudeDir: ClaudeSessions.configHome()).first(where: { Int($0.pid) == session.pid })
        else { checkpoints = []; return }
        loading = true
        note = nil
        Task.detached(priority: .userInitiated) {
            let result = Result { try Checkpoints.list(cwd: record.cwd, sessionId: record.sessionId) }
            await MainActor.run {
                switch result {
                case .success(let list): checkpoints = list
                case .failure(let error): checkpoints = []; note = "\(error)"
                }
                diffing = nil; diff = nil
                loading = false
            }
        }
    }

    private func restore(_ c: Checkpoint) {
        confirming = nil
        guard let session = sessions.first(where: { $0.pid == (pid ?? sessions.first?.pid) }),
              let record = ClaudeSessions.list(claudeDir: ClaudeSessions.configHome()).first(where: { Int($0.pid) == session.pid })
        else { return }
        let repo = (record.cwd as NSString).lastPathComponent
        Task.detached(priority: .userInitiated) {
            let result = Result { try Checkpoints.restore(cwd: record.cwd, sessionId: record.sessionId, n: c.n) }
            await MainActor.run {
                switch result {
                case .success(let done):
                    model.logEvent("other", icon: "clock.arrow.2.circlepath",
                                   "restored \(repo) to checkpoint \(done.restored.subject)")
                case .failure(let error):
                    note = "restore failed: \(error)"
                }
                load()
            }
        }
    }
}
