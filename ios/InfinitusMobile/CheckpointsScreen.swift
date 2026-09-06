import SwiftUI
import InfinitusCore

/// The session detail's Checkpoints row route.
struct CheckpointsRoute: Hashable {
    let session: SessionDetail
}

/// A live session's checkpoint timeline (#167 phase 2), newest first —
/// the repository as it was at each prompt. A row opens its diff
/// against the working tree now; Restore rewrites the Mac's folder to
/// that checkpoint (the state before is checkpointed first, so the
/// restore is itself undoable from this list).
struct CheckpointsScreen: View {
    let session: SessionDetail
    @State private var reply: Checkpoints.Reply?
    @State private var loading = false
    @State private var error: String?
    @State private var confirming: Checkpoint?
    @State private var restoring: Int?
    @State private var result: String?

    private static let age: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private var pid: Int32 { Int32(session.pid) }
    private var checkpoints: [Checkpoint] { (reply?.checkpoints ?? []).reversed() }

    var body: some View {
        List {
            if let error {
                Section { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            if let result {
                Section { Text(result).font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(checkpoints, id: \.n) { checkpoint in
                NavigationLink {
                    CheckpointDiffScreen(pid: pid, checkpoint: checkpoint)
                } label: {
                    row(checkpoint)
                }
                .swipeActions(edge: .trailing) {
                    Button { confirming = checkpoint } label: {
                        Label("Restore", systemImage: "clock.arrow.2.circlepath")
                    }
                    .tint(.orange)
                }
                .overlay(alignment: .trailing) {
                    if restoring == checkpoint.n { ProgressView() }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Checkpoints")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if loading && reply == nil {
                ProgressView()
            } else if !loading && checkpoints.isEmpty && error == nil {
                ContentUnavailableView("No checkpoints", systemImage: "clock.arrow.2.circlepath",
                                       description: Text("With the Infinitus plugin and Display › “Checkpoint the repository at every prompt” on, each prompt in a git folder lands here."))
            }
        }
        .confirmationDialog(confirming.map { "Restore \($0.subject)?" } ?? "",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { checkpoint in
            Button("Restore the folder to this checkpoint", role: .destructive) { restore(checkpoint) }
        } message: { _ in
            Text("Files in \((reply?.cwd ?? session.cwd) as NSString).lastPathComponent) change on the Mac. The state right now is checkpointed first.")
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func row(_ checkpoint: Checkpoint) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(checkpoint.subject).font(.subheadline).lineLimit(2)
                Spacer(minLength: 8)
                Text(Self.age.localizedString(for: checkpoint.at, relativeTo: Date()))
                    .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
            }
            Text(String(checkpoint.sha.prefix(10)))
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            reply = try await NetworkFleetMirror.shared.checkpoints(pid: pid)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func restore(_ checkpoint: Checkpoint) {
        restoring = checkpoint.n
        result = nil
        Task {
            defer { restoring = nil }
            do {
                let outcome = try await NetworkFleetMirror.shared.restoreCheckpoint(pid: pid, n: checkpoint.n)
                if outcome.outcome == "restored" {
                    result = "Restored to \(checkpoint.subject)"
                        + (outcome.backup.map { " — the state before is checkpoint #\($0)" } ?? "")
                    await load()
                } else {
                    error = outcome.detail ?? outcome.outcome
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// One checkpoint against the working tree now: the stat, then the
/// patch (capped on the Mac at `Checkpoints.patchCap`).
struct CheckpointDiffScreen: View {
    let pid: Int32
    let checkpoint: Checkpoint
    @State private var diff: Checkpoints.Diff?
    @State private var error: String?

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 12) {
                if let error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                } else if let diff {
                    if diff.stat.isEmpty {
                        Text("No changes since this checkpoint.").foregroundStyle(.secondary)
                    } else {
                        Text(diff.stat).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        Text(diff.patch).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                        if diff.truncated {
                            Text("Patch cut short on the Mac; the stat above is complete.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .padding()
        }
        .navigationTitle(checkpoint.subject)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { diff = try await NetworkFleetMirror.shared.checkpointDiff(pid: pid, n: checkpoint.n) }
            catch { self.error = error.localizedDescription }
        }
    }
}
