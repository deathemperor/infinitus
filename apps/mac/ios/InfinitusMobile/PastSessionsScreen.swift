import SwiftUI
import InfinitusCore

/// The Sessions tab's clock button route.
struct PastSessionsRoute: Hashable {}

/// Every session the Mac has run (#164), newest first — repo, opening
/// prompt, last activity — with Resume (and Fork, #167): the Mac opens a
/// terminal in the session's folder with `claude --resume`, and the chat opens here once
/// the new pid shows up in the snapshot (the same `requestedPid` path a
/// started session takes).
struct PastSessionsScreen: View {
    @ObservedObject var model: MirrorModel
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [PastSession] = []
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    @State private var resuming: String?
    /// Which paired Mac's history (#144 phase 3); `nil` is the primary.
    @State private var macId: String?

    private static let age: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        List {
            if let error {
                Section { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            ForEach(shown, id: \.sessionId) { session in
                row(session)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Past sessions")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Repo, folder or first message")
        .toolbar {
            if !model.others.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Mac", selection: $macId) {
                            Text(model.machineName(macId: nil)).tag(String?.none)
                            ForEach(model.others) { other in
                                Text(other.pairing.name).tag(String?.some(other.id))
                            }
                        }
                    } label: {
                        Label(model.machineName(macId: macId), systemImage: "desktopcomputer")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        }
        .onChange(of: macId) { _, _ in
            sessions = []
            Task { await load() }
        }
        .onSubmit(of: .search) { Task { await load() } }
        .overlay {
            if loading && sessions.isEmpty {
                ProgressView()
            } else if !loading && shown.isEmpty && error == nil {
                ContentUnavailableView("No past sessions", systemImage: "clock.arrow.circlepath",
                                       description: Text("Sessions the Mac has run show up here."))
            }
        }
        .refreshable { await load() }
        .task {
            if macId == nil { macId = model.defaultTargetMacId }
            await load()
        }
    }

    /// Typing filters the fetched set on the phone; submitting asks the
    /// Mac to search past the newest ones.
    private var shown: [PastSession] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return sessions }
        return sessions.filter {
            $0.repo.lowercased().contains(needle) || $0.cwd.lowercased().contains(needle)
                || $0.firstMessage.lowercased().contains(needle)
        }
    }

    private func row(_ session: PastSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(session.repo).font(.headline).lineLimit(1)
                if session.live {
                    Text("live").font(.caption).foregroundStyle(.green)
                }
                Spacer(minLength: 8)
                Text(Self.age.localizedString(for: session.lastActivityAt, relativeTo: Date()))
                    .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
            }
            Text(session.firstMessage)
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            Text(session.cwd)
                .font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.head)
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            if !session.live {
                Button { resume(session) } label: { Label("Resume", systemImage: "play.fill") }
                    .tint(.accentColor)
            }
            Button { resume(session, fork: true) } label: { Label("Fork", systemImage: "arrow.triangle.branch") }
                .tint(.indigo)
        }
        .contextMenu {
            if !session.live {
                Button { resume(session) } label: { Label("Resume", systemImage: "play.fill") }
            }
            Button { resume(session, fork: true) } label: { Label("Fork", systemImage: "arrow.triangle.branch") }
            Button { UIPasteboard.general.string = session.sessionId } label: {
                Label("Copy session id", systemImage: "doc.on.doc")
            }
        }
        .overlay(alignment: .trailing) {
            if resuming == session.sessionId { ProgressView() }
        }
    }

    private func load() async {
        // The Mac this load is for: switching Macs mid-fetch (a parked
        // one takes the full timeout) must not land the late reply, or
        // its error, under the newly chosen Mac's label.
        let target = macId
        loading = true
        defer { if target == macId { loading = false } }
        do {
            let query = search.trimmingCharacters(in: .whitespaces)
            let reply = try await model.mirror(for: target).pastSessions(
                limit: query.isEmpty ? 50 : 200, search: query.isEmpty ? nil : query)
            guard target == macId else { return }
            sessions = reply.sessions
            error = nil
        } catch {
            guard target == macId else { return }
            self.error = error.localizedDescription
        }
    }

    /// Fork (#167 phase 3): a new session continuing from the transcript,
    /// this one untouched — so a live session can be branched too.
    private func resume(_ session: PastSession, fork: Bool = false) {
        resuming = session.sessionId
        error = nil
        let request = SessionStart.Request(cwd: session.cwd, resume: session.sessionId, fork: fork ? true : nil)
        Task {
            defer { resuming = nil }
            do {
                let reply = try await model.mirror(for: macId).startSession(request)
                guard reply.outcome == "started" else {
                    error = reply.detail ?? reply.outcome
                    return
                }
                if let pid = reply.pid {
                    model.requestedMacId = macId
                    model.requestedPid = pid
                }
                dismiss()
                await model.refresh(macId: macId)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
