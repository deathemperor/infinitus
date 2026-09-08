import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import InfinitusCore
import InfinitusUI

/// A session as T3 Code's mobile thread (T3 clone C-1, #223 §5): native
/// title + subtitle header, the conversation over `/timeline`, and the
/// capsule composer. Deliberately thin — one flat row per message and
/// per activity, no work groups or turn folds; those arrive with
/// `T3TimelineRows` (A's PR 4) and replace `rows(of:)` here.
struct T3ThreadScreen: View {
    @ObservedObject var model: MirrorModel
    let session: SessionDetail
    var macId: String? = nil

    @StateObject private var follower: TimelineFollower
    @Environment(\.t3) private var t3
    @State private var draft = ""
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

    /// The feed's order without its folds: each turn's user message, its
    /// activities by sequence, then its assistant message; anything a
    /// turn does not claim follows by time.
    enum Row: Identifiable, Equatable {
        case message(SessionTimeline.Message)
        case work(SessionTimeline.Activity)
        var id: String {
            switch self {
            case .message(let m): return "m:" + m.id
            case .work(let a): return "a:" + a.id
            }
        }
    }

    static func rows(of timeline: SessionTimeline) -> [Row] {
        var rows: [Row] = []
        var claimed = Set<String>()
        for turn in timeline.turns {
            let messages = timeline.messages.filter { $0.turnId == turn.id }
            for m in messages where m.role == .user { rows.append(.message(m)); claimed.insert(m.id) }
            for a in timeline.activities.filter({ $0.turnId == turn.id }).sorted(by: { $0.sequence < $1.sequence }) {
                rows.append(.work(a)); claimed.insert(a.id)
            }
            for m in messages where m.role == .assistant { rows.append(.message(m)); claimed.insert(m.id) }
        }
        let loose: [(Date, Row)] = timeline.messages.filter { !claimed.contains($0.id) }.map { ($0.createdAt, .message($0)) }
            + timeline.activities.filter { !claimed.contains($0.id) }.map { ($0.createdAt, .work($0)) }
        rows += loose.sorted { $0.0 < $1.0 }.map(\.1)
        return rows
    }

    private var pending: T3Pending.Live { T3Pending.derive(follower.state.timeline) }
    /// The live prompt shows as a card over the composer, not a feed line.
    private var rows: [Row] {
        let hidden = pending.activityIds
        return Self.rows(of: follower.state.timeline).filter {
            if case .work(let a) = $0 { return !hidden.contains(a.id) }
            return true
        }
    }
    private var working: Bool { follower.state.facts?.status == .running }

    var body: some View {
        ZStack {
            t3.mobile.screen.color.ignoresSafeArea()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            switch row {
                            case .message(let m): T3MessageRow(message: m)
                            case .work(let a): T3WorkRow(activity: a)
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
                // The conversation sits at the bottom, as a chat does.
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: rows.last?.id) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onChange(of: follower.state.synchronized) { _, now in
                    if now { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        // The bottom stack is a safe-area inset, so the feed always clears
        // it — a card and the Working pill can be most of the screen.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                if working { workingControl }
                if let approval = pending.approval {
                    T3ApprovalCard(approval: approval, sending: sending,
                                   allowOnce: { send(.init(kind: .key, text: "1")) },
                                   allowSession: { send(.init(kind: .approve, text: approval.sessionApproval)) },
                                   decline: { send(.init(kind: .key, text: "3")) })
                } else if let input = pending.userInput {
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
            .padding(.bottom, 8)
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
            // `infinitus://t3/git|settings` (the parity capture) lands on
            // the thread with that sheet up.
            switch model.requestedThreadSheet {
            case "git": showGit = true
            case "settings": showSettings = true
            default: break
            }
            model.requestedThreadSheet = nil
        }
        .onDisappear { follower.stop() }
        // A PhotosPicker inside a Menu never presents (the menu dismisses
        // first) — same modifier pattern as the feed's composer.
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItems,
                      maxSelectionCount: ComposerAttachments.capCount, matching: .images)
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
        if follower.unreachable { return "Reconnecting…" }
        return mac.map { "\(repo) · \($0)" } ?? repo
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

    // MARK: composer (T3 `ThreadComposer.tsx`)

    /// Collapsed: one capsule row — attach, the single-line editor, send.
    /// Expanded (focused): the strip above a taller editor, the buttons
    /// on a row beneath, T3's 14 pt inset.
    private var expanded: Bool { composerFocused }

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
                    .padding(6)
                }
            }
            .background(t3.mobile.input.color, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(t3.mobile.inputBorder.color, lineWidth: 1))
            .shadow(color: t3.mobile.drawerShadow.color, radius: 14, y: 6)
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
                            } else {
                                VStack(spacing: 2) {
                                    Image(systemName: "doc.fill").font(.system(size: 18))
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
        !sending && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private var sendButton: some View {
        Button {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            let picked = attachments.map(\.wire)
            send(.init(kind: .message, text: text, attachments: picked.isEmpty ? nil : picked,
                       requestId: UUID().uuidString)) {
                draft = ""
                attachments = []
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
            stage(ComposerAttachments.photo(try? await item.loadTransferable(type: Data.self)))
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
    let message: SessionTimeline.Message
    @Environment(\.t3) private var t3

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(message.text)
                        .font(T3Font.mobile(.base))
                        .foregroundStyle(t3.mobile.userBubbleForeground.color)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(t3.mobile.userBubble.color, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    HStack(spacing: 4) { stamp; copyButton }
                        .padding(.top, 4).padding(.trailing, 2)
                }
            }
            .padding(.bottom, 20)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                MarkdownText(text: message.text)
                    .font(T3Font.mobile(.base))
                    .foregroundStyle(t3.mobile.foreground.color)
                HStack(spacing: 4) { copyButton; stamp }
                    .padding(.top, 4)
            }
            .padding(.bottom, 20)
        }
    }

    /// T3's `mt-1 gap-1` row: `text-xs font-t3-medium tabular-nums`.
    private var stamp: some View {
        Text(message.createdAt.formatted(date: .omitted, time: .shortened))
            .font(T3Font.mobile(.xs, .medium)).monospacedDigit()
            .foregroundStyle(t3.mobile.foregroundMuted.color)
    }

    /// `CopyTextButton`: a 28 pt target around a 14 pt glyph.
    private var copyButton: some View {
        Button { UIPasteboard.general.string = message.text } label: {
            Image(systemName: "doc.on.doc").font(.system(size: 14))
                .foregroundStyle(t3.mobile.iconSubtle.color)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy message")
    }
}

/// One activity as a single line — tool, note, or a pending approval /
/// question card's summary. Actions on those cards come with the rows
/// reducer (#330's answers included).
struct T3WorkRow: View {
    let activity: SessionTimeline.Activity
    @Environment(\.t3) private var t3

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(activity.summary)
                .font(T3Font.mobile(.sm))
                .foregroundStyle(activity.tone == .approval ? t3.mobile.foreground.color : t3.mobile.foregroundMuted.color)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
        .padding(.bottom, activity.tone == .approval ? 8 : 0)
    }

    private var symbol: String {
        switch activity.tone {
        case .tool: return "wrench"
        case .approval: return activity.kind == "user-input.requested" ? "questionmark.bubble" : "hand.raised"
        case .error: return "exclamationmark.triangle"
        case .info: return "info.circle"
        }
    }

    private var tint: Color {
        switch activity.tone {
        case .error: return t3.mobile.dangerForeground.color
        case .approval: return t3.mobile.primary.color
        default: return t3.mobile.iconMuted.color
        }
    }
}
