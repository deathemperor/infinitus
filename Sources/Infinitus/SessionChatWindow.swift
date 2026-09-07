import SwiftUI
import AppKit
import InfinitusCore
import InfinitusUI

/// The Mac's chat with one live session (#151): the phone's feed
/// screen, on the Mac, reading the transcript straight from disk
/// (`SessionFeedReader`) and sending through the same
/// `AppModel.deliverSessionInput` the phone's route lands in. One
/// window per pid, reused across visits — a closed borderless NSWindow
/// lingers in AppKit's list anyway (WallWindow's lesson), and the
/// content is detached on close so nothing ticks while it's hidden.
@MainActor
final class SessionChatWindows: NSObject, NSWindowDelegate {
    static let shared = SessionChatWindows()

    private var windows: [Int32: NSWindow] = [:]
    private var stores: [Int32: SessionChatStore] = [:]

    func open(_ session: SessionDetail, model: AppModel) {
        let pid = Int32(session.pid)
        if let w = windows[pid], w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let store = stores[pid] ?? SessionChatStore(pid: pid, session: session, model: model)
        stores[pid] = store
        let host = NSHostingController(rootView: SessionChatRoot(store: store, model: model))
        // Never let the hosting view size the window (the pop-out's
        // unbounded-ideal-width crash): the root pins its own minimums.
        host.sizingOptions = []
        let w = windows[pid] ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("SessionChat")
            w.center()
            w.delegate = self
            return w
        }()
        // Setting the content controller shrinks the window to the hosting
        // view's (zero) frame; put the size back afterwards.
        let frame = w.frame
        w.contentViewController = host
        if frame.width < 200 {
            w.setContentSize(NSSize(width: 560, height: 680))
            w.center()
        } else {
            w.setFrame(frame, display: true)
        }
        w.title = SessionNaming.displayName(name: model.sessionProgress.byPid[session.pid]?.name,
                                            autoName: model.sessionProgress.byPid[session.pid]?.autoName,
                                            cwd: session.cwd)
        windows[pid] = w
        store.start()
        w.makeKeyAndOrderFront(nil)
        model.uiSurface("chat:\(pid)", visible: true)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow,
              let pid = windows.first(where: { $0.value == w })?.key else { return }
        w.contentViewController = nil
        stores[pid]?.stop()
        stores[pid]?.model?.uiSurface("chat:\(pid)", visible: false)
    }
}

/// The window's model: the feed, long-polled off the main actor the way
/// the phone polls the mirror — `waitForChange` blocks until the
/// transcript's stamp moves, so the main actor sees one publish per
/// change, never one per line.
@MainActor
final class SessionChatStore: ObservableObject {
    let pid: Int32
    let session: SessionDetail
    @Published private(set) var feed: SessionFeed?
    /// No record for the pid any more: the session ended.
    @Published private(set) var gone = false
    @Published private(set) var sending = false
    @Published var note: String?
    private(set) weak var model: AppModel?
    private var loop: Task<Void, Never>?

    init(pid: Int32, session: SessionDetail, model: AppModel) {
        self.pid = pid
        self.session = session
        self.model = model
    }

    func start() {
        guard loop == nil else { return }
        let box = model?.ownedBox
        loop = Task.detached(priority: .utility) { [pid, weak self] in
            var since: String?
            while !Task.isCancelled {
                let claudeDir = ClaudeSessions.configHome()
                // An owned session's prompts live in memory, not the
                // transcript: they ride the stamp, and its actor wakes
                // this wait the moment one parks (OwnedFeed).
                let owned = box?.existing.flatMap { $0.ownedPids.contains(pid) ? $0 : nil }
                SessionFeedReader.waitForChange(pid: pid, claudeDir: claudeDir, since: since, wait: MirrorTransport.tailWaitMax,
                                                decorate: { stamp in owned.map { OwnedFeed.decorate(stamp, pending: $0.pending(pid: pid)) } ?? stamp },
                                                wake: owned?.wake)
                if Task.isCancelled { return }
                guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == pid }) else {
                    await MainActor.run { self?.gone = true }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    continue
                }
                var feed = SessionFeedReader.read(record: record, claudeDir: claudeDir, limit: 200)
                if let owned, let f = feed { feed = OwnedFeed.augment(f, pending: owned.pending(pid: pid)) }
                if let feed, feed.stamp != since || since == nil {
                    since = feed.stamp
                    await MainActor.run {
                        self?.feed = feed
                        self?.gone = false
                    }
                }
                // No stamp to wait on (transcript not there yet): pace
                // the retry instead of spinning on an instant return.
                if since == nil { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func send(_ request: SessionInput.Request) {
        guard let model, !sending else { return }
        sending = true
        note = nil
        Task.detached(priority: .userInitiated) { [pid, weak self] in
            let reply = model.deliverSessionInput(pid: pid, request, from: "Mac")
            await MainActor.run {
                self?.sending = false
                if reply.outcome != "delivered" {
                    self?.note = reply.detail.map { "\(reply.outcome) — \($0)" } ?? reply.outcome
                }
            }
        }
    }

    func sendKey(_ key: String) { send(.init(kind: .key, text: key)) }

    /// A prompt image, read the way the mirror's image route reads it.
    nonisolated func image(id: String) -> NSImage? {
        let claudeDir = ClaudeSessions.configHome()
        guard let record = ClaudeSessions.list(claudeDir: claudeDir).first(where: { $0.pid == pid }),
              let image = SessionFeedReader.imageData(record: record, id: id, claudeDir: claudeDir,
                                                      attachmentsDir: SessionInput.defaultAttachmentsDir)
        else { return nil }
        return NSImage(data: image.data)
    }
}

private struct SessionChatRoot: View {
    @ObservedObject var store: SessionChatStore
    @ObservedObject var model: AppModel
    @State private var draft = ""
    @State private var expandedPeers: Set<String> = []
    @State private var expandedTurns: Set<String> = []
    @State private var expandedGroups: Set<String> = []
    @FocusState private var composerFocused: Bool

    private var items: [SessionFeedItem] { store.feed?.items ?? [] }
    /// The timeline reduced to rows (#223); nil for a feed without one.
    private var rows: [ThreadFeedRow]? {
        store.feed?.timeline.map {
            ThreadFeedPresentation.derive($0, expandedTurnIds: expandedTurns, expandedWorkGroupIds: expandedGroups)
        }
    }
    private var newestAnchor: AnyHashable? {
        if let rows { return rows.last.map { AnyHashable($0.id) } }
        return items.indices.last.map { AnyHashable($0) }
    }
    private var status: String { store.gone ? "ended" : (store.feed?.status ?? store.session.status) }

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
        .onExitCommand { if status == "busy" { store.sendKey("esc") } }
        .reloadOnInjection()
    }

    private var header: some View {
        let progress = model.sessionProgress.byPid[store.session.pid]
        return HStack(spacing: 8) {
            Circle().fill(color(for: status)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(SessionNaming.displayName(name: store.feed?.name ?? progress?.name,
                                               autoName: progress?.autoName, cwd: store.session.cwd))
                    .font(.headline).lineLimit(1)
                Text("\(status) · pid \(String(store.session.pid)) · \((store.session.cwd as NSString).abbreviatingWithTildeInPath)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if status == "busy" {
                Button("Interrupt") { store.sendKey("esc") }
                    .help("Stop the current turn (Esc)")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var feedList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let rows {
                        ForEach(rows) { row in
                            ThreadFeedRowView(row: row, expandedTurns: $expandedTurns, expandedGroups: $expandedGroups,
                                              expandedPeers: $expandedPeers) { id in
                                MacFeedThumbnail(store: store, id: id)
                            }
                            .id(row.id)
                        }
                    } else {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            SessionFeedRow(item: item, expandedPeers: $expandedPeers) { id in
                                MacFeedThumbnail(store: store, id: id)
                            }
                            .id(index)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay {
                if store.feed == nil, !store.gone {
                    Text("Reading the transcript…").foregroundStyle(.secondary)
                } else if items.isEmpty {
                    Text("Messages show up here as the session works.").foregroundStyle(.secondary)
                }
            }
            .onChange(of: items.count) { _, count in
                guard count > 0, let anchor = newestAnchor else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(anchor, anchor: .bottom) }
            }
            .onChange(of: rows?.last?.id) { _, id in
                // The live row keeps one id while its content swaps; a new
                // tail row is what moves the bottom.
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(AnyHashable(id), anchor: .bottom) }
            }
        }
    }

    /// The phone's prompt card: a permission's Deny / Allow / Allow-for-
    /// session, a question's numbered options — each one key into the
    /// session's own prompt.
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
                    Button("Deny") { store.sendKey("3") }
                    Button("Allow") { store.sendKey("1") }
                    Button("Allow \(ToolApproval.Rule.from(tool: item.toolName ?? "", input: item.text).label) this session") {
                        store.send(.init(kind: .approve,
                                         text: ToolApproval.encode(tool: item.toolName ?? "", input: item.text)))
                    }
                    if store.sending { ProgressView().controlSize(.small) }
                }
            } else {
                Label(item.text, systemImage: "questionmark.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.yellow)
                ForEach(Array((item.options ?? []).enumerated()), id: \.offset) { i, option in
                    Button {
                        store.sendKey(String(i + 1))
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(option).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
                Label(note, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(store.gone ? "The session ended." : "Message the session…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($composerFocused)
                    .onSubmit(sendDraft)
                    .disabled(store.gone)
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.sending || store.gone)
                .help("Send (Return; Option-Return for a new line)")
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(12)
        .onAppear { composerFocused = true }
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !store.sending else { return }
        store.send(.init(kind: .message, text: text))
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

/// One prompt image, read from disk on demand, kept for the view's life.
private struct MacFeedThumbnail: View {
    let store: SessionChatStore
    let id: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Label("image", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: id) {
            let loaded = await Task.detached(priority: .utility) { store.image(id: id) }.value
            image = loaded
        }
    }
}
