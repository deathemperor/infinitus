import SwiftUI
import InfinitusCore

/// The session detail's Checkpoints row route.
struct CheckpointsRoute: Hashable {
    let session: SessionDetail
    var macId: String? = nil
}

/// A live session's checkpoint timeline (#167 phase 2), newest first —
/// the repository as it was at each prompt. A row opens its diff
/// against the working tree now; Restore rewrites the Mac's folder to
/// that checkpoint (the state before is checkpointed first, so the
/// restore is itself undoable from this list).
struct CheckpointsScreen: View {
    let session: SessionDetail
    /// `nil` is the primary Mac (#144 phase 2).
    var macId: String? = nil
    @ObservedObject var model = MirrorModel.shared
    private var mirror: NetworkFleetMirror { model.mirror(for: macId) }
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
        .environment(\.sessionMirror, mirror)
        .overlay {
            if loading && reply == nil {
                ProgressView()
            } else if !loading && checkpoints.isEmpty && error == nil {
                ContentUnavailableView("No checkpoints", systemImage: "clock.arrow.2.circlepath",
                                       description: Text(reply?.emptyReason ?? ""))
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
            reply = try await mirror.checkpoints(pid: pid)
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
                let outcome = try await mirror.restoreCheckpoint(pid: pid, n: checkpoint.n)
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

/// The chat's Review button target (#166): `Checkpoint` itself is not
/// Identifiable.
struct ReviewTarget: Identifiable {
    let checkpoint: Checkpoint
    var id: Int { checkpoint.n }
}

/// One checkpoint against the working tree now (#166): the files and
/// their hunks, a tap comments a hunk, Approve / Request changes sends
/// the review as the session's next message (`PatchReview.compose`).
struct CheckpointDiffScreen: View {
    let pid: Int32
    let checkpoint: Checkpoint
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sessionMirror) private var mirror
    @State private var diff: Checkpoints.Diff?
    @State private var files: [PatchReview.File] = []
    @State private var error: String?
    /// Comment text by hunk, keyed "fileIndex:hunkIndex".
    @State private var comments: [String: String] = [:]
    @State private var editing: HunkRef?
    @State private var sending = false
    @State private var sent: String?

    struct HunkRef: Identifiable, Hashable {
        let file: Int
        let hunk: Int
        var id: String { "\(file):\(hunk)" }
    }

    var body: some View {
        List {
            if let error {
                Section { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            if let diff, diff.stat.isEmpty {
                Section { Text("No changes since this checkpoint.").foregroundStyle(.secondary) }
            }
            ForEach(Array(files.enumerated()), id: \.offset) { fi, file in
                Section {
                    if file.hunks.isEmpty {
                        Text(file.note ?? "no text changes").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(file.hunks.enumerated()), id: \.offset) { hi, hunk in
                        let ref = HunkRef(file: fi, hunk: hi)
                        Button { editing = ref } label: { hunkRow(hunk, comment: comments[ref.id]) }
                            .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text(file.path).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.head)
                        if let note = file.note { Text("· \(note)").font(.caption2) }
                    }
                    .textCase(nil)
                }
            }
            if diff?.truncated == true {
                Section { Text("Patch cut short on the Mac; the rest is not shown.").font(.caption).foregroundStyle(.orange) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(checkpoint.subject)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if diff == nil && error == nil { ProgressView() } }
        .safeAreaInset(edge: .bottom) { verdictBar }
        .sheet(item: $editing) { ref in
            CommentSheet(hunk: files[ref.file].hunks[ref.hunk], text: comments[ref.id] ?? "") { text in
                comments[ref.id] = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
            }
        }
        .task {
            do {
                let fresh = try await mirror.checkpointDiff(pid: pid, n: checkpoint.n)
                diff = fresh
                files = PatchReview.parse(fresh.patch)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func hunkRow(_ hunk: PatchReview.Hunk, comment: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(hunk.header).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(line.hasPrefix("+") ? Color.green : line.hasPrefix("-") ? Color.red : Color.primary)
                }
            }
            if let comment {
                Label(comment, systemImage: "text.bubble").font(.caption).foregroundStyle(Color.accentColor).lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var commentList: [PatchReview.Comment] {
        // In patch order (numerically — "10" sorts before "2" as text).
        comments.compactMap { key, text -> (Int, Int, String)? in
            let parts = key.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, parts[0] < files.count, parts[1] < files[parts[0]].hunks.count else { return nil }
            return (parts[0], parts[1], text)
        }
        .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        .map { PatchReview.Comment(path: files[$0.0].path, hunk: files[$0.0].hunks[$0.1], text: $0.2) }
    }

    private var verdictBar: some View {
        VStack(spacing: 6) {
            if let sent { Text(sent).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 12) {
                Button { send(.approve) } label: {
                    Label("Approve", systemImage: "checkmark.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(sending || diff == nil || diff?.stat.isEmpty == true)
                Button { send(.requestChanges) } label: {
                    Label(comments.isEmpty ? "Request changes" : "Request changes (\(comments.count))",
                          systemImage: "exclamationmark.bubble").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(sending || comments.isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send(_ verdict: PatchReview.Verdict) {
        sending = true
        sent = nil
        let text = PatchReview.compose(checkpoint: checkpoint.n, subject: checkpoint.subject,
                                       verdict: verdict, comments: commentList)
        Task {
            defer { sending = false }
            do {
                let reply = try await mirror.sessionInput(pid: pid, request: .init(kind: .message, text: text))
                if reply.outcome == "delivered" {
                    dismiss()
                } else {
                    sent = reply.detail ?? reply.outcome
                }
            } catch {
                sent = "couldn't reach the Mac"
            }
        }
    }
}

/// One hunk's comment: the hunk above for reference, the text below.
private struct CommentSheet: View {
    let hunk: PatchReview.Hunk
    @State var text: String
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(hunk.header).foregroundStyle(.secondary)
                            ForEach(Array(hunk.lines.prefix(PatchReview.excerptLines).enumerated()), id: \.offset) { _, line in
                                Text(line.isEmpty ? " " : line)
                                    .foregroundStyle(line.hasPrefix("+") ? Color.green : line.hasPrefix("-") ? Color.red : Color.primary)
                            }
                            if hunk.lines.count > PatchReview.excerptLines { Text("…").foregroundStyle(.secondary) }
                        }
                        .font(.system(.caption2, design: .monospaced))
                    }
                }
                Section("Comment") {
                    TextEditor(text: $text).frame(minHeight: 120).focused($focused)
                }
            }
            .navigationTitle("Comment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(text); dismiss() }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}
