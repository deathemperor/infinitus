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
/// the primary actions (`ComposerPrimaryActions.tsx:222-283`), terminal-style
/// prompt recall (`composerPromptHistory.ts:183-211`) and the `/` command and
/// `@` file menus (`ComposerCommandMenu.tsx` over `detectComposerTrigger`,
/// `packages/shared/src/composerTrigger.ts`).
///
/// Not ported, each with its reason at the call site: the context-window meter
/// (`ContextWindowMeter.tsx` — B has no per-thread token usage), the resting /
/// mobile-collapsed layouts and the compact overflow menu
/// (`CompactComposerControlsMenu.tsx` — one Mac window, one width regime, and
/// the two controls always fit), plan/interaction mode (`plan` is Claude
/// Code's own mode, not something a running session can be moved to), the
/// prompt stash (⌘S, `ComposerStashMenu`), `$`-skills and `/model` (no
/// producer on B — `T3ComposerTrigger` carries the reason), and the model
/// *picker* — the model a live session runs is read from its transcript and
/// cannot be changed from here.
/// What a composer with no session yet sends into (Task 15): upstream's
/// `composerDraftTarget` / `draftId` props on `<ChatComposer>`
/// (`ChatView.tsx:8052-8060`). `nil` is a live thread, and the whole live path
/// below is unchanged by draft mode.
struct T3ComposerDraftTarget: Equatable {
    let draftId: String
    /// The project the first prompt starts its session in.
    let projectId: String
}

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
    /// Set only for a draft thread: ⏎ starts a session instead of delivering
    /// into one (Task 15).
    var draftTarget: T3ComposerDraftTarget?
    /// The drafts' start state (fix 1). Observed — and only this, not the
    /// whole model — so a start that begins or ends re-renders the send
    /// button while a fleet tick still does not.
    @ObservedObject var draftStart: T3DraftStart
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
    @State private var queued: [T3QueuedSend] = []
    /// Where prompt recall stands: the index into `model.promptHistory` the
    /// field is showing (`ComposerPromptHistoryPosition`,
    /// `composerPromptHistory.ts:39-42`), and the text it put there — an edit
    /// ends browsing (`:172`).
    @State private var recall: (index: Int, text: String)?
    @State private var dropTargeted = false

    // MARK: - The `/` and `@` menus (Task 14)

    /// The caret as the field reports it, in UTF-16 code units — what
    /// `T3ComposerTrigger.detect` reads the trigger at
    /// (`ComposerPromptEditor.tsx`'s `selection.anchor` upstream).
    @State private var caret = 0
    /// A caret the composer wants the field to move to (after an insertion or
    /// a restored draft); the field takes it and clears it.
    @State private var caretRequest: Int?
    /// The project's commands / path candidates, loaded when a menu opens and
    /// cached on the model by cwd — never read per keystroke.
    @State private var commands: [SlashCommand] = []
    @State private var mentionRows: [String] = []
    @State private var mentionCwd: String?
    @State private var mentionLoading = false
    /// The menu's own state (`T3ComposerMenuState`, Core): the highlighted
    /// row and the query it was highlighted under
    /// (`composerHighlightedItemId` / `composerHighlightedSearchKey`,
    /// `ChatComposer.tsx:2027-2041`), and which trigger ⎋ shut. Upstream's
    /// menu is open exactly while a trigger is under the caret (`:2023`) and
    /// ⎋ does nothing; a dismissal here stays until the caret is on a
    /// different trigger — never longer, or ⎋ would make `/` a dead key.
    @State private var menu = T3ComposerMenuState()
    /// The open menu's measured height (`T3ComposerMenuHeightKey`).
    @State private var menuHeight: Double = 0
    /// True while `SlashCommands.discover` is reading the command files and no
    /// cached rows stand in — upstream's `isLoading` (`:114`).
    @State private var commandLoading = false
    /// The rank in flight, so the next keystroke can abandon it.
    @State private var rankTask: Task<Void, Never>?
    /// Draft mode only: the start-time permission mode the session will be
    /// born with (`SessionStart.permissionModes`), nil = no
    /// `--permission-mode` flag.
    @State private var startMode: String?
    /// Whether THIS draft's session is starting. Model state, never `@State`:
    /// the view is remounted on every thread switch and the guard has to
    /// outlive it (fix 1, important #1).
    private var starting: Bool { draftTarget.map { draftStart.isStarting($0.draftId) } ?? false }

    var body: some View {
        // One detection per body pass: `detect` copies the text's UTF-16, and
        // the menu, both `onChange`s and the dismissal's lapse all want the
        // same answer for this (text, caret).
        let raw = rawTrigger
        let trigger = menu.trigger(raw)
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
            if let message = validationMessage { validation(message) }
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
        // `ComposerCommandMenuLayer` (`:5046-5059`) portals the menu to an
        // anchor above the composer; here it is an overlay whose BOTTOM edge is
        // pinned to the card's top — the drawer position upstream's
        // `ComposerBanner.Surface` sits in. Anchoring to the caret's own line
        // is out of scope (the field would have to report its layout).
        .overlay(alignment: .topLeading) {
            if let trigger {
                let items = menuItems(trigger)
                T3ComposerMenu(items: items, activeID: activeItemID(items, trigger),
                               emptyText: menuEmptyText(trigger),
                               onHighlight: highlight, onPick: pick)
                    // Lifted by its own measured height: an alignment guide
                    // cannot push an overlay outside its container (it lands on
                    // the field instead — seen on the fixture).
                    .offset(y: -menuHeight)
                    .opacity(menuHeight > 0 ? 1 : 0)
                    // Until it is measured it sits ON the card, where it would
                    // eat the field's own clicks.
                    .allowsHitTesting(menuHeight > 0)
                    .onPreferenceChange(T3ComposerMenuHeightKey.self) { menuHeight = $0 }
            }
        }
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
        // any app that promises a URL, and bare image bytes from one that
        // promises no file (Photos, a browser drag).
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            // Draft mode has nothing to stage into (see `stage`): the drop is
            // refused rather than half-taken, so the Finder animates the file
            // back and `stage` says why.
            guard draftTarget == nil else {
                actions.note = Self.draftAttachmentRefusal
                return false
            }
            load(providers: providers)
            return true
        }
        .onAppear {
            draft = model.draft(for: store.threadId)
            // A restored draft is typed-into at its end, not at its start.
            caretRequest = draft.text.utf16.count
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
        // Opening a menu is what loads its rows — a keystroke inside one only
        // re-ranks what is already in hand.
        .onChange(of: trigger?.kind) { _, kind in openMenu(kind) }
        .onChange(of: trigger?.query) { _, _ in rankMentions(trigger) }
        // A dismissal outlives only the trigger it shut: the moment the caret
        // is on another one (or on none — a send empties the field) it lapses.
        // Keyed on the raw detection, or clearing it would reopen the menu ⎋
        // just closed.
        .onChange(of: raw) { _, raw in menu.triggerMoved(raw) }
    }

    // MARK: - The editor

    private var promptField: some View {
        T3PromptField(text: $draft.text,
                      placeholder: placeholder,
                      caret: $caret,
                      caretRequest: $caretRequest,
                      focus: focusRequest,
                      recalling: recall != nil,
                      onFocusHandled: { focusRequest = false },
                      onSubmit: send,
                      onMenuKey: menuKey,
                      onRecall: step(recall:),
                      onPaste: paste)
    }

    /// `ChatComposer.tsx:5432-5450`'s ladder, ported in
    /// `T3ComposerPlaceholder`. `phase` is `derivePhase`
    /// (`session-logic.ts:1673-1685`) over what B can see: `T3TimelineStore.gone`
    /// — no record for this pid under this session id — is upstream's
    /// "no session / stopped / errored", a draft has no session at all, and a
    /// running turn is `running`. That last branch is why the Mac reference
    /// reads "Ask for changes…": its thread was recreated by hand in T3 Code
    /// and never ran.
    private var placeholder: String {
        let approval = store.pending.approvals.first
        let question = store.pending.userInputs.first
            .map { T3PendingAnswers.parse($0.questions) }?.first
        return T3ComposerPlaceholder.text(
            phase: phase,
            approval: (pending: approval != nil,
                       detail: approval.map { T3PendingApprovalItem($0).detail }),
            question: (pending: approval == nil && question != nil,
                       // `isChoiceOnlyPendingQuestion` (`:2052-2053`).
                       choiceOnly: question?.allowCustomAnswer == false),
            // Neither has a B counterpart: no proposed-plan follow-up prompt,
            // and a draft always carries the project it will start in
            // (`T3ComposerDraftTarget.projectId`).
            planFollowUp: false,
            projectSelectionRequired: false,
            noProviderAvailable: false)
    }

    private var phase: T3ComposerPlaceholder.Phase {
        if draftTarget != nil { return starting ? .connecting : .disconnected }
        if store.gone { return .disconnected }
        return running ? .running : .ready
    }

    /// `ComposerPromptLengthValidation.tsx:5-11`: `px-3 pb-2 text-xs
    /// text-destructive sm:px-4`, the sentence from
    /// `getComposerPromptLengthValidationMessage` (`composerSubmission.ts:20-22`).
    private func validation(_ message: String) -> some View {
        Text(message)
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
                // `SessionStart.Request` carries no attachments (a draft's
                // send is the session's first prompt), so draft mode has
                // nothing to stage them into — upstream's draft composer does
                // take files, over a wire B has no equivalent for.
                if draftTarget == nil {
                    T3ComposerIconButton(icon: .paperclip, tooltip: "Attach files", action: openAttachmentPanel)
                        .disabled(draft.attachments.count >= SessionInput.maxAttachments)
                }
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
        T3ComposerControl(label: T3ModelLabel.display(name), chevron: false) {
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
                    guard let pid = livePid else { startMode = choice.mode; return }
                    actions.send(.init(kind: .mode, text: choice.mode), app: app, pid: pid)
                } label: {
                    // Upstream's select hides its indicator (`:5019`,
                    // `hideIndicator`) and shows the mode in the trigger
                    // instead; a Mac menu marks the item in force as well.
                    if choice.mode == (currentMode ?? "supervised") {
                        Label(choice.label, systemImage: "checkmark")
                    } else {
                        Text(choice.label)
                    }
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
        .disabled(actions.sending || starting)
        .accessibilityLabel(draftTarget == nil ? "Runtime mode" : "Permission mode for the new session")
    }

    /// `ComposerPrimaryActions.tsx:222-272`: a 32 pt round button
    /// (`h-9 w-9 … sm:h-8 sm:w-8`) in `message-action`, the arrow at 14 with a
    /// 1.8 stroke (`:261-268` — lucide's own `arrow-up` geometry), the spinner
    /// while a send is in flight (`:258-259`).
    private var sendButton: some View {
        Button { send() } label: {
            ZStack {
                Circle().fill(t3.web.messageAction.color)
                if actions.sending || starting {
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
            guard let pid = livePid else { return }
            actions.send(.init(kind: .key, text: "esc"), app: app, pid: pid)
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
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in stage([url]) }
                }
                continue
            }
            // Image bytes with no file behind them — the same case as a pasted
            // screenshot, and staged the same way.
            let type = UTType.image.identifier
            guard provider.hasItemConformingToTypeIdentifier(type) else { continue }
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                guard let data else { return }
                Task { @MainActor in stageImageData(data) }
            }
        }
    }

    /// Bytes with no path: `T3ComposerAttachmentRef` is a path (and
    /// `SessionInput.deliver` copies from it), so they are written to the temp
    /// dir first — which is also what lets the draft survive a relaunch.
    private func stageImageData(_ data: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitus-image-\(UUID().uuidString).png")
        guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]),
              (try? png.write(to: url, options: .atomic)) != nil else {
            actions.note = "couldn't stage the image"
            return
        }
        stage([url])
    }

    /// ⌘V in the field. `shouldHandleComposerAttachmentPaste`
    /// (`composerAttachmentFiles.ts:148-166`): files claim the paste, and
    /// image bytes with no file behind them (a screenshot) claim it too —
    /// anything else falls through to the normal text paste.
    private func paste() -> Bool {
        // Draft mode stages nothing (see `stage`), and claiming the paste
        // would eat a pasted path instead of typing it.
        guard draftTarget == nil else { return false }
        let board = NSPasteboard.general
        // File URLs only: `readObjects(forClasses: [NSURL.self])` also answers
        // for a copied web link (`https://…`), and claiming that paste would
        // swallow the link instead of typing it — upstream reads the clipboard's
        // FILES (`event.clipboardData.files`, `composerAttachmentFiles.ts:148-166`).
        if let urls = board.readObjects(forClasses: [NSURL.self],
                                        options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            stage(urls)
            return true
        }
        guard board.canReadItem(withDataConformingToTypes: [UTType.image.identifier]),
              let image = NSImage(pasteboard: board),
              let tiff = image.tiffRepresentation
        else { return false }
        stageImageData(tiff)
        return true
    }

    /// `addComposerAttachments`' limits, as `SessionInput` spells them: at
    /// most `maxAttachments`, each within `maxAttachmentBytes(mime:)` and of
    /// an allowed type. A rejection is said out loud in the banner stack
    /// rather than swallowed (`composerAttachmentFiles.ts:141-147`).
    private func stage(_ urls: [URL]) {
        // `SessionStart.Request` carries no attachments (a draft's send is the
        // session's first prompt), so a file staged here would be dropped
        // silently at send — the paperclip is already hidden in draft mode
        // (`footer`), and this is the same refusal for the drop and paste paths.
        guard draftTarget == nil else {
            actions.note = Self.draftAttachmentRefusal
            return
        }
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
            draft.attachments.append(T3ComposerAttachmentRef(path: url.path, mime: mime, bytes: size))
        }
        if let rejection { actions.note = rejection }
    }

    /// Ours: upstream's draft composer does take files, over a wire B has no
    /// equivalent for.
    private static let draftAttachmentRefusal = "A new thread's first prompt can't carry attachments"

    // MARK: - Sending

    private var running: Bool { store.timeline?.latestTurn?.state == .running }
    /// The session's pid — nil in draft mode, where there is no session and the
    /// store is inert (its pid is `T3WindowModel.draftPid`, a sentinel). Every
    /// `actions.send` here goes through this, so a draft can reach no wire.
    private var livePid: Int32? { draftTarget == nil ? store.pid : nil }
    private var verdict: T3ComposerDrafts.SendVerdict {
        T3ComposerDrafts.canSend(text: draft.text, running: running)
    }
    /// What the destructive line under the field says, if anything: the length
    /// sentence, or the control-character refusal the wire would answer with
    /// (`T3ComposerDrafts.invalidMessage`).
    private var validationMessage: String? {
        switch verdict {
        case let .tooLong(length): return T3ComposerDrafts.tooLongMessage(length: length)
        case .invalid: return T3ComposerDrafts.invalidMessage
        case .send, .queue, .empty: return nil
        }
    }

    /// `hasSendableContent` (`ComposerPrimaryActions.tsx:237`): a staged file
    /// with no prompt is a send too — `SessionInput.deliver` writes "Please
    /// look at the attached file(s):" for it (SessionInput.swift:299-300),
    /// which is upstream's `ATTACHMENT_ONLY_BOOTSTRAP_PROMPT`
    /// (`composerPromptHistory.ts:19-20`).
    private var canSend: Bool {
        guard !actions.sending, !starting, !store.gone else { return false }
        switch verdict {
        case .send, .queue: return true
        // A draft's send IS the session's first prompt (`SessionStart.prompt`),
        // and the start wire carries no attachments — so an attachment-only
        // send has nothing to start with.
        case .empty: return draftTarget == nil && !draft.attachments.isEmpty
        case .tooLong, .invalid: return false
        }
    }

    /// True when the prompt went out — false when there was nothing to send or
    /// a staged file could not be read (⏎ still swallows the newline).
    @discardableResult
    private func send() -> Bool {
        guard canSend else { return false }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let target = draftTarget { return startDraftSession(target, text: text) }
        // Like every other wire call here: `store.pid` is the inert store's
        // sentinel in draft mode, and only `livePid` can never be it.
        guard let pid = livePid else { return false }
        var attachments: [SessionInput.Attachment] = []
        for ref in draft.attachments {
            // Read here, on the actor: the files are capped at 5 MB (20 for a
            // video) and `deliverSessionInput` runs detached from a value it
            // cannot read lazily.
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: ref.path)) else {
                actions.note = "\(ref.name) could not be read"
                return false
            }
            attachments.append(SessionInput.Attachment(name: ref.name, mime: ref.mime, data: data))
        }
        let wasRunning = running
        let sentAt = Date()
        // What to put back if the wire refuses it (below).
        let sent = draft
        // No `queuedAt`: it marks a request that waited in the phone's outbox
        // and drives a push when it lands (SessionInput.swift:36-39,
        // AppModel.swift:1745) — this one was typed just now, in front of the
        // Mac.
        actions.send(.init(kind: .message, text: text,
                           attachments: attachments.isEmpty ? nil : attachments),
                     app: app, pid: pid) { reply in
            guard reply.outcome == "delivered" else {
                // Nothing reached the session — "rejected" (an invalid or
                // unknown message), "running" (SessionInput.swift:344, the pty
                // is busy) or "captured". The banner says why; the prompt and
                // its staged files go back into the field, which is the only
                // copy of them there is. Unless something has been typed in the
                // meantime, which is now the newer draft.
                guard draft.isEmpty else { return }
                draft = sent
                model.flushDraft(sent, for: store.threadId)
                return
            }
            // Only a request the session actually took waits behind the turn.
            guard wasRunning, !text.isEmpty else { return }
            queued.append(T3QueuedSend(text: text, sentAt: sentAt))
        }
        // Upstream clears optimistically too (`submitComposer`); a failure
        // comes back as the banner stack's note, not as a lost prompt —
        // recall (↑) puts it back.
        model.pushPromptHistory(text)
        let cleared = T3ComposerDraft()
        draft = cleared
        recall = nil
        model.flushDraft(cleared, for: store.threadId)
        return true
    }

    /// Draft mode's send (Task 15): the prompt starts the session, and the
    /// reducer swaps the draft for the real thread once its pid shows up in the
    /// fleet — this view is remounted by `T3Root` then, which is exactly why
    /// the guard lives on the model and is released only when the draft is
    /// replaced or its start times out (fix 1).
    private func startDraftSession(_ target: T3ComposerDraftTarget, text: String) -> Bool {
        // Everything else — the guard, the note, and the prompt history (pushed
        // only once a session really started) — belongs to the model.
        model.sendDraft(target.draftId, text: text, permissionMode: startMode)
        // Unlike a live send, the prompt STAYS in the field until the session
        // is under way: a refused start (or the disabled-start gate) must leave
        // the draft exactly as it was.
        return true
    }

    /// A queued send has landed once a user message carrying its text shows
    /// up in the transcript (`T3ComposerDrafts.drainQueue`).
    private func drain(_ timeline: SessionTimeline?) {
        guard !queued.isEmpty else { return }
        guard running, let timeline else {
            // The turn is over: nothing is waiting behind it any more.
            queued = []
            return
        }
        let remaining = T3ComposerDrafts.drainQueue(queued: queued, userMessages: timeline.messages)
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
        caretRequest = draft.text.utf16.count
        focusRequest = true
    }

    // MARK: - The `/` and `@` menus

    /// The trigger under the caret (`detectComposerTrigger`), unless ⎋ shut
    /// this one. Derived, never stored: the text and the caret land in
    /// separate passes and detection is a scan of one line.
    private var trigger: T3ComposerTrigger.Detected? {
        menu.trigger(rawTrigger)
    }

    /// The same detection with ⎋'s dismissal ignored — what tells the
    /// dismissal it has been outlived.
    private var rawTrigger: T3ComposerTrigger.Detected? {
        T3ComposerTrigger.detect(text: draft.text, caret: caret)
    }

    /// The selected thread's project folder — where both menus read from.
    private var cwd: String? {
        guard let thread = model.state.threads.first(where: { $0.id == store.threadId }) else { return nil }
        return model.state.projects.first { $0.id == thread.projectId }?.cwd
    }

    /// `composerMenuItems` (`ChatComposer.tsx:1921-1996`): a path row is its
    /// basename over the directory it sits in (`:1929-1930`), a command row is
    /// `/name` over its description (`:1972-1973`). Ours are Claude Code's own
    /// commands and skills, both invoked as `/name` — upstream's `/skill:`
    /// prefix (`:1983`) would misstate what the row inserts.
    private func menuItems(_ trigger: T3ComposerTrigger.Detected) -> [T3ComposerMenuItem] {
        switch trigger.kind {
        case .command:
            return SlashCommands.filter(commands, query: trigger.query)
                .prefix(T3FileMention.limit)
                .map { T3ComposerMenuItem(id: $0.id, label: "/\($0.name)",
                                          description: $0.description, icon: nil) }
        case .mention:
            return mentionRows.map { path in
                T3ComposerMenuItem(id: "path:\(path)",
                                   label: (path as NSString).lastPathComponent,
                                   description: (path as NSString).deletingLastPathComponent,
                                   icon: .file)
            }
        }
    }

    /// `resolveComposerMenuActiveItemId` (`composerMenuHighlight.ts`).
    private func activeItemID(_ items: [T3ComposerMenuItem],
                             _ trigger: T3ComposerTrigger.Detected) -> String? {
        menu.activeItemID(items.map(\.id), trigger: trigger)
    }

    /// `ComposerCommandMenu.tsx:113-127`: `isLoading` wins over the empty
    /// copy. Upstream's loading line names files because only its path and
    /// skill triggers search; ours reads command files off disk too, so that
    /// menu says so instead of claiming to search files.
    private func menuEmptyText(_ trigger: T3ComposerTrigger.Detected) -> String {
        switch trigger.kind {
        case .command:
            return commandLoading ? "Searching workspace commands..." : "No matching command."
        case .mention:
            return mentionLoading ? "Searching workspace files..." : "No matching files or folders."
        }
    }

    /// A menu opening (and only that) loads its source: `SlashCommands.discover`
    /// reads every command file and `T3FileMention.list` runs `git ls-files`,
    /// so both go to `T3WindowModel`'s per-cwd cache on a detached task, which
    /// serves what it has at once and refreshes behind it.
    private func openMenu(_ kind: T3ComposerTrigger.Kind?) {
        menu.opened()
        // The overlay leaves the tree with its trigger, and a removed view
        // reports no preference — without this a later open would render one
        // frame lifted by the last menu's height.
        if kind == nil { menuHeight = 0 }
        guard let kind, let cwd else { return }
        switch kind {
        case .command:
            commands = model.cachedSlashCommands(cwd: cwd)
            commandLoading = commands.isEmpty
            Task {
                let discovered = await model.slashCommands(cwd: cwd)
                guard self.cwd == cwd, trigger?.kind == .command else { return }
                commands = discovered
                commandLoading = false
            }
        case .mention:
            if mentionCwd != cwd { mentionRows = [] }
            mentionLoading = true
            rankMentions(trigger)
            Task {
                _ = await model.fileMentions(cwd: cwd)
                guard self.cwd == cwd, trigger?.kind == .mention else { return }
                rankMentions(trigger)
            }
        }
    }

    /// The `@` rows for the query as it stands. The ranking runs off the main
    /// actor (a monorepo is 20 000 paths); a result whose query has moved on is
    /// dropped, and the rows in view stay until the new ones arrive — upstream
    /// leaves the previous entries up while its search is `isPending` too
    /// (`ComposerCommandMenu.tsx:116-119`).
    private func rankMentions(_ found: T3ComposerTrigger.Detected?) {
        guard let cwd, let found, found.kind == .mention else { return }
        let query = found.query
        // One rank in flight: the next keystroke abandons the previous query's
        // before asking for its own, so on a 20 000-path checkout a stale rank
        // can no longer land after the newest one. (The detached scan itself
        // runs to its end — `rank` is a pure function — but a cancelled task
        // never publishes its rows.)
        rankTask?.cancel()
        rankTask = Task {
            let rows = await model.mentionRows(cwd: cwd, query: query)
            guard !Task.isCancelled, self.cwd == cwd, let current = self.trigger,
                  current.kind == .mention, current.query == query else { return }
            mentionRows = rows
            mentionCwd = cwd
            mentionLoading = false
        }
    }

    private func highlight(_ id: String) {
        guard let trigger else { return }
        menu.highlight(id, trigger: trigger)
    }

    /// `onComposerCommandKey` (`ChatComposer.tsx:3080-3125`): while a menu is
    /// open it takes ↑/↓ and ⏎/⇥ first, and only then does the key fall
    /// through to prompt recall and to sending. False = the field keeps the key.
    private func menuKey(_ key: T3ComposerMenuKey) -> Bool {
        // Computed once, only when a trigger is open: `menuItems` reads the
        // command/mention caches, not worth it for the common no-menu key.
        guard let trigger else { return false }
        let items = menuItems(trigger)
        switch menu.key(key, trigger: trigger, itemIDs: items.map(\.id)) {
        case .moved, .dismissed:
            return true
        case .pick(let id):
            if let item = items.first(where: { $0.id == id }) { pick(item) }
            return true
        case .unhandled:
            return false
        }
    }
    /// `onSelectComposerItem`: the trigger span is replaced by what the row
    /// inserts and the caret follows it (`replaceTextRange`,
    /// `composerTrigger.ts:118-128`). The insertion ends in a space, so no
    /// trigger is under the caret afterwards and the menu closes on its own.
    private func pick(_ item: T3ComposerMenuItem) {
        guard let trigger else { return }
        let insertion: String
        switch trigger.kind {
        case .command:
            guard let command = commands.first(where: { $0.id == item.id }) else { return }
            insertion = command.insertion
        case .mention:
            insertion = T3FileMention.insertion(for: String(item.id.dropFirst("path:".count)))
        }
        let result = T3ComposerTrigger.replacing(draft.text, start: trigger.start,
                                                 end: trigger.end, with: insertion)
        draft.text = result.text
        caret = result.caret
        caretRequest = result.caret
        recall = nil
        menu.picked()
        // `onMouseDown` `preventDefault` (`ComposerCommandMenu.tsx:158-160`)
        // keeps a click on a row from taking focus off the editor; a SwiftUI
        // tap gives no such promise, so the field is asked back.
        focusRequest = true
    }

    /// `stepComposerPromptHistory` (`composerPromptHistory.ts:183-211`) —
    /// the rules live in `T3ComposerDrafts.stepHistory`; this only moves the
    /// field and the position. False leaves the key to normal caret movement.
    private func step(recall direction: Int) -> Bool {
        guard let step = T3ComposerDrafts.stepHistory(history: model.promptHistory,
                                                      index: recall?.index,
                                                      current: draft.text,
                                                      direction: direction)
        else { return false }
        self.recall = step.index.map { ($0, step.text) }
        draft.text = step.text
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

    private var birth: SessionBirth? { livePid.flatMap { app.sessionBirths[Int($0)] } }
    /// `SessionProgress.model`, off the newest transcript entry that names one
    /// (SessionProgress.swift:52-56).
    private var sessionModel: String? {
        livePid.flatMap { app.sessionProgress.byPid[Int($0)]?.model }
    }
    private var currentMode: String? { draftTarget == nil ? birth?.effectiveMode : startMode }
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
        // Draft mode picks the mode the session is BORN in, which has no floor
        // to respect yet — `SessionStart.permissionModes` (the four
        // `--permission-mode` values), not the running-session hook modes.
        // Until one is picked there is no flag at all, which is "Supervised".
        if draftTarget != nil { return SessionStart.permissionModes }
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
    /// The size was stat'ed when the file was staged: a body runs on every
    /// keystroke, and a file read there would too. A draft persisted before
    /// `bytes` existed has none, and is the one case worth a stat.
    private static func size(of attachment: T3ComposerAttachmentRef) -> String {
        let bytes = attachment.bytes ?? (try? URL(fileURLWithPath: attachment.path)
            .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
