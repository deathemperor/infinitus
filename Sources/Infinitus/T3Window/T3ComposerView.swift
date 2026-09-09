import SwiftUI
import AppKit
import UniformTypeIdentifiers
import InfinitusCore
import InfinitusUI

/// The composer (`ChatComposer.tsx`'s form, `:4704-5600`): the floating card
/// under the thread — the prompt editor over a footer with the session's
/// controls on the left and Send / Stop on the right, the pending drawers
/// (Task 12) attached above it.
///
/// Ported: the surface (`ComposerSurface.tsx` `Main` `:62-80`), the editor
/// (`ComposerPromptEditor.tsx:1971-1990`) with ⏎ to send and ⇧⏎ for a newline
/// (`composerSubmissionIntentForEnter`, `composer-logic.ts:27-37`), the length
/// validation line (`ComposerPromptLengthValidation.tsx`), the footer's mode
/// control (`ChatComposer.tsx:931-1043`) and model label
/// (`ProviderModelPicker`, `:3979-4013`), the attach action (`:5528-5556`),
/// the primary actions (`ComposerPrimaryActions.tsx:222-283`) and terminal-style
/// prompt recall (`composerPromptHistory.ts:183-211`).
///
/// Not ported, each with its reason at the call site: the context-window meter
/// (`ContextWindowMeter.tsx` — B has no per-thread token usage), the resting /
/// mobile-collapsed layouts and the compact overflow menu
/// (`CompactComposerControlsMenu.tsx` — one Mac window, one width regime, and
/// the two controls always fit), plan/interaction mode (`plan` is Claude
/// Code's own mode, not something a running session can be moved to), the
/// prompt stash (⌘S, `ComposerStashMenu`), `@`-mentions, `$`-skills and `/`
/// commands (no producer on B), and the model *picker* — the model a live
/// session runs is read from its transcript and cannot be changed from here.
struct T3ComposerView: View {
    /// Plain references, like `T3ThreadView`'s (T3ThreadView.swift:37-41):
    /// observing either would re-run this body on every fleet tick. `app` is
    /// read for the session's birth (the permission floor) and its model.
    let model: T3WindowModel
    let app: AppModel
    @ObservedObject var store: T3TimelineStore
    /// Task 12's delivery, shared with the pending slot — one sender per
    /// thread, so a verdict and a message can never be in flight at once
    /// (`T3ThreadActions.send`'s `sending` guard).
    @ObservedObject var actions: T3ThreadActions
    @Environment(\.t3) private var t3

    /// The draft as typed. Deliberately `@State` and not a write into
    /// `T3WindowModel.drafts`: a per-keystroke publish there would re-render
    /// the sidebar and the top bar (the very cost T3ThreadView.swift:37-41
    /// avoids). `model.setDraft` debounces the persistence instead.
    @State private var draft = T3ComposerDraft()
    /// A one-shot focus request handed to the field (`model.composerFocusRequested`).
    @State private var focusRequest = false
    /// Messages this composer sent while a turn was running and has not yet
    /// seen come back as a user message — the badge's count. Ours: upstream
    /// has no queue (it sends into the running turn and the server orders
    /// them), so there is no component to transcribe.
    @State private var queued: [QueuedSend] = []
    /// Where prompt recall stands: the index into `model.promptHistory` the
    /// field is showing (`ComposerPromptHistoryPosition`,
    /// `composerPromptHistory.ts:39-42`), and the text it put there — an edit
    /// ends browsing (`:172`).
    @State private var recall: (index: Int, text: String)?
    @State private var dropTargeted = false

    /// One send waiting on the running turn.
    private struct QueuedSend: Equatable {
        let text: String
        let sentAt: Date
    }

    var body: some View {
        // `ComposerSurface.Main` (`ComposerSurface.tsx:67`): `rounded-[22px]
        // p-px` over the inner surface's `rounded-[20px]` (`:4959`).
        VStack(spacing: 0) {
            if !draft.attachments.isEmpty { attachmentList }
            // `data-chat-composer-body` (`:5019-5024`): `px-3 pb-2 sm:px-4`
            // with `pt-3.5 sm:pt-4` — the Mac renders the `sm:` half.
            promptField
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)
            if case let .tooLong(length) = verdict { validation(length: length) }
            footer
        }
        .background {
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            shape
                .fill(surface)
                // `after:border-(--chat-composer-outline)` (`:40`, `:17-18`):
                // black 8% on light, white 5% on dark.
                .overlay(shape.stroke(outline, lineWidth: 1))
        }
        // `shadow-[0_12px_28px_-18px_rgb(0_0_0/40%)] dark:shadow-none` (`:51`).
        // A flat fill, not glass: `--chat-composer-glass-surface` is `card`
        // (light) / `surface-raised` (dark) at `--glass-opacity`, and the
        // window has no CABackdropLayer host — the same call `T3BannerRoot`
        // makes for the drawers above it.
        .shadow(color: t3.scheme == .dark ? .clear : .black.opacity(0.4), radius: 14, x: 0, y: 12)
        .padding(.bottom, 16)
        // `isDragOverComposer` (`:4962`): `bg-accent/45 ring-1 ring-primary/70`.
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(t3.web.accent.color.opacity(0.45))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(t3.web.primary.color.opacity(0.7), lineWidth: 1))
                    .padding(.bottom, 16)
                    .allowsHitTesting(false)
            }
        }
        // `onDropCapture` on the form (`:4762-4765`) — files from Finder or
        // any app that promises a URL.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            load(providers: providers)
            return true
        }
        .onAppear {
            draft = model.draft(for: store.threadId)
            // The window was opened straight at the composer, or reopened
            // while the request was still pending.
            if model.composerFocusRequested { consumeFocusRequest() } else { focusRequest = true }
        }
        .onDisappear {
            // The debounce would drop the last keystrokes of a thread switch
            // or a window close.
            model.flushDraft(draft, for: store.threadId)
        }
        .onChange(of: draft) { _, new in model.setDraft(new, for: store.threadId) }
        .onChange(of: model.composerFocusRequested) { _, requested in
            if requested { consumeFocusRequest() }
        }
        // `ComposerPrimaryActions.tsx:166-181`'s "Refine": a panel asked for
        // its text in the draft (the plan card's Edit, Task 12).
        .onChange(of: model.pendingComposerInsert) { _, text in
            guard let text, !text.isEmpty else { return }
            insert(text)
            model.pendingComposerInsert = nil
        }
        .onChange(of: store.timeline) { _, timeline in drain(timeline) }
    }

    // MARK: - The editor

    private var promptField: some View {
        T3PromptField(text: $draft.text,
                      // `:5449`'s placeholder promises `@tag`, `$skills` and
                      // `/` commands, none of which exist here; `:4998`'s
                      // shorter form of the same string is the honest one.
                      placeholder: "Ask anything...",
                      focus: focusRequest,
                      recalling: recall != nil,
                      onFocusHandled: { focusRequest = false },
                      onSubmit: send,
                      onRecall: step(recall:),
                      onPaste: paste)
    }

    /// `ComposerPromptLengthValidation.tsx:5-11`: `px-3 pb-2 text-xs
    /// text-destructive sm:px-4`, the sentence from
    /// `getComposerPromptLengthValidationMessage` (`composerSubmission.ts:20-22`).
    private func validation(length: Int) -> some View {
        Text(T3ComposerDrafts.tooLongMessage(length: length))
            .font(T3Font.web(.xs))
            .foregroundStyle(t3.web.destructive.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
    }

    // MARK: - The footer

    /// `data-chat-composer-footer` (`:5496-5504`): `flex items-center
    /// justify-between gap-2 px-3 pb-3 sm:px-4 sm:pb-4`, controls left
    /// (`:5506-5515`) and the primary actions right (`:5519-5526`).
    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {   // the left group's `gap-1`
                if let model = sessionModel { modelLabel(model) }
                if !modeChoices.isEmpty {
                    if sessionModel != nil { T3ComposerControlSeparator() }
                    modeMenu
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {   // `gap-2` on the right group
                T3ComposerIconButton(icon: .paperclip, tooltip: "Attach files", action: openAttachmentPanel)
                    .disabled(draft.attachments.count >= SessionInput.maxAttachments)
                if !queued.isEmpty {
                    // Ours (see `queued`): the count of sends the running turn
                    // has not answered yet.
                    T3Badge("\(queued.count) queued", variant: .secondary)
                        .accessibilityLabel("\(queued.count) messages queued behind the running turn")
                }
                if running { stopButton }
                sendButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    /// `ProviderModelPicker`'s trigger (`:3979-4013`) as a label: the provider
    /// mark and the model the session runs. Read-only — the model comes from
    /// the transcript (`SessionProgress.model`, SessionProgress.swift:56) and
    /// no wire moves a live Claude Code session to another one.
    private func modelLabel(_ name: String) -> some View {
        T3ComposerControl(label: Self.modelLabel(name), chevron: false) {
            T3ProviderIcon(size: 16)
        }
        .accessibilityLabel("Model \(name)")
    }

    /// `ComposerFooterModeControls`' runtime-mode select (`:990-1039`): the
    /// mode in force with its glyph, the modes it may move to in the menu.
    /// `runtimeModeConfig`'s labels and descriptions (`:832-856`) are
    /// `SessionStart.hookModes`' labels here — the same three words for the
    /// same three modes, plus upstream's `auto`, which has no hook equivalent.
    private var modeMenu: some View {
        Menu {
            ForEach(modeChoices, id: \.mode) { choice in
                Button {
                    // The same request `TeamSessionChatWindow.swift:183` puts
                    // on the wire; `AppModel.setSessionMode` (:260-274) checks
                    // the floor again and records the move on the birth.
                    actions.send(.init(kind: .mode, text: choice.mode), app: app, pid: store.pid)
                } label: {
                    Text(choice.label)
                }
            }
        } label: {
            T3ComposerControl(label: currentModeLabel, chevron: true) {
                LucideIcon(Self.modeIcon(currentMode), size: 16)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(actions.sending)
        .accessibilityLabel("Runtime mode")
    }

    /// `ComposerPrimaryActions.tsx:222-272`: a 32 pt round button
    /// (`h-9 w-9 … sm:h-8 sm:w-8`) in `message-action`, the arrow at 14 with a
    /// 1.8 stroke (`:261-268` — lucide's own `arrow-up` geometry), the spinner
    /// while a send is in flight (`:258-259`).
    private var sendButton: some View {
        Button(action: send) {
            ZStack {
                Circle().fill(t3.web.messageAction.color)
                if actions.sending {
                    T3Spinner(size: 14)
                } else {
                    LucideIcon(.arrowUp, size: 14, strokeWidth: 1.8)
                        .foregroundStyle(t3.web.messageActionForeground.color)
                }
            }
            .frame(width: 32, height: 32)
            // `disabled:opacity-30` (`:226`).
            .opacity(canSend ? 1 : 0.3)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .help("Send (Return; Shift-Return for a new line)")
        .accessibilityLabel(actions.sending ? "Sending" : "Send message")
    }

    /// `renderStopGenerationButton` (`:89-108`): `size-8 sm:h-8 sm:w-8`,
    /// `bg-destructive/90`, an 8×8 `rx 1.5` square in a 12 box.
    private var stopButton: some View {
        Button {
            // The interrupt the shipped chat window sends
            // (SessionChatWindow.swift:301) — `esc`, which `OwnedSessions`
            // turns into a real interrupt (OwnedSessions.swift:443) and the
            // terminal path types.
            actions.send(.init(kind: .key, text: "esc"), app: app, pid: store.pid)
        } label: {
            ZStack {
                Circle().fill(t3.web.destructive.color.opacity(0.9))
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.white)
                    .frame(width: 8, height: 8)
            }
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .disabled(actions.sending)
        .accessibilityLabel("Stop generation")
    }

    // MARK: - Attachments

    /// The staged files (`:5311-5345`): name, size and a remove button per
    /// row. Upstream previews images as thumbnails (`:5250-5306`); these rows
    /// carry the same information without a disk read per frame, and the
    /// session receives every attachment as a path either way.
    private var attachmentList: some View {
        VStack(spacing: 4) {   // `flex flex-col gap-1`
            ForEach(draft.attachments, id: \.path) { attachment in
                T3ComposerAttachmentRow(attachment: attachment) {
                    draft.attachments.removeAll { $0.path == attachment.path }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// `attachmentInputRef.click()` (`:5537-5545`) — the platform's own file
    /// chooser, limited to what `SessionInput` will accept.
    private func openAttachmentPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = SessionInput.allowedAttachmentMimes.compactMap { UTType(mimeType: $0) }
        guard panel.runModal() == .OK else { return }
        stage(panel.urls)
    }

    /// A drop's promised URLs, resolved off the main actor by the item
    /// provider itself, then staged on it.
    private func load(providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in stage([url]) }
            }
        }
    }

    /// ⌘V in the field. `shouldHandleComposerAttachmentPaste`
    /// (`composerAttachmentFiles.ts:148-166`): files claim the paste, and
    /// image bytes with no file behind them (a screenshot) claim it too —
    /// anything else falls through to the normal text paste.
    private func paste() -> Bool {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            stage(urls)
            return true
        }
        guard board.canReadItem(withDataConformingToTypes: [UTType.image.identifier]),
              let image = NSImage(pasteboard: board),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return false }
        // A pasted screenshot has no path; `T3ComposerAttachmentRef` is one,
        // and `SessionInput.deliver` copies from it — so write the bytes to a
        // temp file first. (It lands in the session's attachments dir at send;
        // this copy is what the draft can survive a relaunch with.)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitus-paste-\(UUID().uuidString).png")
        guard (try? png.write(to: url, options: .atomic)) != nil else {
            actions.note = "couldn't stage the pasted image"
            return true
        }
        stage([url])
        return true
    }

    /// `addComposerAttachments`' limits, as `SessionInput` spells them: at
    /// most `maxAttachments`, each within `maxAttachmentBytes(mime:)` and of
    /// an allowed type. A rejection is said out loud in the banner stack
    /// rather than swallowed (`composerAttachmentFiles.ts:141-147`).
    private func stage(_ urls: [URL]) {
        var rejection: String?
        for url in urls {
            guard draft.attachments.count < SessionInput.maxAttachments else {
                rejection = "at most \(SessionInput.maxAttachments) attachments per message"
                break
            }
            guard !draft.attachments.contains(where: { $0.path == url.path }) else { continue }
            // The extension is what upstream infers an image type from
            // (`inferImageMimeTypeFromName`, `composerAttachmentFiles.ts:37-43`);
            // `UTType` is the platform's own table for it.
            guard let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType,
                  SessionInput.allowedAttachmentMimes.contains(mime) else {
                rejection = "\(url.lastPathComponent) is not a file this session can read"
                continue
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= SessionInput.maxAttachmentBytes(mime: mime) else {
                rejection = "\(url.lastPathComponent) is over the \(SessionInput.maxAttachmentBytes(mime: mime) / (1024 * 1024)) MB limit"
                continue
            }
            draft.attachments.append(T3ComposerAttachmentRef(path: url.path, mime: mime))
        }
        if let rejection { actions.note = rejection }
    }

    // MARK: - Sending

    private var running: Bool { store.timeline?.latestTurn?.state == .running }
    private var verdict: T3ComposerDrafts.SendVerdict {
        T3ComposerDrafts.canSend(text: draft.text, running: running)
    }

    /// `hasSendableContent` (`ComposerPrimaryActions.tsx:237`): a staged file
    /// with no prompt is a send too — `SessionInput.deliver` writes "Please
    /// look at the attached file(s):" for it (SessionInput.swift:299-300),
    /// which is upstream's `ATTACHMENT_ONLY_BOOTSTRAP_PROMPT`
    /// (`composerPromptHistory.ts:19-20`).
    private var canSend: Bool {
        guard !actions.sending, !store.gone else { return false }
        switch verdict {
        case .send, .queue: return true
        case .empty: return !draft.attachments.isEmpty
        case .tooLong: return false
        }
    }

    private func send() {
        guard canSend else { return }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var attachments: [SessionInput.Attachment] = []
        for ref in draft.attachments {
            // Read here, on the actor: the files are capped at 5 MB (20 for a
            // video) and `deliverSessionInput` runs detached from a value it
            // cannot read lazily.
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: ref.path)) else {
                actions.note = "\(ref.name) could not be read"
                return
            }
            attachments.append(SessionInput.Attachment(name: ref.name, mime: ref.mime, data: data))
        }
        let wasRunning = running
        let sentAt = Date()
        // No `queuedAt`: it marks a request that waited in the phone's outbox
        // and drives a push when it lands (SessionInput.swift:36-39,
        // AppModel.swift:1745) — this one was typed just now, in front of the
        // Mac.
        actions.send(.init(kind: .message, text: text,
                           attachments: attachments.isEmpty ? nil : attachments),
                     app: app, pid: store.pid) { reply in
            // Only a request the session actually took is queued behind the
            // turn: a pty-hosted session that is busy answers "running"
            // (SessionInput.swift:344), and the banner already says so.
            guard wasRunning, reply.outcome == "delivered", !text.isEmpty else { return }
            queued.append(QueuedSend(text: text, sentAt: sentAt))
        }
        // Upstream clears optimistically too (`submitComposer`); a failure
        // comes back as the banner stack's note, not as a lost prompt —
        // recall (↑) puts it back.
        model.pushPromptHistory(text)
        draft = T3ComposerDraft()
        recall = nil
        model.flushDraft(draft, for: store.threadId)
    }

    /// A queued send has landed once a user message carrying its text shows up
    /// in the transcript. Matched by `contains`, not equality: the delivered
    /// text is prefaced (`PeerSocket.phonePreface`, SessionInput.swift:327-328)
    /// and carries the `[attached: …]` line. Oldest first, so two identical
    /// prompts drain in order.
    private func drain(_ timeline: SessionTimeline?) {
        guard !queued.isEmpty else { return }
        guard running, let timeline else {
            // The turn is over: nothing is waiting behind it any more.
            queued = []
            return
        }
        var remaining = queued
        for message in timeline.messages where message.role == .user {
            guard let index = remaining.firstIndex(where: {
                message.createdAt >= $0.sentAt.addingTimeInterval(-1) && message.text.contains($0.text)
            }) else { continue }
            remaining.remove(at: index)
        }
        if remaining != queued { queued = remaining }
    }

    // MARK: - Focus, insertion and recall

    private func consumeFocusRequest() {
        focusRequest = true
        // One-shot (`T3WindowModel.applyFocusedScreen`, :48).
        model.composerFocusRequested = false
    }

    /// A panel's text into the draft: appended to whatever is already typed,
    /// the way upstream's "Refine" leaves the draft alone and adds to it.
    private func insert(_ text: String) {
        if draft.text.isEmpty {
            draft.text = text
        } else if draft.text.hasSuffix("\n") {
            draft.text += text
        } else {
            draft.text += "\n\n" + text
        }
        recall = nil
        focusRequest = true
    }

    /// `stepComposerPromptHistory` (`composerPromptHistory.ts:183-211`):
    /// backward starts only from an empty prompt and stops at the oldest
    /// entry; forward past the newest empties the field and ends browsing; an
    /// edited recall (the field no longer holds what was recalled) restarts
    /// browsing from scratch. Ours is one flat list across threads
    /// (`T3ComposerDrafts.pushHistory`), not the thread's own user messages.
    private func step(recall direction: Int) -> Bool {
        let history = model.promptHistory
        guard !history.isEmpty else { return false }
        let active = self.recall.flatMap { $0.text == draft.text ? $0.index : nil }
        if direction < 0 {
            guard active != nil || draft.text.isEmpty else { return false }
            let next = (active ?? -1) + 1
            guard next < history.count else { return false }
            self.recall = (next, history[next])
            draft.text = history[next]
            return true
        }
        guard let active else { return false }
        let next = active - 1
        if next < 0 {
            self.recall = nil
            draft.text = ""
            return true
        }
        self.recall = (next, history[next])
        draft.text = history[next]
        return true
    }

    // MARK: - Capabilities

    // The gate follows the wire, never the engine's identity: a `.mode`
    // request never reaches the session — `AppModel.deliverSessionInput`
    // (:1713-1719) answers it on the Mac from the session's RECORD, and
    // the plugin's PreToolUse hook enforces it (the same path behind
    // "Allow for this session" on a terminal session). So the control
    // shows wherever the mode can move, owned or not, exactly as the team
    // window's Mode menu does (TeamSessionChatWindow.swift:181-183).

    private var birth: SessionBirth? { app.sessionBirths[Int(store.pid)] }
    /// `SessionProgress.model`, off the newest transcript entry that names one
    /// (SessionProgress.swift:52-56).
    private var sessionModel: String? {
        app.sessionProgress.byPid[Int(store.pid)]?.model
    }
    private var currentMode: String? { birth?.effectiveMode }
    private var currentModeLabel: String {
        guard let mode = currentMode else { return "Supervised" }
        return SessionStart.hookModes.first { $0.mode == mode }?.label
            ?? SessionStart.permissionModes.first { $0.mode == mode }?.label
            ?? "Supervised"
    }

    /// "A start mode is a floor" (`SessionStart.modeRank`, SessionStart.swift:76-84):
    /// the hook can only widen what Claude Code already lets through, so the
    /// menu lists the modes at or above the mode the session started in — the
    /// same comparison `AppModel.setSessionMode` rejects on (:265-270).
    private var modeChoices: [(mode: String, label: String)] {
        let floor = SessionStart.modeRank(birth?.permissionMode)
        return SessionStart.hookModes.filter {
            SessionStart.modeRank($0.mode == "supervised" ? nil : $0.mode) >= floor
        }
    }

    /// `runtimeModeConfig`'s glyphs (`ChatComposer.tsx:832-856`): `LockIcon`,
    /// `PenLineIcon`, `LockOpenIcon`. The vendored set has no `lock` or
    /// `lock-open` — `shield-check` and `zap` are its nearest for "asks first"
    /// and "nothing is asked".
    private static func modeIcon(_ mode: String?) -> Lucide {
        switch mode {
        case "acceptEdits": return .penLine
        case "bypassPermissions": return .zap
        default: return .shieldCheck
        }
    }

    /// `activeThreadModelDisplayName` (`ChatComposer.tsx:5566`) is the model's
    /// display name, not its id; B has only the id the transcript carries
    /// (`claude-sonnet-4-5-20250929`), so this is ours: drop the vendor prefix
    /// and the build date, keep the family and its version.
    private static func modelLabel(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }

    private var surface: Color {
        // `--chat-composer-glass-surface`: `var(--card)` light,
        // `var(--surface-raised)` dark (`ComposerSurface.tsx:17-18`).
        t3.scheme == .dark ? t3.web.surfaceRaised.color : t3.web.card.color
    }
    private var outline: Color {
        // `--chat-composer-outline` (`:17-18`).
        t3.scheme == .dark ? .white.opacity(0.05) : .black.opacity(0.08)
    }
}

// MARK: - The footer's controls

/// `ComposerControl` (`ComposerControl.tsx:19-43`) at `size="sm"`:
/// `h-7 min-h-7 gap-1.5 px-2.5 rounded-[var(--control-radius)]`, a ghost button
/// in `secondary-label` going `foreground` on hover, with
/// `ComposerControlIcon` (`:45-67`, `size-4` = 16) and
/// `ComposerControlChevron` (`:69-88`, `size-3.5` = 14, stroke 2.25,
/// `icon-muted`).
private struct T3ComposerControl<Icon: View>: View {
    let label: String
    let chevron: Bool
    @ViewBuilder let icon: Icon
    @State private var hover = false
    @Environment(\.t3) private var t3

    var body: some View {
        HStack(spacing: 6) {   // `gap-1.5`
            icon
            Text(label).font(T3Font.web(.sm, .medium))
            if chevron {
                LucideIcon(.chevronDown, size: 14, strokeWidth: 2.25)
                    .foregroundStyle(t3.web.iconMuted.color)
                    // `[&_svg[data-composer-control-chevron]]:-mx-0.5` (`:20`).
                    .padding(.horizontal, -2)
            }
        }
        .foregroundStyle(hover ? t3.web.foreground.color : t3.web.secondaryLabel.color)
        .padding(.horizontal, 10)   // `px-2.5`
        .frame(height: T3ButtonMetrics.height(.sm))   // `h-7` at the `sm:` breakpoint
        .background(hover ? t3.web.accent.color : .clear,
                    in: RoundedRectangle(cornerRadius: T3Theme.Metrics.controlRadius))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// `ComposerControlSeparator` (`ComposerControl.tsx:90-104`): a vertical rule,
/// `h-4 mx-0.5`.
private struct T3ComposerControlSeparator: View {
    @Environment(\.t3) private var t3
    var body: some View {
        Rectangle()
            .fill(t3.web.border.color)
            .frame(width: 1, height: 16)
            .padding(.horizontal, 2)
    }
}

/// `Button size="icon-sm" variant="ghost"` (`ui/button.tsx:36`), the composer's
/// attach action (`ChatComposer.tsx:5544-5556`): a 28 pt square, the glyph in
/// `secondary-label` over an `accent` fill on hover.
private struct T3ComposerIconButton: View {
    let icon: Lucide
    let tooltip: String
    let action: () -> Void
    @State private var hover = false
    @Environment(\.t3) private var t3

    var body: some View {
        T3Tooltip(tooltip) {
            Button(action: action) {
                LucideIcon(icon, size: 16)
                    .foregroundStyle(hover ? t3.web.foreground.color : t3.web.secondaryLabel.color)
                    .frame(width: T3ButtonMetrics.height(.sm), height: T3ButtonMetrics.height(.sm))
                    .background(hover ? t3.web.accent.color : .clear,
                                in: RoundedRectangle(cornerRadius: T3Theme.Metrics.controlRadius))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .accessibilityLabel(tooltip)
        }
    }
}

/// One staged file (`ChatComposer.tsx:5324-5330`): `flex items-center gap-2
/// py-1 text-sm`, the name truncating, its size in `text-xs
/// text-secondary-label` (`:5334`) and an `icon-xs` remove button (`:5390`).
private struct T3ComposerAttachmentRow: View {
    let attachment: T3ComposerAttachmentRef
    let onRemove: () -> Void
    @Environment(\.t3) private var t3

    var body: some View {
        HStack(spacing: 8) {
            LucideIcon(attachment.mime.hasPrefix("image/") ? .image : .file, size: 14)
                .foregroundStyle(t3.web.mutedForeground.color)
            Text(attachment.name)
                .font(T3Font.web(.sm))
                .foregroundStyle(t3.web.foreground.color)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.size(of: attachment))
                .font(T3Font.web(.xs))
                .foregroundStyle(t3.web.secondaryLabel.color)
            T3ComposerIconButton(icon: .x, tooltip: "Remove \(attachment.name)", action: onRemove)
        }
        .padding(.vertical, 4)
    }

    /// `formatAttachmentSize`'s job, done by the platform's own formatter.
    private static func size(of attachment: T3ComposerAttachmentRef) -> String {
        let bytes = (try? URL(fileURLWithPath: attachment.path)
            .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - The prompt field

/// The prompt editor (`ComposerPromptEditor.tsx:1971-1990`) as an `NSTextView`.
///
/// Why not SwiftUI: `TextEditor` has no submit at all (⏎ always inserts a
/// newline) and `TextField(axis: .vertical)`'s `onSubmit` cannot tell ⏎ from
/// ⇧⏎ — AppKit binds both to `insertNewline:` and only ⌥⏎ to
/// `insertNewlineIgnoringFieldEditor:` — nor can either intercept ⌘V to claim
/// a pasted screenshot, or ↑/↓ for prompt recall. `doCommand(by:)` on an
/// `NSTextView` answers all four.
private struct T3PromptField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    /// A one-shot focus request; `onFocusHandled` clears it once taken.
    let focus: Bool
    /// Whether prompt recall is already walking the history — ↑ from a
    /// non-empty field only steps when it is (`composerPromptHistory.ts:196`).
    let recalling: Bool
    let onFocusHandled: () -> Void
    let onSubmit: () -> Void
    /// −1 = older, +1 = newer; false leaves the key to normal caret movement.
    let onRecall: (Int) -> Bool
    /// True when the paste was claimed as attachments.
    let onPaste: () -> Bool

    /// `[font-size:var(--font-size-prompt,0.875rem)]` with `leading-relaxed`
    /// (`ComposerPromptEditor.tsx:1973`, `:1982`) — 14 pt on a 1.625 line box.
    private static let fontSize: Double = 14
    private static let lineHeightMultiple: Double = 1.625
    /// `whitespace-pre-wrap` inside the body's own padding: the text view adds
    /// none of its own beyond the container's line-fragment padding.
    private static let inset = NSSize(width: 0, height: 0)

    func makeNSView(context: Context) -> NSScrollView {
        let view = T3PromptTextView()
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.drawsBackground = false
        view.textContainerInset = Self.inset
        // The canonical text-view-in-a-scroll-view setup: the container
        // tracks the view's width and the view grows with its text, so the
        // string lays out from the top and overflow scrolls.
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.font = .systemFont(ofSize: Self.fontSize)
        view.defaultParagraphStyle = Self.paragraphStyle
        view.typingAttributes = Self.attributes
        view.textColor = NSColor(context.environment.t3.web.foreground.color)
        view.placeholder = NSAttributedString(string: placeholder, attributes: [
            .font: NSFont.systemFont(ofSize: Self.fontSize),
            .foregroundColor: NSColor(context.environment.t3.web.placeholder.color),
            .paragraphStyle: Self.paragraphStyle,
        ])
        view.string = text

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? T3PromptTextView else { return }
        context.coordinator.parent = self
        // Only when it differs: an unconditional assignment would reset the
        // caret and the undo stack on every unrelated republish.
        if view.string != text {
            view.string = text
            view.needsDisplay = true
        }
        view.textColor = NSColor(context.environment.t3.web.foreground.color)
        view.typingAttributes = Self.attributes
        if focus, view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
            DispatchQueue.main.async { onFocusHandled() }
        } else if focus {
            DispatchQueue.main.async { onFocusHandled() }
        }
    }

    /// The editor grows with its text between `min-h-17.5` (70) and `max-h-50`
    /// (200) and scrolls past that (`overflow-y-auto`,
    /// `ComposerPromptEditor.tsx:1982`) — measured from the string rather than
    /// the live layout so no measurement writes back into the view.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        // A pass may propose no width at all; 320 wraps narrower than the
        // real card, so such a pass can only over-report a line, and the
        // next (sized) pass corrects it.
        let width = proposal.width ?? 320
        let padding = ((nsView.documentView as? NSTextView)?.textContainer?.lineFragmentPadding ?? 5) * 2
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: max(1, width - padding), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: Self.attributes)
        // `boundingRect` ignores a trailing newline; the caret still needs its
        // line.
        let trailing = text.hasSuffix("\n") ? Self.fontSize * Self.lineHeightMultiple : 0
        return CGSize(width: width, height: min(200, max(70, ceil(bounds.height + trailing))))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeightMultiple
        return style
    }
    private static var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize), .paragraphStyle: paragraphStyle]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: T3PromptField
        init(_ parent: T3PromptField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? T3PromptTextView else { return }
            parent.text = view.string
            view.needsDisplay = true   // the placeholder appears and disappears
        }
    }
}

/// The field itself: draws the placeholder an `NSTextView` has no property
/// for, and routes the four keys SwiftUI cannot reach.
private final class T3PromptTextView: NSTextView {
    var placeholder: NSAttributedString?
    weak var coordinator: T3PromptField.Coordinator?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let placeholder else { return }
        placeholder.draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5),
                                     y: textContainerInset.height))
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // AppKit sends `insertNewline:` for both ⏎ and ⇧⏎ — only the event
            // tells them apart (`composerSubmissionIntentForEnter`,
            // `composer-logic.ts:33-34`: shift is a newline, never a send).
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                super.doCommand(by: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
                return
            }
            coordinator?.parent.onSubmit()
            return
        case #selector(NSResponder.moveUp(_:)):
            if canRecall, coordinator?.parent.onRecall(-1) == true { return }
        case #selector(NSResponder.moveDown(_:)):
            if coordinator?.parent.recalling == true, coordinator?.parent.onRecall(1) == true { return }
        default:
            break
        }
        super.doCommand(by: selector)
    }

    /// Backward recall starts from an empty prompt and continues while
    /// browsing (`stepComposerPromptHistory`, `composerPromptHistory.ts:196`).
    private var canRecall: Bool {
        string.isEmpty || coordinator?.parent.recalling == true
    }

    override func paste(_ sender: Any?) {
        if coordinator?.parent.onPaste() == true { return }
        super.paste(sender)
    }

    /// ⌥⏎ keeps AppKit's own meaning (a newline) — `insertNewlineIgnoringFieldEditor:`
    /// arrives here and is passed straight through by `doCommand(by:)`.
    override var acceptsFirstResponder: Bool { true }
}
