import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import InfinitusCore
import InfinitusUI

/// A session as T3 Code's mobile thread (T3 clone C-1, #223 §5): native
/// title + subtitle header, the conversation over `/timeline`, and the
/// capsule composer. The feed is `T3TimelineRows.derive` over the
/// follower's timeline: messages, work rows and live activity, tool
/// groups behind a summary toggle, settled turns behind "Worked for …".
struct T3ThreadScreen: View {
    @ObservedObject var model: MirrorModel
    let session: SessionDetail
    var macId: String? = nil

    @StateObject private var follower: TimelineFollower
    @Environment(\.t3) private var t3
    @State private var draft = ""
    /// The session's slash commands, fetched once the first `/` is typed;
    /// nil until then, empty when the Mac had none (or could not be asked).
    @State private var commands: [SlashCommand]?
    @State private var commandsTask: Task<Void, Never>?
    @State private var composerFocused = false
    @State private var sending = false
    @State private var note: String?
    @State private var attachments: [ComposerAttachment] = []
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showCamera = false
    @State private var showSettings = false
    @State private var showGit = false
    /// T3's live-follow latch (`T3LiveFollow`): new rows scroll the feed
    /// only while this holds. `userScrolling` spans a drag through its
    /// momentum; `atEnd` is the last geometry's answer; `foldPending`
    /// marks a fold toggle whose layout has yet to settle.
    @State private var following = true
    @State private var userScrolling = false
    @State private var atEnd = true
    @State private var foldPending = false
    /// Bumped to scroll to the end from outside the reader (the button,
    /// a send).
    @State private var scrollToEndRequest = 0
    /// Within this many points of the bottom counts as at the end.
    private static let endThreshold: CGFloat = 24

    init(model: MirrorModel, session: SessionDetail, macId: String? = nil) {
        self.model = model
        self.session = session
        self.macId = macId
        _follower = StateObject(wrappedValue: TimelineFollower(pid: Int32(session.pid), mirror: model.mirror(for: macId)))
    }

    /// The render harness's screen: a fixture follower, no polling.
    init(model: MirrorModel, session: SessionDetail, fixture: TimelineFollower.State) {
        self.model = model
        self.session = session
        _follower = StateObject(wrappedValue: TimelineFollower(fixture: fixture))
    }

    /// Which turn folds and work groups the user opened (`expandedTurnIds`,
    /// `expandedWorkGroupIds` in T3's timeline state).
    @State private var expandedTurnIds: Set<String> = []
    @State private var expandedWorkGroupIds: Set<String> = []

    /// Rows and cards derived once per timeline and expansion, not per
    /// body pass (#380).
    @State private var memo = T3ThreadMemo()
    private var derived: T3ThreadMemo {
        memo.update(state: follower.state, expandedTurnIds: expandedTurnIds, expandedWorkGroupIds: expandedWorkGroupIds)
    }
    private var pending: T3Pending.Live { derived.pending }
    private var rows: [T3TimelineRows.Row] { derived.rows }

    /// `T3TimelineRows.Input` over the follower's state: the live prompt's
    /// activities stay out (they show as a card over the composer), the
    /// facts' latest turn and the running turn steer the folds.
    static func timelineInput(state: TimelineFollower.State, hiddenActivityIds: Set<String>,
                              expandedTurnIds: Set<String>, expandedWorkGroupIds: Set<String>) -> T3TimelineRows.Input {
        var timeline = state.timeline
        timeline.activities.removeAll { hiddenActivityIds.contains($0.id) }
        let running = timeline.turns.first { $0.state == .running }
        let latest = state.facts?.latestTurn
        return T3TimelineRows.Input(
            entries: T3TimelineEntry.entries(from: timeline),
            latestTurn: latest.map { .init(turnId: $0.id, state: $0.state, startedAt: $0.startedAt, completedAt: $0.completedAt) },
            runningTurnId: running?.id,
            expandedTurnIds: expandedTurnIds, expandedWorkGroupIds: expandedWorkGroupIds,
            isWorking: state.facts?.status == .running,
            activeTurnStartedAt: running?.startedAt ?? running?.requestedAt)
    }

    /// Facts freeze at their last value once the session exits, so a
    /// running status alone can't mean Working.
    private var working: Bool { follower.state.facts?.status == .running && !follower.ended }

    var body: some View {
        ZStack {
            t3.mobile.screen.color.ignoresSafeArea()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in feedRow(row) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                .modifier(FollowTracking(atEnd: $atEnd, userScrolling: $userScrolling, following: $following,
                                         foldPending: $foldPending, threshold: Self.endThreshold,
                                         scrollToEnd: { proxy.scrollTo("end", anchor: .bottom) }))
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: rows.last?.id) { _, _ in
                    guard following else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onChange(of: follower.state.synchronized) { _, now in
                    guard now else { return }
                    following = T3LiveFollow.resolve(following, .reset)
                    proxy.scrollTo("end", anchor: .bottom)
                }
                .onChange(of: scrollToEndRequest) { _, _ in
                    following = T3LiveFollow.resolve(following, .reset)
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                }
                // A fold above the end pushes content past it; whether that
                // left the reader at the end is known once geometry settles.
                .onChange(of: expandedTurnIds) { _, _ in foldPending = true }
                .onChange(of: expandedWorkGroupIds) { _, _ in foldPending = true }
            }
        }
        // The bottom stack is a safe-area inset, so the feed always clears
        // it — a card and the Working pill can be most of the screen.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                // Same copy as the Mac's thread (#400); the rows stay put.
                if follower.ended { T3ErrorBanner("This session has ended.") }
                if working || !following {
                    HStack(spacing: 16) {
                        if working { workingControl }
                        if !following { scrollToEndButton }
                    }
                }
                if let approval = pending.approval, !follower.ended {
                    T3ApprovalCard(approval: approval, sending: sending,
                                   allowOnce: { send(.init(kind: .key, text: "1")) },
                                   allowSession: { send(.init(kind: .approve, text: approval.sessionApproval)) },
                                   decline: { send(.init(kind: .key, text: "3")) })
                } else if let input = pending.userInput, !follower.ended {
                    T3UserInputCard(input: input, sending: sending) { submission in
                        switch submission {
                        case .answers(let text): send(.init(kind: .answers, text: text))
                        case .key(let key): send(.init(kind: .key, text: key))
                        }
                    }
                }
                composer
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        // T3's iOS header (`ios-thread.png`) drawn in the content — the
        // system bar squeezes a leading title into a glass pill on iOS 26
        // — with swipe-back kept, as the feed does.
        .toolbar(.hidden, for: .navigationBar)
        .background(InteractivePopGesture())
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            follower.start()
            LeaseReporter.shared.acquire(.session(Int32(session.pid)), on: .mac(macId))
            // `infinitus://t3/git|thread-settings` (the parity capture) lands on
            // the thread with that sheet up.
            switch model.requestedThreadSheet {
            case "git": showGit = true
            case "thread-settings": showSettings = true
            default: break
            }
            model.requestedThreadSheet = nil
        }
        .onDisappear {
            follower.stop()
            LeaseReporter.shared.release(.session(Int32(session.pid)), on: .mac(macId))
        }
        // A PhotosPicker inside a Menu never presents (the menu dismisses
        // first) — same modifier pattern as the feed's composer.
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItems,
                      maxSelectionCount: ComposerAttachments.capCount, matching: .any(of: [.images, .videos]))
        .onChange(of: photoPickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await addPickedPhotos(items) }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: Self.allowedFileTypes,
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                guard let data = try? Data(contentsOf: url) else { note = "couldn't read \(url.lastPathComponent)"; continue }
                stage(ComposerAttachments.file(named: url.lastPathComponent, data: data))
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCapture { image in stage(ComposerAttachments.image(image, prefix: "camera")) }
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showSettings) {
            T3ThreadSettingsSheet(model: model, session: session, macId: macId, facts: follower.state.facts).t3(platform: .mobile)
        }
        .sheet(isPresented: $showGit) {
            T3GitSheet(branch: model.progress(macId: macId, pid: session.pid)?.gitBranch).t3(platform: .mobile)
        }
    }

    private static let allowedFileTypes: [UTType] = [
        .png, .jpeg, .heic, .gif, .pdf, .plainText, UTType(mimeType: "image/webp"),
    ].compactMap { $0 }

    /// Title and `project · Mac` subtitle lead; the terminal and files
    /// pills (E/F's, inert here) share a glass capsule; the git gear is
    /// its own.
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(T3Font.mobile(.xl, .bold)).lineLimit(1)
                    .foregroundStyle(t3.mobile.foreground.color)
                Text(subtitle).font(T3Font.mobile(.sm)).lineLimit(1)
                    .foregroundStyle(t3.mobile.foregroundMuted.color)
            }
            Spacer(minLength: 8)
            T3GlassSurface {
                HStack(spacing: 0) {
                    Image(systemName: "terminal").frame(width: 60, height: 44).accessibilityLabel("Terminal (soon)")
                    Image(systemName: "folder").frame(width: 60, height: 44).accessibilityLabel("Files (soon)")
                }
                .font(.system(size: 18))
                .foregroundStyle(t3.mobile.iconSubtle.color)
            }
            .clipShape(Capsule())
            Button { showGit = true } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 20))
                    .foregroundStyle(t3.mobile.icon.color)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 8, weight: .bold))
                            .foregroundStyle(t3.mobile.icon.color).offset(x: 4, y: 3)
                    }
                    .frame(width: 48, height: 48)
                    .background(t3.mobile.subtleStrong.color, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open git controls")
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
        .background(t3.mobile.screen.color)
    }

    private var title: String {
        let p = model.progress(macId: macId, pid: session.pid)
        return SessionNaming.displayName(name: p?.name, autoName: p?.autoName, cwd: session.cwd)
    }

    private var subtitle: String {
        let repo = URL(fileURLWithPath: session.cwd).lastPathComponent
        let mac = model.macName(macId) ?? model.snapshot?.machineName
        if follower.ended { return "Session ended" }
        if follower.unreachable { return "Reconnecting…" }
        return mac.map { "\(repo) · \($0)" } ?? repo
    }

    // MARK: feed rows (`MessagesTimeline.tsx` variants)

    @ViewBuilder private func feedRow(_ row: T3TimelineRows.Row) -> some View {
        switch row {
        case let .message(_, _, message, _, showAssistantMeta, _, _, _, _):
            T3MessageRow(message: message, showMeta: message.role == .user || showAssistantMeta)
        case let .assistantMeta(_, _, message, _, _):
            T3MessageMeta(message: message).padding(.horizontal, 4).padding(.bottom, 20)
        case let .work(_, _, groupedEntries, _, displayLabel):
            if let entry = groupedEntries.first {
                T3WorkRow(entry: entry, label: displayLabel ?? T3WorkLog.displayLabel(entry, workspaceRoot: session.cwd))
            }
        case let .workLive(_, _, entry, _, _, _, active):
            T3WorkRow(entry: entry, label: T3WorkLog.liveLabel(entry, workspaceRoot: session.cwd, active: active), live: active)
        case let .workToggle(_, _, _, groupId, hiddenCount, expanded, summary, _, _, _, hasFailure):
            T3FoldRow(label: hiddenCount > 0 && !expanded ? "\(summary) · \(hiddenCount) more" : summary,
                      expanded: expanded, failure: hasFailure) {
                if expanded { expandedWorkGroupIds.remove(groupId) } else { expandedWorkGroupIds.insert(groupId) }
            }
        case let .turnFold(_, _, turnId, label, expanded):
            T3FoldRow(label: label, expanded: expanded, failure: false) {
                if expanded { expandedTurnIds.remove(turnId) } else { expandedTurnIds.insert(turnId) }
            }
        case let .contextCompaction(_, _, label):
            Text(label).font(T3Font.mobile(.xs)).foregroundStyle(t3.mobile.foregroundTertiary.color)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
        case let .proposedPlan(_, _, plan):
            VStack(alignment: .leading, spacing: 8) {
                T3CardEyebrow(text: "Proposed plan")
                MarkdownText(text: plan.planMarkdown).markdownStyle(.t3(t3.mobile))
            }
            .padding(16)
            .background(t3.mobile.cardAlt.color, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(t3.mobile.border.color, lineWidth: 1))
            .padding(.bottom, 20)
        case .working, .thinking:
            HStack(spacing: 8) {
                T3Spinner(size: 12)
                Text(row.kind == "thinking" ? "Thinking" : "Working").font(T3Font.mobile(.sm))
                    .foregroundStyle(t3.mobile.foregroundMuted.color)
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: floating working control (T3 `floating-working-control.tsx`)

    private var workingControl: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Working").font(T3Font.mobile(.xs, .medium))
            if let since = follower.state.facts?.latestTurn?.startedAt ?? follower.state.facts?.latestTurn?.requestedAt {
                Text(since, style: .timer).font(T3Font.mobile(.xs, .medium)).monospacedDigit()
                    .foregroundStyle(t3.mobile.foregroundMuted.color)
            }
            Spacer(minLength: 0)
            Button { send(.init(kind: .key, text: "esc")) } label: {
                Image(systemName: "stop.fill").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(t3.mobile.dangerForeground.color)
                    .frame(width: 28, height: 28)
                    .background(t3.mobile.danger.color, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(t3.mobile.foreground.color)
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .frame(height: 38.5)
        .background(t3.mobile.card.color, in: Capsule())
        .overlay(Capsule().stroke(t3.mobile.border.color, lineWidth: 1))
    }

    /// `ScrollToEndButton` beside the pill (`floating-working-control.tsx`:
    /// `h-11 w-11 border border-border bg-card shadow-md`), shown while
    /// follow is broken; a tap re-arms it.
    private var scrollToEndButton: some View {
        Button { scrollToEndRequest += 1 } label: {
            Image(systemName: "chevron.down").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(t3.mobile.foreground.color)
                .frame(width: 44, height: 44)
                .background(t3.mobile.card.color, in: Circle())
                .overlay(Circle().stroke(t3.mobile.border.color, lineWidth: 1))
                .shadow(color: .black.opacity(0.1), radius: 6, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scroll to end")
    }

    // MARK: composer (T3 `ThreadComposer.tsx`)

    /// Collapsed: one capsule row — attach, the single-line editor, send.
    /// Expanded (focused): the strip above a taller editor, the buttons
    /// on a row beneath, T3's 14 pt inset.
    private var expanded: Bool { composerFocused }

    private var slashTrigger: T3SlashTrigger.Match? { T3SlashTrigger.detect(draft) }

    /// `ComposerCommandPopover` docked 8 pt above the composer while a `/`
    /// trigger is live (`ThreadComposer.tsx`: `bottom-full mb-2`); drawn as
    /// an overlay so the composer keeps its place.
    @ViewBuilder private func commandPopover(_ match: T3SlashTrigger.Match) -> some View {
        T3CommandPopover(items: SlashCommands.filter(commands ?? [], query: match.query),
                         loading: commands == nil) { command in
            draft = T3SlashTrigger.apply(command, to: draft, match: match)
        }
        .onAppear { loadCommands() }
    }

    private func loadCommands() {
        guard commands == nil, commandsTask == nil else { return }
        commandsTask = Task {
            let found = try? await model.mirror(for: macId).commands(pid: Int32(session.pid))
            commands = found ?? []
            commandsTask = nil
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if expanded {
                    VStack(alignment: .leading, spacing: 0) {
                        if !attachments.isEmpty { attachmentStrip.padding(.horizontal, 14).padding(.bottom, 10) }
                        editor.padding(.horizontal, 14)
                        HStack(spacing: 4) {
                            attachButton
                            Button { showSettings = true } label: {
                                Image(systemName: "slider.horizontal.3").font(.system(size: 16))
                                    .foregroundStyle(t3.mobile.icon.color)
                                    .frame(width: 44, height: 44).contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Thread settings")
                            Spacer(minLength: 0)
                            sendButton
                        }
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 6)
                } else {
                    HStack(spacing: 4) {
                        attachButton
                        if !attachments.isEmpty { attachmentCount }
                        editor.padding(.horizontal, 4)
                        sendButton
                    }
                    // 44 pt buttons in a 48 pt capsule (`ios-thread.png`).
                    .padding(2)
                }
            }
            .background(t3.mobile.input.color, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(t3.mobile.inputBorder.color, lineWidth: 1))
            .shadow(color: t3.mobile.drawerShadow.color, radius: 14, y: 6)
            .overlay(alignment: .top) {
                if let match = slashTrigger {
                    commandPopover(match).alignmentGuide(.top) { $0[.bottom] + 8 }
                }
            }
            if let note {
                Text(note).font(T3Font.mobile(.xxs)).foregroundStyle(t3.mobile.dangerForeground.color)
                    .padding(.leading, 14)
            }
        }
        .animation(.easeOut(duration: 0.18), value: expanded)
    }

    private var editor: some View {
        T3ComposerEditor(text: $draft, isFocused: $composerFocused,
                         placeholder: "Ask the repo agent, or run a command…", expanded: expanded,
                         textColor: t3.mobile.foreground.color, placeholderColor: t3.mobile.placeholder.color) { image in
            stage(ComposerAttachments.image(image, prefix: "pasted"))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// T3's `ComposerAttachmentButton`: `plus` in a 44 pt round hit
    /// target, a menu of sources. Camera and paste are the phone's own
    /// (user 2026-09-03), kept alongside T3's two.
    private var attachButton: some View {
        Menu {
            Button { showPhotoPicker = true } label: { Label("Photo Library", systemImage: "photo") }
            if CameraCapture.isAvailable {
                Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
            }
            Button { showFileImporter = true } label: { Label("Choose Files", systemImage: "folder") }
            if UIPasteboard.general.hasImages {
                Button {
                    guard let image = UIPasteboard.general.image else { note = "nothing to paste"; return }
                    stage(ComposerAttachments.image(image, prefix: "pasted"))
                } label: { Label("Paste Image", systemImage: "doc.on.clipboard") }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 20, weight: .medium))
                .foregroundStyle(t3.mobile.icon.color)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .disabled(sending || attachments.count >= ComposerAttachments.capCount)
        .accessibilityLabel("Attach")
    }

    /// Collapsed rows show the count in a 30 pt square, not the strip.
    private var attachmentCount: some View {
        Text("\(attachments.count)")
            .font(T3Font.mobile(.xxxs, .bold))
            .foregroundStyle(t3.mobile.foregroundMuted.color)
            .frame(width: 30, height: 30)
            .background(t3.mobile.subtleStrong.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// T3's `ComposerAttachmentStrip`: 64 pt tiles, r12, a 22 pt remove
    /// button over the top-right corner.
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let thumbnail = attachment.thumbnail {
                                Image(uiImage: thumbnail).resizable().scaledToFill()
                                    .overlay {
                                        if attachment.mime.hasPrefix("video/") {
                                            Image(systemName: "play.circle.fill").font(.system(size: 18))
                                                .foregroundStyle(.white, .black.opacity(0.5))
                                        }
                                    }
                            } else {
                                VStack(spacing: 2) {
                                    Image(systemName: attachment.mime.hasPrefix("video/") ? "video.fill" : "doc.fill").font(.system(size: 18))
                                        .foregroundStyle(t3.mobile.iconMuted.color)
                                    Text(attachment.name).font(T3Font.mobile(.xxxs)).lineLimit(1)
                                        .foregroundStyle(t3.mobile.foreground.color)
                                }
                                .padding(.horizontal, 4)
                            }
                        }
                        .frame(width: 64, height: 64)
                        .background(t3.mobile.subtle.color)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Button { attachments.removeAll { $0.id == attachment.id } } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Color.black.opacity(0.55), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -4)
                        .accessibilityLabel("Remove \(attachment.name)")
                    }
                }
            }
            .padding(.top, 4).padding(.trailing, 4)
        }
    }

    private var canSend: Bool {
        !sending && !follower.ended && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private var sendButton: some View {
        Button {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            let picked = attachments.map(\.wire)
            send(.init(kind: .message, text: text, attachments: picked.isEmpty ? nil : picked,
                       requestId: UUID().uuidString)) {
                draft = ""
                attachments = []
                // Sending re-arms follow (T3 resets the latch on submit).
                scrollToEndRequest += 1
            }
        } label: {
            Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold))
                .foregroundStyle(t3.mobile.primaryForeground.color)
                .frame(width: 36, height: 36)
                .background(canSend ? t3.mobile.primary.color : t3.mobile.subtle.color, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
    }

    private func stage(_ staged: Result<ComposerAttachment, ComposerAttachments.Failure>) {
        guard attachments.count < ComposerAttachments.capCount else { note = ComposerAttachments.Failure.full.message; return }
        switch staged {
        case .success(let attachment): attachments.append(attachment); note = nil
        case .failure(let failure): note = failure.message
        }
    }

    private func addPickedPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if PickedVideo.isVideo(item) {
                stage(ComposerAttachments.video(await PickedVideo.load(item)))
            } else {
                stage(ComposerAttachments.photo(try? await item.loadTransferable(type: Data.self)))
            }
        }
        photoPickerItems = []
    }

    private func send(_ request: SessionInput.Request, delivered: @escaping () -> Void = {}) {
        sending = true
        note = nil
        Task {
            defer { sending = false }
            do {
                let reply = try await model.mirror(for: macId).sessionInput(pid: Int32(session.pid), request: request)
                if reply.outcome == "delivered" {
                    delivered()
                } else if reply.outcome == "rejected", reply.detail == "session ended" {
                    note = "that session has ended"
                } else {
                    note = SessionFeedScreen.describe(reply.outcome)
                }
            } catch {
                note = "couldn't reach the Mac"
            }
        }
    }
}

/// One message (T3 `ThreadFeed.tsx` `MessageRow`): the user's in the blue
/// bubble, trailing; the assistant's as plain markdown; a timestamp under
/// each.
struct T3MessageRow: View {
    let message: T3ChatMessage
    /// The assistant's copy + time row; the reducer folds it into a
    /// following `assistantMeta` row when tool calls trail the text.
    var showMeta = true
    @Environment(\.t3) private var t3

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 0) {
                    // The user's text is markdown too (skill bodies, pasted
                    // notes): T3's `user` run styles, everything in the
                    // bubble's foreground.
                    MarkdownText(text: message.text)
                        .markdownStyle(.t3(t3.mobile, user: true))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(t3.mobile.userBubble.color, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    HStack(spacing: 4) { meta.stamp; meta.copyButton }
                        .padding(.top, 4).padding(.trailing, 2)
                }
            }
            .padding(.bottom, 20)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                MarkdownText(text: message.text)
                    .markdownStyle(.t3(t3.mobile))
                if showMeta { meta.padding(.top, 4) }
            }
            // T3's assistant row sits 4 pt inside the feed's 16 (`px-1`).
            .padding(.horizontal, 4)
            .padding(.bottom, showMeta ? 20 : 8)
        }
    }

    private var meta: T3MessageMeta { T3MessageMeta(message: message) }
}

/// The assistant meta row (`assistant-meta`): copy, then the time.
struct T3MessageMeta: View {
    let message: T3ChatMessage
    @Environment(\.t3) private var t3

    var body: some View { HStack(spacing: 4) { copyButton; stamp } }

    /// T3's `mt-1 gap-1` row: `text-xs font-t3-medium tabular-nums`.
    var stamp: some View {
        Text(message.createdAt.formatted(date: .omitted, time: .shortened))
            .font(T3Font.mobile(.xs, .medium)).monospacedDigit()
            .foregroundStyle(t3.mobile.foregroundMuted.color)
    }

    /// `CopyTextButton`: a 28 pt target around a 14 pt glyph.
    var copyButton: some View {
        Button { UIPasteboard.general.string = message.text } label: {
            Image(systemName: "doc.on.doc").font(.system(size: 14))
                .foregroundStyle(t3.mobile.iconSubtle.color)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy message")
    }
}

/// One work entry as a single line (`work` / `work-live`): the tool glyph,
/// the reducer's display label, a spinner while live.
struct T3WorkRow: View {
    let entry: T3WorkLogEntry
    let label: String
    var live = false
    @Environment(\.t3) private var t3

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if live {
                // A non-text view's baseline is its bottom; lift the spinner
                // so it sits on the label's first line.
                T3Spinner(size: 12).frame(width: 16)
                    .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 2 }
            } else {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 16)
            }
            Text(label)
                .font(T3Font.mobile(.sm))
                .foregroundStyle(t3.mobile.foregroundMuted.color)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
    }

    private var symbol: String {
        if T3WorkLog.indicatesFailure(entry) { return "exclamationmark.triangle" }
        switch entry.tone {
        case .tool: return T3WorkLog.indicatesSuccess(entry) ? "checkmark" : "wrench"
        case .thinking: return "brain"
        case .error: return "exclamationmark.triangle"
        case .info: return "info.circle"
        }
    }

    private var tint: Color {
        if entry.tone == .error || T3WorkLog.indicatesFailure(entry) { return t3.mobile.dangerForeground.color }
        return t3.mobile.iconMuted.color
    }
}

/// `turn-fold` and `work-toggle`: "Worked for 2m 14s" / the group summary
/// with a chevron, opening the folded rows in place.
struct T3FoldRow: View {
    let label: String
    let expanded: Bool
    let failure: Bool
    let toggle: () -> Void
    @Environment(\.t3) private var t3

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(t3.mobile.iconMuted.color)
                    .frame(width: 16)
                Text(label).font(T3Font.mobile(.sm))
                    .foregroundStyle(failure ? t3.mobile.dangerForeground.color : t3.mobile.foregroundMuted.color)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "Collapse \(label)" : "Expand \(label)")
    }
}


/// The feed's scroll tracking for `T3LiveFollow`. iOS 18 reports geometry
/// and phases; there the bottom anchor only sets the initial offset and the
/// alignment of short content, and following is this modifier's job (a
/// size-change anchor would re-pin the reader on every streamed chunk).
/// iOS 17 keeps the plain bottom anchor and always follows.
private struct FollowTracking: ViewModifier {
    @Binding var atEnd: Bool
    @Binding var userScrolling: Bool
    @Binding var following: Bool
    @Binding var foldPending: Bool
    let threshold: CGFloat
    let scrollToEnd: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .alignment)
                .onScrollGeometryChange(for: Bool.self) { g in
                    g.visibleRect.maxY >= g.contentSize.height - threshold
                } action: { _, isAtEnd in
                    atEnd = isAtEnd
                    if foldPending {
                        foldPending = false
                        following = T3LiveFollow.resolve(following, .disclosureSettled(isAtEnd: isAtEnd, sessionActive: userScrolling))
                    } else {
                        following = T3LiveFollow.resolve(following, .scroll(isAtEnd: isAtEnd, sessionActive: userScrolling))
                    }
                }
                // A streamed chunk grows the last row without a new row id:
                // follow the height, not just the ids.
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { old, new in
                    if new > old, following, !userScrolling { scrollToEnd() }
                }
                .onScrollPhaseChange { _, phase in
                    switch phase {
                    case .interacting:
                        guard !userScrolling else { return }
                        userScrolling = true
                        following = T3LiveFollow.resolve(following, .userScrollBegin)
                    case .idle:
                        guard userScrolling else { return }
                        userScrolling = false
                        following = T3LiveFollow.resolve(following, .userScrollEnd(isAtEnd: atEnd, sessionActive: true))
                    default:
                        break
                    }
                }
        } else {
            content.defaultScrollAnchor(.bottom)
        }
    }
}
