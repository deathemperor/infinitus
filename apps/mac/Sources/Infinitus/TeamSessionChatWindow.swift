import SwiftUI
import AppKit
import Combine
import InfinitusCore
import InfinitusUI

/// Driving a teammate's session (#220 §7.2): the Mac chat's surface over
/// the grantor's tail route, every control gated on the capabilities they
/// granted me, each command's lane + outcome inline. One window per
/// (kid, session), reused; the content is detached on close so the 3 s
/// tail poll stops with the window (WallWindow's lesson).
@MainActor
final class TeamSessionChatWindows: NSObject, NSWindowDelegate {
    static let shared = TeamSessionChatWindows()

    private var windows: [String: NSWindow] = [:]
    private var stores: [String: TeamSessionChatStore] = [:]

    func open(kid: String, session: TeamDocs.LiveSession, team: TeamModel) {
        let key = "\(kid)/\(session.id)"
        if let w = windows[key], w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let store = stores[key] ?? TeamSessionChatStore(kid: kid, session: session, team: team)
        stores[key] = store
        let host = NSHostingController(rootView: TeamSessionChatRoot(store: store, team: team))
        // Never let the hosting view size the window (the pop-out's
        // unbounded-ideal-width crash): the root pins its own minimums.
        host.sizingOptions = []
        let w = windows[key] ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("TeamSessionChat")
            w.center()
            w.delegate = self
            return w
        }()
        let frame = w.frame
        w.contentViewController = host
        if frame.width < 200 {
            w.setContentSize(NSSize(width: 560, height: 680))
            w.center()
        } else {
            w.setFrame(frame, display: true)
        }
        w.title = "\(team.reader?.members[kid]?.name ?? kid) · \(session.name ?? session.project)"
        windows[key] = w
        store.start()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow,
              let key = windows.first(where: { $0.value == w })?.key else { return }
        w.contentViewController = nil
        stores[key]?.stop()
    }
}

/// The window's model: the remote feed polled every 3 s while open, each
/// command's delivery, and the store-lane acks that arrive with the reader.
@MainActor
final class TeamSessionChatStore: ObservableObject {
    let kid: String
    let session: TeamDocs.LiveSession
    @Published private(set) var feed: SessionFeed?
    /// The lane the last tail came over; nil when none answered.
    @Published private(set) var lane: TeamControl.Lane?
    @Published private(set) var sending = false
    /// The last command's "send via LAN → delivered" line, or the error.
    @Published private(set) var note: String?
    /// Store-lane commands waiting on the grantor's fetch: id → action.
    @Published private(set) var pending: [String: String] = [:]
    private weak var team: TeamModel?
    private var loop: Task<Void, Never>?
    private var acks: AnyCancellable?

    init(kid: String, session: TeamDocs.LiveSession, team: TeamModel) {
        self.kid = kid
        self.session = session
        self.team = team
    }

    var controls: Set<String> { team?.controls(grantedBy: kid) ?? [] }

    func start() {
        guard loop == nil, let team else { return }
        let kid = kid, session = session.id
        loop = Task { [weak self] in
            var since: String?
            while !Task.isCancelled {
                if let (lane, feed) = await team.tail(kid: kid, session: session, since: since) {
                    since = feed.stamp
                    self?.feed = feed
                    self?.lane = lane
                } else {
                    self?.lane = nil
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        // Store-lane acks arrive with the reader (each fetch).
        acks = team.$reader.receive(on: DispatchQueue.main).sink { [weak self] reader in
            guard let self, let reader, !pending.isEmpty else { return }
            for (id, action) in pending {
                guard let ack = reader.members[kid]?.acks[id] else { continue }
                pending[id] = nil
                note = Self.line(action, TeamControl.Lane.store, ack.outcome, ack.detail)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        acks = nil
    }

    func drive(_ action: String, _ text: String? = nil) {
        guard let team, !sending else { return }
        sending = true
        Task {
            let delivery = await team.drive(kid: kid, session: session.id, action: action, text: text)
            sending = false
            guard let delivery else { note = team.lastError ?? "failed"; return }
            if delivery.lane == .store { pending[delivery.id] = action }
            note = Self.line(action, delivery.lane, delivery.outcome, delivery.detail)
        }
    }

    static func line(_ action: String, _ lane: TeamControl.Lane, _ outcome: String, _ detail: String?) -> String {
        "\(action) \(lane.label) → \(outcome)\(detail.map { " — \($0)" } ?? "")"
    }
}

private struct TeamSessionChatRoot: View {
    @ObservedObject var store: TeamSessionChatStore
    @ObservedObject var team: TeamModel
    @State private var draft = ""
    @State private var expandedPeers: Set<String> = []
    @FocusState private var composerFocused: Bool

    private var items: [SessionFeedItem] { store.feed?.items ?? [] }
    private var status: String { store.feed?.status ?? store.session.status }
    private var controls: Set<String> { store.controls }
    private var name: String { team.reader?.members[store.kid]?.name ?? store.kid }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            feedList
            Divider()
            if let prompt = FeedRows.pendingPrompt(store.feed) { promptBar(prompt) }
            composer
        }
        .frame(minWidth: 400, minHeight: 360)
        .reloadOnInjection()
    }

    /// `.disabled` + the missing capability in `.help` (spec §7.2).
    private func gated<V: View>(_ capability: String, _ view: V) -> some View {
        view.disabled(!controls.contains(capability))
            .help(controls.contains(capability) ? "" : "needs the \(capability) grant")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(color(for: status)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(name) · \(store.session.name ?? store.session.project)").font(.headline).lineLimit(1)
                Text("\(status) · \(store.session.project) · \(store.lane?.label ?? "no live tail (store only)")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            gated(TeamGrants.mode, Menu("Mode") {
                ForEach(SessionStart.hookModes, id: \.mode) { choice in
                    Button(choice.label) { store.drive(TeamGrants.mode, choice.mode) }
                }
            }.fixedSize())
            gated(TeamGrants.resume, Button("Resume") { store.drive(TeamGrants.resume) })
            gated(TeamGrants.key, Button("Interrupt") { store.drive(TeamGrants.key, "esc") })
        }
        .disabled(store.sending)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var feedList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        // Images never leave the grantor's Mac.
                        SessionFeedRow(item: item, expandedPeers: $expandedPeers) { _ in
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        }
                        .id(index)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay {
                if store.feed == nil {
                    Text(store.lane == nil ? "No live tail: \(name)'s Mac is not reachable right now. Commands still go through the store."
                                           : "Reading the transcript…")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).padding()
                } else if items.isEmpty {
                    Text("Messages show up here as the session works.").foregroundStyle(.secondary)
                }
            }
            .onChange(of: items.count) { _, count in
                guard count > 0 else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }

    /// A permission's Deny / Allow (`approve deny|allow`), a question's
    /// numbered options (`key <n>`).
    private func promptBar(_ item: SessionFeedItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.kind == .permission {
                Label("\(item.toolName ?? "A tool") wants to run this", systemImage: "hand.raised.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                Text(item.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 10) {
                    gated(TeamGrants.approve, Button("Deny") { store.drive(TeamGrants.approve, "deny") })
                    gated(TeamGrants.approve, Button("Allow") { store.drive(TeamGrants.approve, "allow") })
                    if store.sending { ProgressView().controlSize(.small) }
                }
            } else {
                Label(item.text, systemImage: "questionmark.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.yellow)
                ForEach(Array((item.options ?? []).enumerated()), id: \.offset) { i, option in
                    gated(TeamGrants.key, Button {
                        store.drive(TeamGrants.key, String(i + 1))
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(option).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain))
                }
            }
        }
        .disabled(store.sending)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let note = store.note {
                let refused = TeamControl.Outcome.refusals.contains { note.contains("→ \($0)") }
                Label(note, systemImage: refused ? "exclamationmark.circle" : "arrow.turn.down.right")
                    .font(.caption).foregroundStyle(refused ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            if !store.pending.isEmpty {
                Text("\(store.pending.count) waiting on \(name)'s next fetch").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(controls.contains(TeamGrants.send) ? "Message \(name)'s session…" : "They did not grant send.",
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($composerFocused)
                    .onSubmit(sendDraft)
                    .disabled(!controls.contains(TeamGrants.send))
                gated(TeamGrants.send, Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.sending))
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(12)
        .onAppear { composerFocused = true }
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !store.sending, controls.contains(TeamGrants.send) else { return }
        store.drive(TeamGrants.send, text)
        draft = ""
    }

    private func color(for status: String) -> Color {
        switch status {
        case "busy": return .orange
        case "waiting": return .yellow
        case "idle": return .green
        case "shell": return .blue
        default: return .gray
        }
    }
}
