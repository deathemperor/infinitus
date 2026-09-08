import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import InfinitusCore
import InfinitusUI

/// One session's recent important messages (#17), chat-style — `GET
/// /sessions/<pid>/tail` polled every 5s while this screen is on screen,
/// with a bottom composer and per-card action buttons (layer 2) that
/// `POST /sessions/<pid>/input`.
struct SessionFeedScreen: View {
    @ObservedObject var model: MirrorModel
    let session: SessionDetail
    /// `nil` is the primary Mac (#144 phase 2).
    var macId: String? = nil
    /// The Mac this session lives on — the primary's mirror, or its own
    /// Mac's (#144 phase 2). Same-body children read it from the
    /// environment (`.environment(\.sessionMirror, mirror)` below).
    private var mirror: NetworkFleetMirror { model.mirror(for: macId) }
    private var outboxKey: String { OutboxDelivery.macKey(for: macId, model: model) }

    @State private var feed: SessionFeed?
    @State private var errorText: String?
    @State private var draft = ""
    @State private var sendingMessage = false
    @State private var messageResult: String?
    @State private var actionSending = false
    @State private var actionResult: String?
    // MARK: attachments (2026-09-03 "add features to allow attachments")
    @State private var attachments: [PendingAttachment] = []
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var composerFocused = false
    @State private var previewing: PendingAttachment?
    @State private var attachmentError: String?
    @State private var awsLoginItem: AwsLogin.Item?
    /// Review this turn's changes (#166): the newest checkpoint vs now.
    @State private var reviewTarget: ReviewTarget?
    /// Why Review changes had nothing to show (#214): an alert, not a
    /// caption — the caption read as the button doing nothing.
    @State private var reviewEmptyReason: String?
    @State private var lastRowVisible = true
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var screenshots = ScreenshotWatch()
    /// "compact" (avatar + three lines) or "strip" (title row + a gauge
    /// strip) — both built for the user to compare (2026-09-04 "this UI
    /// needs big overhaul"; "also build option 2 for me to see").
    @AppStorage("chat_header") private var headerStyle = "compact"
    /// Peer messages opened to their full text (keyed by time + text).
    @State private var expandedPeers: Set<String> = []
    /// The reducer's toggles (#223): folded turns and tool groups opened.
    @State private var expandedTurns: Set<String> = []
    @State private var expandedGroups: Set<String> = []
    @Environment(\.dismiss) private var dismiss
    /// Bumped on foreground return: `.task(id:)` drops the long-poll that
    /// was in flight when the app left — its connection may be dead until
    /// a 35 s timeout — and starts a fresh one.
    @State private var pollGeneration = 0
    /// Messages the Mac accepted that the transcript hasn't shown yet
    /// (user 2026-09-04 "sending … not responsive": the draft cleared and
    /// nothing else moved until the session read its inbox).
    @State private var pendingSent: [PendingSent] = []
    /// #168: this session's queued outbox item, if a send couldn't reach
    /// the Mac and is waiting for it to come back.
    @State private var queued: OutboxItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // MARK: pending prompt (critique 2026-09-04 P0: a permission was one
    // unguarded tap on a prominent button that auto-scroll could move)
    @State private var confirmingAllow = false
    @State private var selectedOption: Int?
    @State private var deliveredTick = 0
    @State private var deniedTick = 0
    // MARK: dictation (user 2026-09-03 "build a smart dictation for mobile")
    @StateObject private var dictation = Dictation()
    /// The draft as it stood when the mic went on; the transcript
    /// appends to it.
    @State private var draftBeforeDictation = ""
    /// A non-English dictation as spoken, kept beside its English
    /// draft so the chip can show it and the send can fall back to it.
    @State private var dictatedOriginal: String?
    @State private var dictatedLocale: Locale?
    @State private var translateRequest: DictationTranslateRequest?
    @State private var translating = false
    @State private var dictationNote: String?
    @State private var showOriginal = false

    /// A picked file, already processed into the exact bytes/mime that
    /// will ride in `SessionInput.Attachment`.
    private struct PendingAttachment: Identifiable {
        let id = UUID()
        let name: String
        let mime: String
        let data: Data
        let thumbnail: UIImage?
    }

    /// A sent message as the phone showed it, until the transcript does.
    private struct PendingSent: Identifiable {
        let id = UUID()
        let text: String
        let images: [UIImage]
        let files: [String]
        var queued = false
        let at = Date()
    }

    /// The session hit an expired AWS session; the login runs on the
    /// Mac, driven from AwsLoginScreen.
    @ViewBuilder private var awsLoginBar: some View {
        if let item = model.awsLogin(macId: macId, pid: session.pid) {
            Button { awsLoginItem = item } label: {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Needs AWS login · \(item.profile)").font(.subheadline.bold())
                        Text(awsLoginStatus(item)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("Sign in").font(.subheadline.bold()).foregroundStyle(.orange)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
            }
            .buttonStyle(.plain)
        }
    }

    private func awsLoginStatus(_ item: AwsLogin.Item) -> String {
        switch item.state?.phase {
        case nil: return "Tap to sign in from this phone"
        case .starting: return "Starting on the Mac…"
        case .waitingForBrowser: return "Sign-in page ready — tap to continue"
        case .waitingForCode: return "Waiting for the authorization code"
        case .done: return "Signed in — the session was told to continue"
        case .failed: return item.state?.message ?? "Failed — tap to retry"
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if let rows {
                    // The T3-shaped feed (#223): the timeline reduced to
                    // rows — tool groups, turn folds, one live row.
                    ForEach(rows) { row in
                        let isLast = row.id == rows.last?.id
                        VStack(alignment: .leading, spacing: 6) {
                            ThreadFeedRowView(row: row, expandedTurns: $expandedTurns, expandedGroups: $expandedGroups,
                                              expandedPeers: $expandedPeers) {
                                FeedThumbnail(pid: Int32(session.pid), id: $0)
                            }
                            if isLast, pendingPrompt == nil, let item = feed?.items.last,
                               Self.canContinue(after: item, status: feed?.status ?? session.status) {
                                continueRow
                            }
                        }
                        .id(row.id)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: ThreadFeedRowView<EmptyView>.isChrome(row) ? 2 : 4, leading: 16,
                                                  bottom: ThreadFeedRowView<EmptyView>.isChrome(row) ? 2 : 4, trailing: 16))
                        .onAppear { if isLast { lastRowVisible = true } }
                        .onDisappear { if isLast { lastRowVisible = false } }
                    }
                } else {
                    // A Mac from before the timeline: the flat item list.
                    ForEach(Array((feed?.items ?? []).enumerated()), id: \.offset) { index, item in
                        VStack(alignment: .leading, spacing: 6) {
                            SessionFeedRow(item: item, expandedPeers: $expandedPeers) {
                                FeedThumbnail(pid: Int32(session.pid), id: $0)
                            }
                            if index == (feed?.items.count ?? 0) - 1, pendingPrompt == nil,
                               Self.canContinue(after: item, status: feed?.status ?? session.status) {
                                continueRow
                            }
                        }
                        .id(index)
                        .listRowSeparator(.hidden)
                        // Tool chips are the bulk of a transcript; they sit
                        // tight so the conversation isn't 85% dead space.
                        .listRowInsets(EdgeInsets(top: item.kind == .tool ? 2 : 4, leading: 16,
                                                  bottom: item.kind == .tool ? 2 : 4, trailing: 16))
                        // The last row's visibility drives the scroll-to-
                        // bottom button (user 2026-09-03 from the phone).
                        .onAppear { if index == (feed?.items.count ?? 0) - 1 { lastRowVisible = true } }
                        .onDisappear { if index == (feed?.items.count ?? 0) - 1 { lastRowVisible = false } }
                    }
                }
                ForEach(pendingSent) { pending in
                    pendingRow(pending)
                        .id(pending.id)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }
            .listStyle(.plain)
            .overlay {
                if feed == nil, errorText == nil {
                    ThemedPlaceholder(theme: model.rowTheme, key: "loading")
                } else if feed?.items.isEmpty == true {
                    ThemedPlaceholder(theme: model.rowTheme, key: "empty", plainSymbol: "bubble.left.and.bubble.right",
                                      description: "Messages show up here as the session works.")
                }
            }
            // Dragging the feed tucks the keyboard away; so does a tap on
            // it (user 2026-09-03 from the phone: "I can't hide keyboard").
            // `.immediately`, not `.interactively`: a drag that ends midway
            // through an interactive dismissal leaves the bottom inset at
            // the keyboard's height, and the composer floats mid-screen
            // (user 2026-09-05 screenshot: "Still the floating textinput").
            .scrollDismissesKeyboard(.immediately)
            .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
            .onChange(of: feed?.items.count) { _, _ in
                reconcilePending()
                if let pending = pendingSent.last { scrollToNewest(proxy, pending.id); return }
                guard let anchor = newestAnchor else { return }
                scrollToNewest(proxy, anchor)
            }
            .onChange(of: pendingSent.count) { _, _ in
                guard let last = pendingSent.last else { return }
                scrollToNewest(proxy, last.id)
            }
            .onChange(of: feed?.stamp) { _, _ in
                reconcilePending()
                // The live row keeps its id while its content changes, so
                // the count never moves; a reader at the bottom stays there.
                if rows != nil, lastRowVisible, pendingSent.isEmpty, let anchor = newestAnchor {
                    scrollToNewest(proxy, anchor)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !lastRowVisible, (feed?.items.count ?? 0) > 1 {
                    Button {
                        guard let anchor = newestAnchor else { return }
                        scrollToNewest(proxy, anchor)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.body.weight(.semibold))
                            .padding(10)
                            .background(.regularMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(.quaternary))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 14).padding(.bottom, 10)
                    .accessibilityLabel("Scroll to newest")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: lastRowVisible)
        }
        .sheet(item: $awsLoginItem) { AwsLoginScreen(item: $0, mirror: mirror) }
        .alert("Nothing to review yet", isPresented: Binding(
            get: { reviewEmptyReason != nil }, set: { if !$0 { reviewEmptyReason = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(reviewEmptyReason ?? "")
        }
        .sheet(item: $reviewTarget) { target in
            // A sheet is presented from this node, not from the root:
            // hand it the mirror itself so a review from another Mac's
            // chat goes to that Mac.
            NavigationStack { CheckpointDiffScreen(pid: Int32(session.pid), checkpoint: target.checkpoint) }
                .environment(\.sessionMirror, mirror)
        }
        .background(SwipeBackAnywhere().frame(width: 0, height: 0))
        // Pinned above the transcript, not in it: the feed opens scrolled
        // to the newest message, so a card at the top was out of reach
        // (user 2026-09-03 "have to scroll to top").
        .safeAreaInset(edge: .top, spacing: 0) {
            let theme = model.rowTheme
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    ChatHeaderView(style: headerStyle, theme: theme, data: headerData,
                                   link: { middle in
                                       AnyView(NavigationLink(value: SessionDetailRoute(session: session, macId: macId)) { middle }
                                           .buttonStyle(.plain)
                                           .accessibilityLabel("Session details"))
                                   },
                                   onBack: { dismiss() },
                                   onInterrupt: feed?.status == "busy" ? { sendKey("esc") } : nil)
                }
                .background(theme.plain ? Color.clear : ThemeColor.flash(theme).opacity(0.16))
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
                offlineBanner
                awsLoginBar
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let item = pendingPrompt { promptCard(item) }
                if !screenshots.found.isEmpty { screenshotOffer }
                if let item = queued {
                    QueuedCard(item: item, onEdit: {
                        draft = item.request.text
                        attachments = (item.request.attachments ?? []).map {
                            PendingAttachment(name: $0.name, mime: $0.mime, data: $0.data,
                                             thumbnail: $0.mime.hasPrefix("image/") ? UIImage(data: $0.data) : nil)
                        }
                        OutboxDelivery.outbox.remove(id: item.id)
                        pendingSent.removeAll(where: \.queued)
                        reloadQueued()
                    }, onDiscard: {
                        OutboxDelivery.outbox.remove(id: item.id)
                        pendingSent.removeAll(where: \.queued)
                        reloadQueued()
                    })
                }
                composer
            }
        }
        .onAppear { LeaseReporter.shared.acquire(.session(Int32(session.pid)), on: .mac(macId)) }
        .onDisappear { LeaseReporter.shared.release(.session(Int32(session.pid)), on: .mac(macId)) }
        .onAppear {
            screenshots.check()
            takeStagedCapture()
            reloadQueued()
            // Dev seam like `INFINITUS_FEED_PID`: a headless simulator
            // capture can't tap the camera button.
            if ProcessInfo.processInfo.environment["INFINITUS_STAGE_CAPTURE"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { stageAppScreenshot() }
            }
        }
        .onChange(of: model.stagedCapture?.id) { _, _ in takeStagedCapture() }
        // A screenshot taken while the app is in front: the first one
        // asks for Photos access (that's the discovery moment), later
        // ones show up in the library a beat after the shutter.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            guard ScreenshotWatch.enabled else { return }
            Task {
                if !screenshots.hasAccess { await screenshots.requestAccess() }
                try? await Task.sleep(for: .seconds(1.5))
                screenshots.check()
            }
        }
        // The composer owns the bottom edge; the floating tab bar would
        // sit under it.
        .toolbar(.hidden, for: .tabBar)
        // A header of its own — Messenger/Slack style (user 2026-09-04:
        // "native header is too limited for future builds"): back, the
        // session's name and state as the route into its details, the
        // account's fleet row beneath, all on the theme's tint.
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .background(InteractivePopGesture())
        .sensoryFeedback(.success, trigger: deliveredTick)
        .sensoryFeedback(.warning, trigger: deniedTick)
        .refreshable { await load() }
        .task(id: pollGeneration) {
            // Long-poll loop: each request returns when the transcript
            // changes (or after the Mac's wait cap), so a reply lands
            // within a second of being written. A long-poll that came
            // back with news re-arms almost at once — the Mac paced it,
            // and a reply streams in over many writes (user 2026-09-04
            // "receiving … not responsive": each landed up to 2 s late).
            // The floor is for the plain fetch (a Mac that ignores
            // `since`/`wait`) and for failures.
            while !Task.isCancelled {
                let started = Date()
                let before = feed?.stamp
                let ok = await load(longPoll: before != nil)
                if Task.isCancelled { return }
                // A background flush (the outbox is a separate actor)
                // can clear this session's queued item between polls.
                reloadQueued()
                let changed = before != nil && feed?.stamp != before
                let floor: TimeInterval = !ok ? 3 : changed ? 0.5 : 2
                let elapsed = Date().timeIntervalSince(started)
                if elapsed < floor {
                    try? await Task.sleep(nanoseconds: UInt64((floor - elapsed) * 1_000_000_000))
                }
            }
        }
        // Back in the foreground: the long-poll in flight when the app
        // left may sit on a dead connection until its timeout; start a
        // fresh one (the stale one's answer is dropped in `load`).
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                pollGeneration += 1
                // Back from another app: anything shot meanwhile.
                screenshots.check()
            }
        }
        // Outermost on purpose: an environment write flows only into the
        // view it modifies, so every inset, sheet and thumbnail above
        // sits inside it (#144 phase 2).
        .environment(\.sessionMirror, mirror)
    }

    private func scrollToNewest(_ proxy: ScrollViewProxy, _ id: some Hashable) {
        if reduceMotion { proxy.scrollTo(id, anchor: .bottom) }
        else { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
    }

    /// The echo of a sent message: the user bubble, lighter, with a line
    /// saying where it stands. Honest about it — "sent" is the Mac's
    /// word; the session shows it here once it has read its inbox.
    private func pendingRow(_ pending: PendingSent) -> some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 6) {
                if !pending.text.isEmpty { Text(pending.text) }
                if !pending.images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(pending.images.enumerated()), id: \.offset) { _, image in
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: 120, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                ForEach(pending.files, id: \.self) { name in
                    Label(name, systemImage: "paperclip")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if pending.queued {
                    Text("queued").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Sent · shows here once the session reads it")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityElement(children: .combine)
    }

    /// Drops an echo once the transcript carries the message: a user
    /// entry no older than the send (a minute of clock slack) whose text
    /// contains it — or any such entry for an attachments-only send,
    /// whose text the Mac wrote. A never-read one goes after ten minutes.
    private func reconcilePending() {
        guard !pendingSent.isEmpty else { return }
        let users = (feed?.items ?? []).filter { $0.kind == .user }
        let now = Date()
        pendingSent.removeAll { pending in
            if now.timeIntervalSince(pending.at) > 600 { return true }
            return users.contains { item in
                guard let at = item.at, at >= pending.at.addingTimeInterval(-60) else { return false }
                return pending.text.isEmpty || item.text.contains(pending.text)
            }
        }
    }

    /// This session's outbox item, if any — re-read after every send and
    /// on appear, since the outbox lives on disk and a flush can clear it
    /// from under this screen.
    private func reloadQueued() {
        queued = OutboxDelivery.outbox.items(macKey: outboxKey).first { $0.pid == Int32(session.pid) }
    }

    /// The account behind this session: the summary's account and the
    /// fleet that renders it, when there is one.
    private var headerAccount: (account: Account, fleet: MirrorFleetModel)? {
        guard let summary = model.accountSummary(macId: macId, pid: session.pid),
              let account = summary.account,
              let fleet = model.fleets(macId: macId).first(where: { $0.engineID == summary.engineID }) else { return nil }
        return (account, fleet)
    }

    /// What the header shows: the session's name and state, the
    /// account behind it and every window on it.
    private var headerData: ChatHeaderData {
        let pair = headerAccount
        var data = ChatHeaderData(name: feed?.name ?? repoName(session.cwd),
                                  status: feed?.status ?? session.status,
                                  accountName: pair.map { ChatHeaderData.accountName($0.account) },
                                  plan: pair?.account.plan,
                                  chips: pair.map { ChatHeaderData.chips($0.account, theme: model.rowTheme,
                                                                         burnStyle: $0.fleet.burnStyle) } ?? [])
        data.macName = model.macName(macId)
        // The Fleet card's beats for this account (the fleet's ticks
        // reach here through MirrorModel's objectWillChange relay); the
        // switch celebration only when this account is the one switched to.
        if let (account, fleet) = pair {
            data.switchTick = account.active ? fleet.switchFlashTick : 0
            data.deathTick = fleet.deathTicks[account.number] ?? 0
            data.reviveTick = fleet.reviveTicks[account.number] ?? 0
            data.critical = AccountRowVitals.isCritical(account)
            data.lucky = AccountRowVitals.isLucky(account, theme: fleet.rowTheme)
        }
        return data
    }

    /// Reachability, where it's seen: a banner up top, not a caption at
    /// the end of a list that's scrolled elsewhere.
    @ViewBuilder private var offlineBanner: some View {
        if let errorText {
            Label(errorText, systemImage: "wifi.exclamationmark")
                .font(.caption).foregroundStyle(.orange)
                .lineLimit(2)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
                .overlay(alignment: .bottom) { Divider() }
        }
    }

    /// The prompt the session is stopped on, while it is stopped on it —
    /// pinned above the composer so it never moves under a thumb.
    /// The timeline reduced to rows, when the Mac sends one (#223).
    private var rows: [ThreadFeedRow]? {
        feed?.timeline.map {
            ThreadFeedPresentation.derive($0, expandedTurnIds: expandedTurns, expandedWorkGroupIds: expandedGroups)
        }
    }

    /// What "newest" scrolls to: the last row's id, or the last item's index.
    private var newestAnchor: AnyHashable? {
        if let rows { return rows.last.map { AnyHashable($0.id) } }
        return feed?.items.indices.last.map { AnyHashable($0) }
    }

    private var pendingPrompt: SessionFeedItem? {
        guard feed?.waiting == true, let last = feed?.items.last,
              last.kind == .permission || last.kind == .question else { return nil }
        return last
    }

    @ViewBuilder private func promptCard(_ item: SessionFeedItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if item.kind == .permission {
                Label("\(item.toolName ?? "A tool") wants to run this on the Mac",
                      systemImage: "hand.raised.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                Text(item.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 10) {
                    Button("Deny") { deniedTick += 1; sendKey("3") }
                        .buttonStyle(.bordered).tint(.primary)
                    Button("Allow…") { confirmingAllow = true }
                        .buttonStyle(.bordered)
                    if actionSending { ProgressView() }
                    Spacer()
                }
                .disabled(actionSending)
                .confirmationDialog("Run this on the Mac?", isPresented: $confirmingAllow, titleVisibility: .visible) {
                    Button("Allow") { sendKey("1") }
                    // Remembered by the Mac for the plugin's PreToolUse
                    // hook (#79); Bash rules are per command verb.
                    Button("Allow \(ToolApproval.Rule.from(tool: item.toolName ?? "", input: item.text).label) for this session") {
                        sendInput(.init(kind: .approve, text: ToolApproval.encode(tool: item.toolName ?? "", input: item.text)))
                    }
                } message: {
                    Text(item.text).lineLimit(6)
                }
            } else if let questions = item.questions, !questions.isEmpty {
                // An owned session's prompt: every question, answered at once.
                QuestionsPrompt(questions: questions, sending: actionSending) {
                    sendInput(.init(kind: .answers, text: $0))
                }
                .id("\(item.at?.timeIntervalSince1970 ?? 0)|\(item.text)")
            } else {
                Label(item.text, systemImage: "questionmark.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.yellow)
                let options = item.options ?? []
                ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                    Button {
                        selectedOption = selectedOption == i ? nil : i
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: selectedOption == i ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedOption == i ? Color.accentColor : Color.secondary)
                            Text(option).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Option \(i + 1) of \(options.count): \(option)")
                    .accessibilityAddTraits(selectedOption == i ? .isSelected : [])
                }
                HStack(spacing: 10) {
                    Button(selectedOption.map { "Send answer \($0 + 1) of \(options.count)" } ?? "Pick an answer") {
                        if let i = selectedOption { sendKey(String(i + 1)) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedOption == nil || actionSending)
                    if actionSending { ProgressView() }
                }
            }
            if let actionResult {
                Label(actionResult, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: item.text) { _, _ in selectedOption = nil }
    }

    @discardableResult
    private func load(longPoll: Bool = false) async -> Bool {
        do {
            if longPoll, let since = feed?.stamp {
                do {
                    let fresh = try await mirror.sessionTail(
                        pid: Int32(session.pid), limit: 30, since: since,
                        wait: MirrorTransport.tailWaitMax)
                    // A poll loop that was replaced (foreground return)
                    // must not overwrite the new loop's feed with its
                    // late answer.
                    if Task.isCancelled { return false }
                    feed = fresh
                    errorText = nil
                    return true
                } catch {
                    // The pinned route may have died — the plain fetch
                    // below walks every route again.
                }
            }
            let fresh = try await mirror.sessionTail(pid: Int32(session.pid), limit: 30)
            if Task.isCancelled { return false }
            feed = fresh
            errorText = nil
            return true
        } catch {
            if Task.isCancelled { return false }
            if feed == nil, let parked = await mirror.parkedTail(pid: Int32(session.pid)) {
                feed = parked
                errorText = "parked — showing the last transcript"
                return false
            }
            errorText = feed == nil ? "couldn't reach \(model.macName(macId) ?? "the Mac"): \(error.localizedDescription)"
                : "offline — showing the last feed"
            return false
        }
    }

    // MARK: - Layer 2: sending in

    /// "Reply…" / "Listening…" in the theme's words (#124): a theme that

    /// renames every tab and state should not leave the composer plain.

    private var composerPlaceholder: String {

        model.rowTheme.loadingWord(dictation.listening ? "composerListening" : "composerReply")

    }


    private var composer: some View {
        VStack(spacing: 4) {
            if let messageResult {
                Text(messageResult).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            if let attachmentError {
                Text(attachmentError).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal)
            }
            if let dictationError = dictation.error {
                Text(dictationError).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal)
            }
            if translating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Translating…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            } else if let original = dictatedOriginal, let locale = dictatedLocale {
                // The dictation as spoken: peek, or put it back.
                HStack(spacing: 8) {
                    Button {
                        showOriginal.toggle()
                    } label: {
                        Text((locale.language.languageCode?.identifier ?? "?").uppercased())
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                    }
                    .accessibilityLabel("Show the dictation as spoken")
                    if showOriginal {
                        Text(original).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        Button("Use it") { draft = original; dictatedOriginal = nil; dictationNote = "Sending as spoken, with a note asking for an English reply." }
                            .font(.caption)
                    } else if let note = dictationNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal)
            } else if let note = dictationNote {
                Text(note).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(attachments) { attachmentChip($0) } }
                        .padding(.horizontal)
                }
            }
            HStack(spacing: 8) {
                // This turn's diff with hunk comments (#166): the newest
                // checkpoint is the state at the last prompt.
                Button { openReview() } label: {
                    Image(systemName: "text.badge.checkmark").font(.title2)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Review changes")
                // One button for everything attachable (user 2026-09-05:
                // "Combine the 3 items into one"): the capture of this
                // screen first, then the library, camera, files, paste.
                Menu {
                    Button { stageAppScreenshot() } label: {
                        Label("Capture This Screen", systemImage: "camera.viewfinder")
                    }
                    // A PhotosPicker inside a Menu never presents (the menu
                    // dismisses first — user 2026-09-03 "Choose library
                    // doesn't show anything"); the picker is a modifier
                    // below, flipped from a plain button like the importer.
                    Button { showPhotoPicker = true } label: {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                    }
                    if CameraCapture.isAvailable {
                        Button { showCamera = true } label: {
                            Label("Take Photo", systemImage: "camera")
                        }
                    }
                    Button { showFileImporter = true } label: {
                        Label("Choose File", systemImage: "doc")
                    }
                    // A copied image/screenshot (user 2026-09-03 from the
                    // phone: "allow pasting images"). The check reads no
                    // pasteboard content, so no paste banner until chosen.
                    if UIPasteboard.general.hasImages {
                        Button { pasteImage() } label: {
                            Label("Paste Image", systemImage: "doc.on.clipboard")
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title2)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Attach")
                .disabled(sendingMessage || attachments.count >= SessionInput.maxAttachments)
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(composerPlaceholder)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 5)
                            .padding(.top, 6)
                            .allowsHitTesting(false)
                    }
                    PasteableTextView(text: $draft, isFocused: $composerFocused,
                                      placeholder: composerPlaceholder) { image in
                        addImage(image, prefix: "pasted")
                    }
                }
                // No hide-keyboard button (user 2026-09-03 from the phone:
                // "too much") — a drag on the feed or a tap outside the
                // composer dismisses it.
                if Dictation.isAvailable {
                    Button {
                        if !dictation.listening {
                            draftBeforeDictation = draft
                            dictatedOriginal = nil
                            dictationNote = nil
                            dictation.hints = dictationHints()
                        }
                        dictation.toggle()
                    } label: {
                        Image(systemName: dictation.listening ? "stop.circle.fill" : "mic.circle")
                            .font(.title2)
                            .foregroundStyle(dictation.listening ? Color.red : Color.accentColor)
                    }
                    .disabled(sendingMessage)
                    .accessibilityLabel(dictation.listening ? "Stop dictating" : "Dictate")
                    // Long-press: the language, without a trip to Settings
                    // (user 2026-09-04 "can it accept Vietnamese?").
                    .contextMenu { languageMenu }
                }
                Button(action: sendMessage) {
                    if sendingMessage {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                }
                .frame(width: 44, height: 44)
                .accessibilityLabel("Send")
                .disabled(sendingMessage
                          || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              && attachments.isEmpty))
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .onChange(of: dictation.transcript) { _, text in
            guard !text.isEmpty else { return }
            let base = draftBeforeDictation
            draft = base.isEmpty || base.hasSuffix(" ") || base.hasSuffix("\n") ? base + text : base + " " + text
        }
        .onChange(of: dictation.listening) { was, now in
            guard was, !now else { return }
            dictationEnded()
        }
        .dictationTranslate(translateRequest) { result in
            guard translating else { return }   // timed out or sent already
            translating = false
            translateRequest = nil
            switch result {
            case .success(let english):
                let base = draftBeforeDictation
                draft = base.isEmpty || base.hasSuffix(" ") || base.hasSuffix("\n") ? base + english : base + " " + english
                dictationNote = nil
            case .failure:
                // No language pack (or iOS 17): send as spoken, and say so.
                dictationNote = "Couldn't translate on the phone — sending as spoken, with a note asking for an English reply."
            }
        }
        .onDisappear { dictation.stop() }
        .onChange(of: photoPickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await addPickedPhotos(items) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCapture { image in addImage(image, prefix: "camera") }
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $previewing) { attachment in
            AttachmentPreview(name: attachment.name, bytes: attachment.data.count,
                              image: attachment.thumbnail)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItems,
                      maxSelectionCount: SessionInput.maxAttachments, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: Self.allowedFileTypes,
                     allowsMultipleSelection: true) { result in
            addPickedFiles(result)
        }
    }

    private static let allowedFileTypes: [UTType] = [
        .png, .jpeg, .heic, .gif, .pdf, .plainText,
        UTType(mimeType: "image/webp"),
    ].compactMap { $0 }

    @ViewBuilder private func attachmentChip(_ attachment: PendingAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail = attachment.thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                        .overlay {
                            if attachment.mime.hasPrefix("video/") {
                                Image(systemName: "play.circle.fill").font(.title3)
                                    .foregroundStyle(.white, .black.opacity(0.5))
                            }
                        }
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: attachment.mime.hasPrefix("video/") ? "video.fill" : "doc.fill").font(.title3)
                        Text(attachment.name).font(.caption2).lineLimit(1)
                    }
                }
            }
            .frame(width: 52, height: 52)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { previewing = attachment }
            Button {
                attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.6))
                    .padding(12)
            }
            .offset(x: 12, y: -12)
            .accessibilityLabel("Remove \(attachment.name)")
        }
    }

    /// PhotosPicker hands over the original bytes (HEIC included); every
    /// image is downscaled to ≤ 2048 px on its long edge and re-encoded
    /// JPEG regardless of source format.
    private func addPickedPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard attachments.count < SessionInput.maxAttachments else { break }
            if PickedVideo.isVideo(item) {
                // A video travels as the movie file (#381), not its poster frame.
                switch await PickedVideo.load(item) {
                case .success(let video):
                    attachments.append(PendingAttachment(name: video.name, mime: video.mime,
                                                         data: video.data, thumbnail: video.thumbnail))
                case .failure(let failure): attachmentError = failure.message
                }
                continue
            }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data), let jpeg = Self.downscaledJPEG(image) else {
                attachmentError = "couldn't read that photo"
                continue
            }
            guard jpeg.count <= SessionInput.maxAttachmentBytes else {
                attachmentError = "that photo is still \(jpeg.count / 1_048_576) MB after compression — the cap is \(SessionInput.maxAttachmentBytes / 1_048_576) MB"
                continue
            }
            let name = "photo-\(UUID().uuidString.prefix(8)).jpg"
            attachments.append(PendingAttachment(name: name, mime: "image/jpeg",
                                                 data: jpeg, thumbnail: UIImage(data: jpeg)))
        }
        photoPickerItems = []
    }

    private func pasteImage() {
        guard let image = UIPasteboard.general.image else {
            attachmentError = "nothing to paste"
            return
        }
        addImage(image, prefix: "pasted")
    }

    /// A camera shot or a pasted image takes the same downscale/JPEG
    /// path as a library pick.
    private func addImage(_ image: UIImage, prefix: String) {
        guard attachments.count < SessionInput.maxAttachments,
              let jpeg = Self.downscaledJPEG(image) else {
            attachmentError = "couldn't read that photo"
            return
        }
        guard jpeg.count <= SessionInput.maxAttachmentBytes else {
            attachmentError = "that photo is still \(jpeg.count / 1_048_576) MB after compression — the cap is \(SessionInput.maxAttachmentBytes / 1_048_576) MB"
            return
        }
        let name = "\(prefix)-\(UUID().uuidString.prefix(8)).jpg"
        attachments.append(PendingAttachment(name: name, mime: "image/jpeg",
                                             data: jpeg, thumbnail: UIImage(data: jpeg)))
    }

    private static func downscaledJPEG(_ image: UIImage) -> Data? { AttachmentImage.jpeg(image) }

    /// PDFs/text ride as-is (≤ 5 MiB, same cap the Mac enforces) — no
    /// re-encoding, unlike photos.
    private func addPickedFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            guard attachments.count < SessionInput.maxAttachments else { break }
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url) else {
                attachmentError = "couldn't read \(url.lastPathComponent)"
                continue
            }
            guard data.count <= SessionInput.maxAttachmentBytes else {
                attachmentError = "\(url.lastPathComponent) is over 5 MB"
                continue
            }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            guard SessionInput.allowedAttachmentMimes.contains(mime) else {
                attachmentError = "\(url.lastPathComponent) isn't a supported file type"
                continue
            }
            attachments.append(PendingAttachment(name: url.lastPathComponent, mime: mime,
                                                 data: data, thumbnail: nil))
        }
    }

    // MARK: screenshots (user 2026-09-05: "It should be like when I
    // paste the image intentionally" — every capture stages, so the
    // words about it go with it)

    /// Screenshots taken since the phone last looked, offered above the
    /// composer: attach them all in one tap, or wave them off.
    private var screenshotOffer: some View {
        let shots = screenshots.found
        let room = SessionInput.maxAttachments - attachments.count
        return HStack(spacing: 10) {
            if let thumb = shots.last?.thumbnail {
                Image(uiImage: thumb)
                    .resizable().scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(shots.count == 1 ? "New screenshot" : "\(shots.count) new screenshots")
                    .font(.subheadline.weight(.semibold))
                Text(shots.count > room ? "The newest \(room) go" : "Attach to your reply?")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Attach") { stageFoundScreenshots() }
                .buttonStyle(.borderedProminent)
            Button { screenshots.dismiss() } label: {
                Image(systemName: "xmark").font(.caption.weight(.semibold))
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Not now")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// The camera button: the capture lands in the composer as an
    /// attachment, cursor ready, so the words about it can go with it
    /// (user 2026-09-05: "put the captured in attachment instead of
    /// send immediately as I need to describe the request").
    private func stageAppScreenshot() {
        guard let image = ScreenshotWatch.captureApp() else {
            attachmentError = "couldn't capture the screen"
            return
        }
        stage(image)
    }

    private func stage(_ image: UIImage) {
        addImage(image, prefix: "app-screenshot")
        composerFocused = true
    }

    /// A shake elsewhere in the app captured a screen and picked this
    /// session: the capture is waiting on the model.
    private func takeStagedCapture() {
        // The share extension and the shake stage for the primary Mac
        // only; another Mac's feed sharing the pid must not swallow it.
        guard macId == nil, let staged = model.stagedCapture, staged.pid == session.pid else { return }
        model.stagedCapture = nil
        stage(staged.image)
    }

    /// The offer's tap: the screenshots land in the composer as
    /// attachments, cursor ready — the same as a pasted image, so a
    /// request can be typed about them before anything goes out.
    private func stageFoundScreenshots() {
        let room = SessionInput.maxAttachments - attachments.count
        guard room > 0 else {
            attachmentError = "the reply already has \(SessionInput.maxAttachments) attachments"
            return
        }
        let images = screenshots.images(limit: room)
        guard !images.isEmpty else {
            messageResult = "couldn't read those screenshots"
            screenshots.dismiss()
            return
        }
        for image in images { addImage(image, prefix: "screenshot") }
        screenshots.dismiss()
        composerFocused = true
    }

    // MARK: continue (user 2026-09-04: "a button on ios when clicked it
    // continues the session that maybe stopped by various reasons")

    /// The Mac composes the nudge (`resume` kind); the button shows once
    /// the session isn't mid-turn and the turn ended without a final
    /// answer — a limit stop, or a tool call / sub-agent / unfinished
    /// text as the last thing in it. After a complete answer (`.result`)
    /// the composer is the way on (user 2026-09-04: "Continue button
    /// should only appear conditionally based on agent's last messages").
    static func canContinue(after item: SessionFeedItem, status: String) -> Bool {
        if item.kind == .limit { return true }
        guard item.kind == .tool || item.kind == .agent || item.kind == .assistant else { return false }
        return status != "busy"
    }

    @State private var continuing = false
    @State private var continueResult: String?

    private var continueRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    continueSession()
                } label: {
                    Label("Continue session", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(continuing || actionSending)
                if continuing { ProgressView() }
            }
            if let continueResult {
                Text(continueResult).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    private func continueSession() {
        continuing = true
        continueResult = nil
        Task {
            do {
                let reply = try await mirror.sessionInput(
                    pid: Int32(session.pid), request: .init(kind: .resume, text: ""))
                continueResult = reply.outcome == "delivered"
                    ? "asked to continue" + (reply.channel == "socket" ? "" : " (typed into the terminal)")
                    : (reply.outcome == "rejected" && reply.detail == "session ended")
                        ? "that session has ended"
                        : reply.detail.map { "\(Self.describe(reply.outcome)) — \($0)" } ?? Self.describe(reply.outcome)
            } catch MirrorTransportError.http(let status) where status == 400 {
                // An older Mac doesn't know the `resume` kind.
                continueResult = "update Infinitus on the Mac to continue sessions from the phone"
            } catch {
                continueResult = "couldn't reach the Mac"
            }
            continuing = false
            await load()
        }
    }

    private func sendMessage() {
        dictation.stop()
        // Sending mid-translation: the take goes as spoken, with the note.
        translating = false
        translateRequest = nil
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        // A non-English dictation that wasn't translated on the phone
        // goes out as spoken; under the "note" policy the session is
        // asked to read it as an English instruction so the chat stays
        // English (user 2026-09-04: "force it to take it as English").
        if let locale = dictatedLocale, !Dictation.isEnglish(locale),
           let original = dictatedOriginal, text.contains(original.trimmingCharacters(in: .whitespacesAndNewlines)),
           Dictation.policy != "none" {
            let language = Locale(identifier: "en").localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? "") ?? "another language"
            text = "(Dictated in \(language) — read it as an English instruction and reply in English.)\n" + text
        }
        sendingMessage = true
        messageResult = nil
        attachmentError = nil
        let picked = attachments.map {
            SessionInput.Attachment(name: $0.name, mime: $0.mime, data: $0.data)
        }
        // One id for both the live send and, on a transport failure, the
        // outbox item — a delivery that reached the Mac but timed out on
        // the reply must not be queued under a NEW id and delivered twice
        // (#168 fix pass).
        let request = SessionInput.Request(kind: .message, text: text,
                                           attachments: picked.isEmpty ? nil : picked,
                                           requestId: UUID().uuidString, sessionId: feed?.sessionId)
        Task {
            await send(request) { reply in
                if reply.outcome == "delivered" {
                    pendingSent.append(PendingSent(
                        text: text, images: attachments.compactMap(\.thumbnail),
                        files: attachments.filter { $0.thumbnail == nil }.map(\.name)))
                    draft = ""
                    attachments = []
                    messageResult = nil
                    dictatedOriginal = nil
                    dictatedLocale = nil
                    dictationNote = nil
                } else {
                    // The Mac says why ("attachment too large", "unsupported
                    // attachment type"…) — show it, a bare "wasn't valid"
                    // sent the user guessing (2026-09-03).
                    messageResult = reply.outcome == "rejected" && reply.detail == "session ended"
                        ? "that session has ended"
                        : reply.detail.map { "\(Self.describe(reply.outcome)) — \($0)" }
                            ?? Self.describe(reply.outcome)
                }
            } onFailure: { error in
                // An HTTP error is the Mac answering (a wrong pairing
                // token, a stale route) — not something a retry later
                // fixes, so it is shown, not queued; the draft stays put.
                if case MirrorTransportError.http(let code) = error {
                    switch code {
                    case 401: messageResult = "the Mac refused it — check the pairing token in Settings"
                    case 409: messageResult = "the Mac is still taking the last send — it lands once"
                    case 410: messageResult = "the turn was stopped before it landed"
                    default: messageResult = "the Mac refused it (HTTP \(code))"
                    }
                    return
                }
                if (try? OutboxDelivery.outbox.enqueue(
                        macKey: outboxKey, pid: Int32(session.pid), sessionId: feed?.sessionId,
                        sessionName: feed?.name ?? repoName(session.cwd), request: request)) != nil {
                    pendingSent.append(PendingSent(text: text, images: attachments.compactMap(\.thumbnail),
                                                   files: attachments.filter { $0.thumbnail == nil }.map(\.name),
                                                   queued: true))
                    draft = ""; attachments = []; messageResult = nil
                    dictatedOriginal = nil
                    dictatedLocale = nil
                    dictationNote = nil
                    reloadQueued()
                } else {
                    messageResult = "couldn't reach the Mac"
                }
            } finished: {
                sendingMessage = false
            }
        }
    }

    private func sendKey(_ key: String) { sendInput(.init(kind: .key, text: key)) }

    private func openReview() {
        actionResult = nil
        Task {
            do {
                let reply = try await mirror.checkpoints(pid: Int32(session.pid))
                guard let last = reply.checkpoints.last else {
                    reviewEmptyReason = reply.emptyReason
                    return
                }
                reviewTarget = ReviewTarget(checkpoint: last)
            } catch {
                actionResult = "couldn't reach the Mac"
            }
        }
    }

    private func sendInput(_ request: SessionInput.Request) {
        actionSending = true
        actionResult = nil
        Task {
            await send(request) { reply in
                if reply.outcome == "delivered" { deliveredTick += 1; selectedOption = nil }
                actionResult = reply.outcome == "delivered" ? nil
                    : reply.outcome == "rejected" && reply.detail == "session ended"
                        ? "that session has ended" : Self.describe(reply.outcome)
            } onFailure: { _ in
                actionResult = "couldn't reach the Mac"
            } finished: {
                actionSending = false
            }
        }
    }

    // MARK: dictation language (user 2026-09-04)

    /// The mic stopped: a non-English take is either translated on the
    /// phone or kept as spoken for the note at send time.
    private func dictationEnded() {
        let spoken = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return }
        let locale = dictation.locale
        dictatedLocale = locale
        guard !Dictation.isEnglish(locale) else { dictatedOriginal = nil; return }
        dictatedOriginal = spoken
        showOriginal = false
        switch Dictation.policy {
        case "phone":
            translating = true
            let request = DictationTranslateRequest(text: spoken, from: locale)
            translateRequest = request
            // Nothing spins forever: past the deadline the take goes out
            // as spoken with the English-reply note.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                guard translating, translateRequest == request else { return }
                translating = false
                translateRequest = nil
                dictationNote = "Translation is taking too long — sending as spoken, with a note asking for an English reply."
            }
        case "note":
            dictationNote = "Sending as spoken, with a note asking for an English reply."
        default:
            dictationNote = nil
        }
    }

    /// Words the recognizer should keep verbatim: the session's own
    /// names and the tools it has been using.
    private func dictationHints() -> [String] {
        var words: [String] = []
        if let name = feed?.name { words.append(name) }
        words.append(repoName(session.cwd))
        if let branch = model.progress(macId: macId, pid: session.pid)?.gitBranch { words.append(branch) }
        if let modelName = model.progress(macId: macId, pid: session.pid)?.model { words.append(modelName) }
        for item in (feed?.items ?? []).suffix(40) {
            if let tool = item.toolName { words.append(tool) }
        }
        words += ["Claude", "commit", "PR", "merge", "rebase", "Swift", "SwiftUI", "Xcode", "iOS", "macOS"]
        var seen = Set<String>()
        return words.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    @AppStorage(Dictation.localeKey) private var dictationLocaleID = ""

    private var languageMenu: some View {
        let current = dictationLocaleID
        let quick = [Locale.current, Locale(identifier: "en-US"), Locale(identifier: "vi-VN")]
        return Group {
            Button { dictationLocaleID = "" } label: {
                Label("Phone language (\(Dictation.displayName(Locale.current)))",
                      systemImage: current.isEmpty ? "checkmark" : "")
            }
            ForEach(quick.dropFirst(), id: \.identifier) { locale in
                Button { dictationLocaleID = locale.identifier } label: {
                    Label(Dictation.displayName(locale), systemImage: current == locale.identifier ? "checkmark" : "")
                }
            }
            Text("More languages and what happens to non-English dictation: Settings → Dictation")
        }
    }

    private func send(_ request: SessionInput.Request, onReply: @escaping (SessionInput.Reply) -> Void,
                      onFailure: @escaping (Error) -> Void, finished: @escaping () -> Void) async {
        do {
            let reply = try await mirror.sessionInput(pid: Int32(session.pid),
                                                                         request: request)
            onReply(reply)
        } catch {
            onFailure(error)
        }
        finished()
        await load()
    }

    static func describe(_ outcome: String) -> String {
        switch outcome {
        case "running": return "session is mid-turn — try again when it's waiting"
        case "noSurface": return "this session has nowhere to receive input right now"
        case "noChannel": return "this session can't receive messages right now"
        case "captured": return "a menu is on screen — try again"
        case "rejected": return "that wasn't a valid reply"
        default: return outcome
        }
    }

    /// Another session's message, the way the CLI shows it: one
    /// "Message from @<sender>" line with a short preview, the full text
    /// a tap away (user 2026-09-04: "same on ios but indicative").
    private func repoName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

/// #168: the message a `sendMessage` couldn't reach the Mac with, waiting
/// on disk for `OutboxDelivery.flush()` — edit it back into the composer,
/// or give up on it.
private struct QueuedCard: View {
    let item: OutboxItem
    let onEdit: () -> Void
    let onDiscard: () -> Void

    private var status: String {
        switch item.state {
        case .queued, .inFlight:
            let tries = item.attempts >= 3 ? " · \(item.attempts) tries" : ""
            return "queued for when the Mac is back · \(item.updatedAt.formatted(.relative(presentation: .named)))\(tries)"
        case .refused(let why): return "the Mac refused it — \(why)"
        case .ended: return "that session has ended"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(status, systemImage: "tray.and.arrow.up").font(.caption).foregroundStyle(.secondary)
            Text(item.request.text).font(.subheadline).lineLimit(3)
            HStack {
                if case .ended = item.state {} else { Button("Edit", action: onEdit) }
                Button("Discard", role: .destructive, action: onDiscard)
            }
            .font(.caption)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }
}
