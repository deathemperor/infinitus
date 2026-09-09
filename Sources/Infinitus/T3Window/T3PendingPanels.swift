import SwiftUI
import AppKit
import InfinitusCore
import InfinitusUI

/// The composer's attached drawers: the banner stack
/// (`components/chat/ComposerBannerStack.tsx` over `ComposerBanner.tsx`) and the
/// top drawer that holds either a pending approval
/// (`ComposerPendingApprovalPanel.tsx` + `ComposerPendingApprovalActions.tsx`),
/// or a pending question (`ComposerPendingUserInputPanel.tsx`) — the first two
/// branches of `ChatComposer.tsx:4805-4846`, in that order.
///
/// Every verdict leaves through `T3ThreadActions`, which wraps
/// `AppModel.deliverSessionInput(pid:_:from:)` exactly as the shipped Mac chat
/// window's `SessionChatStore.send` does (SessionChatWindow.swift:135-150), so
/// the workspace window and that window put the same bytes on the wire.
///
/// Not ported, each with its reason at the call site: the peek's hover
/// choreography and the 220 ms dismiss transition (`ComposerBannerStack.tsx:9`,
/// `:151-175`), the `--chat-composer-attachment-overlap` mask that slides an
/// attached banner under the composer surface (there is no composer surface
/// until Task 13), the description popover on a narrow container
/// (`:290-311`), the number-key shortcuts (`ComposerPendingUserInputPanel.tsx:141-166`
/// guards on focus not being in an editable field — no SwiftUI equivalent, and
/// Task 13's composer would lose its digits), and single-select auto-advance
/// (`:126-132`, a 200 ms timer). The drawer's third branch,
/// `ComposerPlanFollowUpBanner` (`ChatComposer.tsx:4841-4845`), is not ported
/// either: it needs an actionable proposed plan and B has no producer for one —
/// a parked `ExitPlanMode` arrives as an `approval.requested`, so the first
/// branch already claims the drawer.

// MARK: - Delivery

/// One owner for the panels' side effects: `sending` and `note` published the
/// way `SessionChatStore` publishes them (SessionChatWindow.swift:135-150) —
/// an outcome other than "delivered" becomes the note the stack shows.
///
/// `app` and `pid` are parameters rather than stored: `deliverSessionInput` is
/// `nonisolated` and blocking (it lists sessions and writes a pty or stdin), so
/// it runs on a detached task, and `T3TimelineStore.pid` changes under a resume
/// (`rebind(pid:)`) — reading it per send is what keeps a verdict aimed at the
/// session on screen.
@MainActor
final class T3ThreadActions: ObservableObject {
    @Published private(set) var sending = false
    @Published var note: String?

    /// `nonisolated` so a `@State` in a (nonisolated) `View` initialiser can
    /// make one without a hop.
    nonisolated init() {}

    /// `onOutcome` runs on the main actor once the reply is in, for a caller
    /// that has to know what the session did with it — Task 13's queue badge
    /// only counts a message the session actually took.
    func send(_ request: SessionInput.Request, app: AppModel, pid: Int32,
              onOutcome: ((SessionInput.Reply) -> Void)? = nil) {
        guard !sending else { return }
        sending = true
        note = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            let reply = app.deliverSessionInput(pid: pid, request, from: "workspace")
            await MainActor.run {
                self?.sending = false
                if reply.outcome != "delivered" {
                    self?.note = reply.detail.map { "\(reply.outcome) — \($0)" } ?? reply.outcome
                }
                onOutcome?(reply)
            }
        }
    }

    /// Deny. A plain deny is key `3` through the same path as the shipped chat
    /// window (SessionChatWindow.swift:302) — `OwnedWire.decision(forKey:)`
    /// answers it with `OwnedWire.denyMessage`. A typed reason has no
    /// `SessionInput.Request.Kind` to ride, so it goes straight to the owned
    /// child as `Decision.deny(message:)` through
    /// `OwnedSessions.answer(pid:requestId:decision:)` (OwnedSessions.swift:390)
    /// — which is exactly why the reason field is owned-only.
    func deny(app: AppModel, pid: Int32, requestId: String, reason: String) {
        let message = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            send(.init(kind: .key, text: "3"), app: app, pid: pid)
            return
        }
        guard !sending else { return }
        sending = true
        note = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            // `.existing`, never `ownedSessions()`: a request into a session
            // nobody owns must not pay for locating `claude`
            // (OwnedSessionsBox.swift:8-10). An unowned pid cannot reach here —
            // the field only exists when the session is owned.
            let ok = app.ownedBox.existing?.answer(pid: pid, requestId: requestId,
                                                   decision: .deny(message: message)) ?? false
            await MainActor.run {
                self?.sending = false
                if !ok { self?.note = "rejected — the session is no longer waiting on this request" }
            }
        }
    }
}

// MARK: - What the panels read

/// A parked permission as the panel renders it: the tool, the rendered input
/// (the feed's own `describeTool` signals) and the "allow for this session"
/// rule built from that same text. The phone's `T3Pending.Approval`
/// (ios/InfinitusMobile/T3/T3Pending.swift:10-19) is the same shape; it lives
/// in the phone target, so the Mac gets this copy rather than a Core move.
struct T3PendingApprovalItem: Equatable {
    let requestId: String
    let toolName: String
    let detail: String

    init(requestId: String, toolName: String, detail: String) {
        self.requestId = requestId
        self.toolName = toolName
        self.detail = detail
    }

    init(_ approval: PendingRequests.PendingApproval) {
        requestId = approval.requestId
        toolName = approval.toolName
        detail = Self.renderedInput(tool: approval.toolName, approval.input, summary: approval.summary)
    }

    /// The "allow for this session" rule, read off the same text the panel
    /// shows (`T3Pending.Approval.rule`, `:14`).
    var rule: ToolApproval.Rule { .from(tool: toolName, input: detail) }
    /// `ToolApproval.encode`'s wire form, the `text` of a `.approve` request
    /// (SessionChatWindow.swift:305-306).
    var sessionApproval: String { ToolApproval.encode(tool: toolName, input: detail) }

    /// `T3Pending.renderedInput` (`:93-101`): a Bash command, a file path, else
    /// the input's JSON — the same text the feed shows for a permission.
    static func renderedInput(tool: String, _ input: JSONValue?, summary: String) -> String {
        guard let object = input?.objectValue, !object.isEmpty else { return summary }
        if tool == "Bash", let command = object["command"]?.stringValue { return command }
        if let path = object["file_path"]?.stringValue { return path }
        if let data = try? JSONEncoder().encode(input), let text = String(data: data, encoding: .utf8) { return text }
        return summary
    }

    /// `ComposerPendingApprovalPanel.tsx:16-23`'s `fallbackLabel`, keyed off
    /// `requestType` there and off the tool here (B has no `requestKind`).
    static func fallbackLabel(tool: String) -> String {
        switch tool {
        case "Bash": return "Command approval"
        case "Read", "Glob", "Grep", "NotebookRead": return "File read approval"
        default: return "File change approval"
        }
    }
}

/// One question of a parked `AskUserQuestion`, decoded from the activity
/// payload the way the phone decodes it (`T3Pending.derive`,
/// ios/InfinitusMobile/T3/T3Pending.swift:69-81).
struct T3PendingQuestionItem: Identifiable, Equatable {
    struct Option: Identifiable, Equatable {
        let label: String
        let description: String
        var id: String { label }
    }
    /// Upstream's `question.id`; the option rows key off it.
    let id: String
    /// The `answers` JSON *key*: `OwnedWire.decision(answers:pending:)` looks
    /// each answer up by the question's TEXT (OwnedWire.swift:280), so this is
    /// what the encoder must use — never `id`.
    let question: String
    let header: String
    let multiSelect: Bool
    /// `allowCustomAnswer: Schema.optional(Schema.Boolean)`
    /// (`providerRuntime.ts:539`) — absent means allowed, and only an
    /// explicit `false` withdraws the free-text field
    /// (`pendingUserInput.ts:45`). A `var` so the memberwise init defaults it.
    var allowCustomAnswer = true
    let options: [Option]

    static func parse(_ questions: [JSONValue]) -> [T3PendingQuestionItem] {
        questions.compactMap { q in
            guard let o = q.objectValue, let text = o["question"]?.stringValue else { return nil }
            let options = (o["options"]?.arrayValue ?? []).compactMap { opt -> Option? in
                guard let d = opt.objectValue, let label = d["label"]?.stringValue else { return nil }
                return Option(label: label, description: d["description"]?.stringValue ?? "")
            }
            guard !options.isEmpty else { return nil }
            return T3PendingQuestionItem(id: o["id"]?.stringValue ?? text, question: text,
                                         header: o["header"]?.stringValue ?? "",
                                         multiSelect: o["multiSelect"].map { $0 == .bool(true) } ?? false,
                                         allowCustomAnswer: o["allowCustomAnswer"] != .bool(false),
                                         options: options)
        }
    }
}

// MARK: - Banner primitives

/// `ComposerBannerVariant` (`ComposerBanner.tsx:10`) and its `variantColors`
/// (`:26-33`): the tint is the severity at 8 %, which is exactly what the
/// generated `errorSurface`/`warningSurface` tokens hold, and the outline is
/// the severity at 32 %/28 % — everything else uses `neutralOutline`
/// (`--chat-composer-outline`, the port's `border`).
enum T3BannerVariant {
    case `default`, error, info, success, warning

    func tint(_ p: T3Theme.WebPalette) -> Color {
        switch self {
        case .error: return p.errorSurface.color
        case .warning: return p.warningSurface.color
        default: return .clear
        }
    }
    func outline(_ p: T3Theme.WebPalette) -> Color {
        switch self {
        case .error: return p.error.color.opacity(0.32)
        case .warning: return p.warning.color.opacity(0.28)
        default: return p.border.color
        }
    }
}

/// `ComposerBanner.Surface` + `.Root` (`:36-118`, `:141-170`): the glass
/// surface (light `--card`, dark `--surface-raised` — the same value in this
/// port's dark palette), `border`, the variant tint over it, `px-1` and a
/// `--composer-banner-padding-block` of 4 (`--spacing(1)`) or 5 when
/// `density="comfortable"` (`--spacing(1.25)`).
///
/// `attached` rounds only the top (`before:rounded-t-[16px]`); a floating
/// notice rounds all four (`before:rounded-[1rem]`). The
/// `--chat-composer-attachment-overlap` negative margin and its mask are not
/// ported: nothing sits under the drawer until Task 13's composer does.
private struct T3BannerRoot<Content: View>: View {
    var variant: T3BannerVariant = .default
    var attached = true
    var comfortable = false
    @ViewBuilder let content: Content
    @Environment(\.t3) private var t3

    var body: some View {
        let p = t3.web
        // `text-xs/4` on the Root: 12 pt with a 16 pt line box.
        content
            .font(T3Font.web(.xs))
            .padding(.horizontal, 4)
            .padding(.vertical, comfortable ? 5 : 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape
                    .fill(p.card.color)
                    .overlay(shape.fill(variant.tint(p)))
                    .overlay(shape.stroke(variant.outline(p), lineWidth: 1))
            }
    }

    private var shape: some InsettableShape {
        // `rounded-t-[16px]` / `rounded-[1rem]`.
        UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: attached ? 0 : 16,
                               bottomTrailingRadius: attached ? 0 : 16, topTrailingRadius: 16,
                               style: .continuous)
    }
}

/// `--composer-banner-icon-column`: `--spacing(6)` = 24 from `sm` up
/// (`ComposerBanner.tsx:144`), which every Mac window is.
private let t3BannerIconColumn: Double = 24

/// `ComposerBanner.Row` (`:172-202`) with its `.Icon` (`:204`), `.Content`
/// (`:218`) and `.Actions` (`:245`) slots: a
/// `grid-cols-[var(--composer-banner-icon-column)_minmax(0,1fr)_auto]` with
/// `gap-x-1` and `min-h-(--composer-banner-icon-column)` — the icon column is
/// `--spacing(6)` = 24 at `sm` and up, which every Mac window is.
private struct T3BannerRow<Content: View, Actions: View>: View {
    var icon: Lucide? = nil
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions
    @Environment(\.t3) private var t3

    var body: some View {
        HStack(spacing: 4) {
            // Upstream keeps the column even with no glyph in it
            // (`<ComposerBanner.Icon />`, ChatComposer.tsx:4813) — the content
            // aligns across rows either way. `[&>svg]:size-3` = 12.
            Group {
                if let icon { LucideIcon(icon, size: 12).foregroundStyle(t3.web.mutedForeground.color) }
            }
            .frame(width: t3BannerIconColumn)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .frame(minHeight: t3BannerIconColumn)
    }
}

/// `ComposerBanner.Body` (`:299`): `ps-[calc(var(--composer-banner-icon-column)+(--spacing(1)))]`
/// — a block under a row, aligned with that row's content column.
private struct T3BannerBody<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(.leading, t3BannerIconColumn + 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `Button size="micro" variant="ghost-muted"` (`ui/button.tsx:32`, `:47`):
/// `h-5 rounded-sm px-1.5 text-[11px]`, `muted-foreground` going `foreground`
/// on hover with an `accent` fill. The tint overrides the label colour the way
/// `ComposerPendingApprovalActions.tsx:43-51` does per decision.
private struct T3BannerActionButton: View {
    let title: String
    var icon: Lucide? = nil
    var tint: Color? = nil
    let action: () -> Void
    @Environment(\.t3) private var t3
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {   // `gap-1`
                if let icon { LucideIcon(icon, size: 12) }   // `[&_svg]:size-3`
                // `APPROVAL_ACTION_CLASS_NAME = "font-normal"` (`:21`).
                Text(title).font(T3Font.webLiteral(11)).lineLimit(1)
            }
            .foregroundStyle(tint ?? (hover ? t3.web.foreground.color : t3.web.mutedForeground.color))
            .padding(.horizontal, 6)
            .frame(height: 20)
            // `rounded-sm` = `calc(var(--radius) - 4px)`.
            .background(hover ? t3.web.accent.color : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// `ComposerBanner.Dismiss` (`:335`): `Button size="icon-xs" variant="ghost"`
/// (24 pt square) around lucide `x` at 14.
private struct T3BannerDismissButton: View {
    let label: String
    let action: () -> Void
    @Environment(\.t3) private var t3
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            LucideIcon(.x, size: 14)
                .foregroundStyle(t3.web.mutedForeground.color)
                .frame(width: 24, height: 24)
                .background(hover ? t3.web.accent.color : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(label)
    }
}

// MARK: - Banner stack

/// `ComposerBannerStackItem` (`ComposerBannerStack.tsx:12-23`). `children` is
/// `[String]` rather than a view: the only child body B produces is the usage
/// limits list, which is a list of sentences (`LimitNote.text`).
struct T3BannerItem: Identifiable {
    enum Priority { case activity, urgent, notice }
    let id: String
    var variant: T3BannerVariant = .default
    var priority: Priority?
    var icon: Lucide?
    var title: String
    var description: String?
    var children: [String] = []
    var dismissLabel: String?
    var dismiss: (() -> Void)?

    /// `bannerPriority` (`:32-40`): activity stays attached, urgency and
    /// severity only order the notices behind it.
    var order: Int {
        if priority == .activity { return 0 }
        if priority == .urgent || variant == .error || variant == .warning { return 1 }
        return 2
    }
}

/// `ComposerBannerStack` (`:47-241`): the front item is the attached banner,
/// the rest hide behind a peek cap that opens them as floating notices above
/// it. The stack renders bottom-up (`flex flex-col-reverse`, `:121`).
///
/// The peek opens on click only — upstream also opens on pointer enter
/// (`:151-157`) and animates the dismissal for 220 ms before dropping the item
/// (`:9`, `:109-112`); neither survives the port to a value-typed list without
/// a timer, and this window's budget is zero idle work.
struct T3BannerStack: View {
    let items: [T3BannerItem]
    @State private var expanded = false
    @Environment(\.t3) private var t3

    private var ordered: [T3BannerItem] {
        items.enumerated().sorted { l, r in
            l.element.order == r.element.order ? l.offset < r.offset : l.element.order < r.element.order
        }.map(\.element)
    }

    var body: some View {
        let ordered = ordered
        if let front = ordered.first {
            let stacked = Array(ordered.dropFirst())
            VStack(spacing: 0) {
                if !stacked.isEmpty {
                    if expanded {
                        // `space-y-2 pb-2` on the expanded notices (`:209`).
                        VStack(spacing: 8) {
                            ForEach(stacked) { alert($0, attached: false) }
                        }
                        .padding(.bottom, 8)
                    } else {
                        peek(variant: stacked[0].variant)
                    }
                }
                alert(front, attached: true)
            }
            .onChange(of: items.count) { _, count in if count < 2 { expanded = false } }
        }
    }

    /// `ComposerBanner.Peek` (`:80-104`): `h-3 w-[96%] rounded-t-2xl` with the
    /// first hidden notice's severity on its border.
    private func peek(variant: T3BannerVariant) -> some View {
        Button { expanded = true } label: {
            UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16, style: .continuous)
                .fill(t3.web.card.color)
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16, style: .continuous)
                    .stroke(variant.outline(t3.web), lineWidth: 1))
                .frame(height: 12)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)   // stands in for `w-[96%] mx-auto`
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show other notices")
    }

    /// `ComposerBannerStackAlert` (`:243-331`).
    private func alert(_ item: T3BannerItem, attached: Bool) -> some View {
        T3BannerRoot(variant: item.variant, attached: attached, comfortable: true) {
            VStack(alignment: .leading, spacing: 1) {   // `.Children`'s `gap-px`
                T3BannerRow(icon: item.icon) {
                    HStack(spacing: 4) {
                        // `font-medium leading-7 sm:leading-6`, truncating.
                        Text(item.title)
                            .font(T3Font.web(.xs, .medium))
                            .foregroundStyle(t3.web.foreground.color)
                            .lineLimit(1)
                        if let description = item.description {
                            Text(description)
                                .font(T3Font.web(.xs))
                                .foregroundStyle(t3.web.mutedForeground.color)
                                .lineLimit(1)
                        }
                    }
                } actions: {
                    if let dismiss = item.dismiss {
                        T3BannerDismissButton(label: item.dismissLabel ?? "Dismiss warning", action: dismiss)
                    }
                }
                if !item.children.isEmpty {
                    // `ComposerBanner.Children` (`:262`) + the usage-limits
                    // `.Body` (`ComposerUsageLimits.tsx:58`, `gap-2 pt-1 pb-1.5 pe-2`).
                    T3BannerBody {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(item.children, id: \.self) { line in
                                Text(line)
                                    .font(T3Font.web(.xs))
                                    .foregroundStyle(t3.web.mutedForeground.color)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.top, 4)
                        .padding(.bottom, 6)
                        .padding(.trailing, 8)
                    }
                }
            }
        }
    }
}

extension T3BannerItem {
    /// `usageLimitsBannerItem` (`ComposerUsageLimits.tsx:24-46`): the limits
    /// report as a dismissible `info` notice. B's report is the session's own
    /// `LimitNote`s — no account list and no windows to gauge, just one
    /// sentence each (`LimitNote.text`, OwnedWire.swift:142) — so the caller
    /// passes those sentences and each becomes a child line.
    static func usageLimits(notes: [String], dismiss: @escaping () -> Void) -> T3BannerItem {
        T3BannerItem(id: "usage-limits", variant: .info, priority: .notice, icon: .gauge,
                     title: "Usage limits",
                     description: notes.count == 1 ? nil : "\(notes.count) windows",
                     children: notes,
                     dismissLabel: "Dismiss usage limits", dismiss: dismiss)
    }

    /// `ThreadErrorBanner` (`ThreadErrorBanner.tsx:36-70`) as a stack entry —
    /// upstream renders it as a floating `Alert` over the composer; the stack
    /// is where `ChatView.tsx:5698` collects the composer's own error items,
    /// and one place for every notice keeps the drawer's geometry honest.
    static func error(id: String, message: String, dismiss: (() -> Void)?) -> T3BannerItem {
        T3BannerItem(id: id, variant: .error, priority: .urgent, icon: .circleAlert,
                     title: message, dismissLabel: "Dismiss error", dismiss: dismiss)
    }
}

// MARK: - Pending approval

/// `ComposerPendingApprovalPanel.tsx` inside its top-drawer Root
/// (`ChatComposer.tsx:4805-4830`, `variant="warning"` while an approval is
/// parked) with `ComposerPendingApprovalActions.tsx`'s buttons.
///
/// The wire is the shipped Mac chat window's (SessionChatWindow.swift:300-316):
/// Approve = key `1`, Decline = key `3`, "Always allow this session" =
/// `.approve` carrying `ToolApproval.encode(tool:input:)`. On an owned session
/// each of those answers `pending(pid:).first` (OwnedSessions.swift:421,
/// `:445`), which is the approval this panel renders — upstream shows the first
/// of `pendingApprovals` too (`ComposerPendingApprovalPanel` gets
/// `activePendingApproval`).
struct T3PendingApprovalPanel: View {
    let approval: T3PendingApprovalItem
    /// `pendingCount` (`:6`): the `1/N` marker when more than one waits.
    let pendingCount: Int
    /// The one owned-only control is the deny reason: `Decision.deny(message:)`
    /// has no `SessionInput.Request.Kind` to ride, so it can only reach a
    /// session the app runs. Every other button works on any session.
    let owned: Bool
    let sending: Bool
    let onApprove: () -> Void
    let onAllowSession: () -> Void
    let onDeny: (String) -> Void
    @State private var reason = ""
    @Environment(\.t3) private var t3

    var body: some View {
        T3BannerRoot(variant: .warning) {
            VStack(alignment: .leading, spacing: 4) {
                T3BannerRow {
                    // `<code aria-label=… class="block max-h-20 min-w-0 flex-1
                    // overflow-auto whitespace-pre font-mono text-[11px]
                    // text-foreground/85">` (`:44-51`).
                    HStack(spacing: 8) {
                        Text(approval.detail.isEmpty
                             ? T3PendingApprovalItem.fallbackLabel(tool: approval.toolName)
                             : approval.detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(t3.web.foreground.color.opacity(0.85))
                            // Upstream scrolls this surface to `max-h-20` (80);
                            // a SwiftUI ScrollView cannot size to its content
                            // up to a cap without a measurement pass, so it
                            // truncates at the same five 16 pt lines instead.
                            .lineLimit(5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel(approval.toolName)
                        if pendingCount > 1 {
                            // `text-[10px] font-medium text-muted-foreground tabular-nums` (`:53`).
                            Text("1/\(pendingCount)")
                                .font(T3Font.webLiteral(10, .medium))
                                .monospacedDigit()
                                .foregroundStyle(t3.web.mutedForeground.color)
                        }
                    }
                } actions: {
                    actions
                }
                if owned {
                    // No upstream equivalent: the web client's decisions carry
                    // no reason. `OwnedWire.Decision.deny(message:)` does, and
                    // the controller asked for the field — so it exists only
                    // where that decision can be delivered.
                    T3BannerBody {
                        T3Input(text: $reason, placeholder: "Reason for declining (optional)")
                            .padding(.trailing, 4)
                    }
                }
            }
            .disabled(sending)
        }
        .accessibilityLabel(T3PendingApprovalItem.fallbackLabel(tool: approval.toolName))
    }

    /// `DEFAULT_APPROVAL_OPTIONS` (`ComposerPendingApprovalActions.tsx:22-27`)
    /// minus `cancel`, which has no wire on B — nothing can retract a parked
    /// Claude Code prompt without answering it.
    private var actions: some View {
        HStack(spacing: 4) {   // `.Actions`' `gap-1`
            T3BannerActionButton(title: "Decline", tint: t3.web.destructiveForeground.color) {
                onDeny(reason)
            }
            // Plain ghost-muted, no glyph: the triangle and the warning tint
            // are `option.warning`'s (`:48-49`, `:56`), and
            // `DEFAULT_APPROVAL_OPTIONS` sets no warning on `acceptForSession`
            // (`:22-27`).
            //
            // Ownership-independent, like the shipped chat window's own button
            // (SessionChatWindow.swift:304-307): `deliverSessionInput` rewrites
            // `.approve` into `.key "1"` before any owned path runs
            // (AppModel.swift:1723-1728) and records the rule with
            // `toolApprovals.add(rule, sessionId:)`. What enforces it is the
            // plugin's PreToolUse hook, which asks the app per session id
            // (ControlServer.swift:341) — the terminal path this feature was
            // built for (#79, ToolApproval.swift:3-6).
            // `ExitPlanMode` has no upstream "always allow" slot either —
            // it shows the plan follow-up banner there instead (`:26-30`
            // above), which B doesn't port; suppressing the button rather
            // than wiring it to a plan it can't reason about.
            if approval.toolName != "ExitPlanMode" {
                T3BannerActionButton(title: "Always allow this session", action: onAllowSession)
                    .accessibilityHint("Allows \(approval.rule.label) for the rest of this session")
            }
            T3BannerActionButton(title: "Approve", tint: t3.web.foreground.color, action: onApprove)
            if sending { T3Spinner(size: 12) }
        }
    }
}

// MARK: - Pending user input

/// What a question panel can put on the wire.
enum T3PendingSubmission: Equatable {
    /// Every question at once, `SessionInput.Answers.encode`'s JSON
    /// (`SessionInput.swift:119-125`) — owned sessions only.
    case answers(String)
    /// The Nth option of the first question, as Claude Code's own menu key
    /// (`OwnedWire.decision(forKey:)`, OwnedWire.swift:293-301).
    case key(String)
}

/// `ComposerPendingUserInputPanel.tsx` (`ComposerPendingUserInputCard`,
/// `:50-293`): the active question's header as a collapsible trigger row, then
/// the question, an optional "Select one or more options.", and the options as
/// rows carrying their shortcut number or a check when picked.
///
/// Two deviations, both forced by the wire and the task split:
/// - the primary action lives here. Upstream's Previous / "Next question" /
///   "Submit answer(s)" sit in the composer's own footer
///   (`ComposerPrimaryActions.tsx:40-56`, `:110-161`), which is Task 13.
/// - the free-text answer lives here too, as a field under the options.
///   Upstream types it into the composer instead (`ChatComposer.tsx:4881`
///   "Write custom answer", `:4987` "Type your own answer, or leave this
///   blank to use the selected option"); this port follows the phone's
///   layout, which puts the same field inside the card
///   (`apps/mobile/.../PendingUserInputCard.tsx:308-318`) — B's composer is
///   already carrying the next prompt, and one draft cannot be both.
struct T3PendingUserInputPanel: View {
    let questions: [T3PendingQuestionItem]
    /// A terminal-hosted session answers by menu key: one question, one pick
    /// (the phone does the same, ios/.../T3PendingCards.swift:60).
    let owned: Bool
    let sending: Bool
    let onSubmit: (T3PendingSubmission) -> Void
    @State private var questionIndex = 0
    @State private var picks: [String: Set<String>] = [:]
    /// Upstream's `draft.customAnswer`, per question id.
    @State private var custom: [String: String] = [:]
    @State private var collapsed = false
    @Environment(\.t3) private var t3

    private var visible: [T3PendingQuestionItem] { owned ? questions : Array(questions.prefix(1)) }
    private var active: T3PendingQuestionItem? {
        let index = min(max(0, questionIndex), max(0, visible.count - 1))
        return visible.indices.contains(index) ? visible[index] : nil
    }
    private var isLastQuestion: Bool { questionIndex >= visible.count - 1 }

    /// `buildPendingUserInputAnswers` (`pendingUserInput.ts:100-115`) against
    /// this port's encoder: every question answered, a multi-select's labels
    /// joined by `SessionInput.Answers.separator` in option order, keyed by the
    /// question text (what `OwnedWire.decision(answers:)` looks up).
    private var submission: T3PendingSubmission? {
        if owned {
            var out: [String: String] = [:]
            for q in visible {
                if let typed = typedAnswer(q) {
                    // `resolvePendingUserInputAnswer` (`pendingUserInput.ts:40-57`)
                    // returns the custom answer over the selection, and
                    // `OwnedWire.decision(answers:pending:)` takes one non-option
                    // string per question as Claude Code's "Other"
                    // (OwnedWire.swift:283-289).
                    out[q.question] = typed
                    continue
                }
                let chosen = q.options.map(\.label).filter { picks[q.id]?.contains($0) == true }
                guard !chosen.isEmpty else { return nil }
                out[q.question] = chosen.joined(separator: SessionInput.Answers.separator)
            }
            return .answers(SessionInput.Answers.encode(out))
        }
        guard let q = visible.first, let label = picks[q.id]?.first,
              let i = q.options.firstIndex(where: { $0.label == label }), i < 9 else { return nil }
        return .key(String(i + 1))
    }

    /// `normalizeDraftAnswer` (`pendingUserInput.ts:22-28`): trimmed, and nil
    /// when empty or when the question withdrew the field. Terminal sessions
    /// never have one — only a menu key reaches them.
    ///
    /// One shape more has no wire and so is no answer here either: a
    /// multi-select whose text carries `Answers.separator`.
    /// `OwnedWire.decision(answers:pending:)` (OwnedWire.swift:285-288) splits
    /// a multi-select's answer on it and needs every part to be an option, so
    /// that text can only be rejected. Refusing it in *this* one place keeps
    /// `answered` and `submission` on one rule — deciding it in `submission`
    /// alone let "Next question" pass an undeliverable answer and killed
    /// Submit two questions later, with the offending field off-screen.
    private func typedAnswer(_ q: T3PendingQuestionItem) -> String? {
        guard owned, q.allowCustomAnswer else { return nil }
        let trimmed = (custom[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return q.multiSelect && trimmed.contains(SessionInput.Answers.separator) ? nil : trimmed
    }

    /// Text typed into a multi-select's field that `typedAnswer` has to drop.
    private func separatorInMultiSelectText(_ q: T3PendingQuestionItem) -> Bool {
        guard owned, q.allowCustomAnswer, q.multiSelect else { return false }
        return (custom[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .contains(SessionInput.Answers.separator)
    }

    /// `setPendingUserInputCustomAnswer` (`pendingUserInput.ts:60-71`): a
    /// non-empty custom answer drops the question's selected options, which is
    /// what clears the checks (upstream hides them instead, through
    /// `customAnswerActive`, `ComposerPendingUserInputPanel.tsx:172`, `:244`).
    private func customBinding(_ q: T3PendingQuestionItem) -> Binding<String> {
        Binding(get: { custom[q.id] ?? "" },
                set: { value in
                    custom[q.id] = value
                    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { picks[q.id] = [] }
                })
    }

    var body: some View {
        T3BannerRoot(variant: .info) {
            VStack(alignment: .leading, spacing: 0) {
                trigger
                if !collapsed, let active {
                    // `CollapsiblePanel` > `.Body className="pe-1 pb-1"` (`:231`).
                    T3BannerBody {
                        VStack(alignment: .leading, spacing: 0) {
                            // `text-sm text-foreground/85` (`:232`).
                            Text(active.question)
                                .font(T3Font.web(.sm))
                                .foregroundStyle(t3.web.foreground.color.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                            if active.multiSelect {
                                // `mt-1 text-secondary-label text-xs` (`:234`).
                                Text("Select one or more options.")
                                    .font(T3Font.web(.xs))
                                    .foregroundStyle(t3.web.secondaryLabel.color)
                                    .padding(.top, 4)
                            }
                            // `mt-2 space-y-0.5` (`:236`).
                            VStack(spacing: 2) {
                                ForEach(active.options.indices, id: \.self) { i in
                                    option(active, index: i)
                                }
                                if owned, active.allowCustomAnswer {
                                    // The phone's field (`PendingUserInputCard.tsx:316`),
                                    // sized to this card's rows rather than its
                                    // `min-h-[54px]`.
                                    T3Input(text: customBinding(active), placeholder: "Or type a custom answer")
                                        .padding(.top, 4)
                                        .accessibilityLabel("Write custom answer")
                                        .accessibilityHint("Answers in place of the options above")
                                    // Upstream never shows this: its wire carries an
                                    // array, so a comma is just a comma. Ours joins on
                                    // ", ", so on a multi-select that text cannot be
                                    // told from two labels and `typedAnswer` drops it —
                                    // say why, rather than leave Submit dead.
                                    if separatorInMultiSelectText(active) {
                                        Text("A custom answer here can't contain a comma followed by a space — on a multiple-choice question that reads as two options.")
                                            .font(T3Font.web(.xs))
                                            .foregroundStyle(t3.web.warningForeground.color)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .padding(.top, 4)
                                    }
                                }
                            }
                            .padding(.top, 8)
                            primaryActions
                                .padding(.top, 8)
                        }
                        .padding(.trailing, 4)
                        .padding(.bottom, 4)
                    }
                }
            }
            .disabled(sending)
        }
    }

    /// `CollapsibleTrigger render={<ComposerBanner.Row render={<button/>}/>}`
    /// (`:181-229`): the header, the question when collapsed, `i/N` and the
    /// chevron. `prompt.dismissible` is not modelled on B — a parked Claude
    /// Code question has no "close without answering", so no Dismiss.
    private var trigger: some View {
        Button { collapsed.toggle() } label: {
            T3BannerRow {
                HStack(spacing: 4) {
                    if let active, !active.header.isEmpty {
                        Text(active.header)
                            .font(T3Font.web(.xs, .medium))
                            .foregroundStyle(t3.web.mutedForeground.color)
                    }
                    if collapsed, let active {
                        Text(active.question)
                            .font(T3Font.web(.xs))
                            .foregroundStyle(t3.web.secondaryLabel.color)
                            .lineLimit(1)
                    }
                }
            } actions: {
                HStack(spacing: 4) {
                    if visible.count > 1 {
                        // `text-[10px] font-medium text-muted-foreground tabular-nums` (`:201`).
                        Text("\(questionIndex + 1)/\(visible.count)")
                            .font(T3Font.webLiteral(10, .medium))
                            .monospacedDigit()
                            .foregroundStyle(t3.web.mutedForeground.color)
                    }
                    // `ComposerBanner.ToggleIcon` (`:325`): `size-3.5`, rotated
                    // when closed.
                    LucideIcon(.chevronDown, size: 14)
                        .foregroundStyle(t3.web.mutedForeground.color)
                        .rotationEffect(.degrees(collapsed ? 180 : 0))
                        .frame(width: 24, height: 24)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(collapsed ? "Show the question and its options" : "Hide the question and its options")
    }

    /// One option row (`:246-287`): `rounded-md px-2.5 py-2`, `bg-muted/55`
    /// when picked, the label at `text-sm font-medium` over an optional
    /// `text-[11px]` description, and either the `size-3.5` check or the
    /// shortcut number in a `size-5` kbd.
    private func option(_ question: T3PendingQuestionItem, index: Int) -> some View {
        let option = question.options[index]
        let on = picks[question.id]?.contains(option.label) == true
        // A terminal session answers by menu key and `SessionInput.allowedKeys`
        // stops at 9 (SessionInput.swift:141-143) — an option past that has no
        // way to reach the session, so it reads as unavailable rather than
        // picking into a Submit that never enables.
        let unreachable = !owned && index >= 9
        return Button {
            var set = picks[question.id] ?? []
            if on { set.remove(option.label) }
            else if question.multiSelect, owned { set.insert(option.label) }
            else { set = [option.label] }
            picks[question.id] = set
            // `togglePendingUserInputOptionSelection` (`pendingUserInput.ts:75-95`)
            // writes `customAnswer: ""` on every branch: picking an option
            // withdraws the typed answer, or the typed one would still win.
            custom[question.id] = ""
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {   // `gap-0.5`
                    Text(option.label)
                        .font(T3Font.web(.sm, .medium))
                        .foregroundStyle(unreachable ? t3.web.mutedForeground.color
                                         : (on ? t3.web.foreground.color : t3.web.foreground.color.opacity(0.85)))
                        .fixedSize(horizontal: false, vertical: true)
                    if !option.description.isEmpty, option.description != option.label {
                        Text(option.description)
                            .font(T3Font.webLiteral(11))
                            .foregroundStyle(t3.web.secondaryLabel.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if on {
                    LucideIcon(.check, size: 14).foregroundStyle(t3.web.primary.color)
                } else if index < 9 {
                    Text("\(index + 1)")
                        .font(T3Font.webLiteral(10, .medium))
                        .monospacedDigit()
                        .foregroundStyle(t3.web.mutedForeground.color)
                        .frame(width: 20, height: 20)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            // `bg-muted/55` picked, `hover:bg-muted/30` otherwise —
            // `rounded-md` = `calc(var(--radius) - 2px)`.
            .background(on ? t3.web.muted.color.opacity(0.55) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(unreachable)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// `ComposerPrimaryActions.tsx:110-161` — Previous, then
    /// `formatPendingPrimaryActionLabel` (`:40-56`) on the submit button.
    private var primaryActions: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if sending { T3Spinner(size: 12) }
            if questionIndex > 0 {
                T3Button("Previous", variant: .outline, size: .sm) { questionIndex -= 1 }
            }
            T3Button(label, size: .sm) {
                if isLastQuestion {
                    if let submission { onSubmit(submission) }
                } else {
                    questionIndex += 1
                }
            }
            .disabled(sending || (isLastQuestion && submission == nil) || (!isLastQuestion && !answered))
        }
    }

    /// `canAdvance`: the active question has an answer — `resolvedAnswer`,
    /// so a typed one counts (`pendingUserInput.ts:40-47`).
    private var answered: Bool {
        guard let active else { return false }
        if typedAnswer(active) != nil { return true }
        return !(picks[active.id] ?? []).isEmpty
    }

    private var label: String {
        if sending { return "Submitting..." }
        if !isLastQuestion { return "Next question" }
        return questionIndex > 0 ? "Submit answers" : "Submit answer"
    }
}

// MARK: - The thread's bottom slot

/// What `T3ThreadView.bottomSlot` renders above Task 13's composer: the banner
/// stack, then the top drawer's one panel — `ComposerBanner.Dock` >
/// `.Column` > the stack and the drawer (`ChatComposer.tsx:4786-4809`).
///
/// A view of its own so that `sending`/`note` (which flip on every verdict)
/// re-render this and nothing else: `T3ThreadView`'s body runs `Row ==` for
/// every timeline row, and Task 11 fix 1 deliberately kept observable objects
/// out of it.
struct T3ThreadPendingSlot: View {
    let app: AppModel
    @ObservedObject var store: T3TimelineStore
    @ObservedObject var actions: T3ThreadActions
    /// Dismissed notices, keyed as `getThreadErrorBannerKey`
    /// (`ThreadErrorBanner.tsx:7-9`) keys them — thread plus message. Upstream
    /// keeps that set at module level so it survives a remount; here the whole
    /// thread view remounts per thread id, so `@State` has the same scope.
    @State private var dismissed: Set<String> = []

    /// The capability gate: only a session the app runs itself has the control
    /// channel that whole-prompt answers, permission suggestions and a deny
    /// message ride (`OwnedSessions`). Same predicate the store polls with
    /// (`owned` in `T3TimelineStore.start()`) — never the engine's identity.
    private var owned: Bool { app.ownedBox.existing?.ownedPids.contains(store.pid) == true }

    private var approval: T3PendingApprovalItem? {
        // `.first`, not a search: every key and `.approve` answers
        // `pending(pid:).first` (OwnedSessions.swift:421-449), so the panel has
        // to render exactly that one.
        store.pending.approvals.first.map(T3PendingApprovalItem.init)
    }
    private var questions: [T3PendingQuestionItem] {
        guard approval == nil, let input = store.pending.userInputs.first else { return [] }
        return T3PendingQuestionItem.parse(input.questions)
    }
    private var userInputRequestId: String? { store.pending.userInputs.first?.requestId }

    /// `bannerStackItems` (`ChatView.tsx:5698`) reduced to what B produces: the
    /// last delivery's failure, a session that has ended, and the usage limits.
    private var bannerItems: [T3BannerItem] {
        var items: [T3BannerItem] = []
        // Dismissing this one clears the note itself, so it needs no key.
        if let note = actions.note {
            items.append(.error(id: "delivery", message: note) { actions.note = nil })
        }
        // `store.gone`: no record for this pid under this session id any more.
        // `ThreadErrorBanner` has no closed-session copy upstream, so this is
        // the shortest neutral sentence.
        let ended = "This session has ended."
        if store.gone, !dismissed.contains(key("gone", ended)) {
            items.append(.error(id: "gone", message: ended) { dismissed.insert(key("gone", ended)) })
        }
        let limits = store.limits
        if !limits.isEmpty, !dismissed.contains(key("limits", limits.map(\.key).joined())) {
            items.append(.usageLimits(notes: limits.map(\.text)) {
                dismissed.insert(key("limits", limits.map(\.key).joined()))
            })
        }
        return items
    }

    private func key(_ kind: String, _ message: String) -> String { "\(kind)\u{0}\(message)" }

    var body: some View {
        VStack(spacing: 0) {
            T3BannerStack(items: bannerItems)
            if let approval {
                T3PendingApprovalPanel(approval: approval, pendingCount: store.pending.approvals.count,
                                       owned: owned, sending: actions.sending,
                                       onApprove: { send(.init(kind: .key, text: "1")) },
                                       onAllowSession: { send(.init(kind: .approve, text: approval.sessionApproval)) },
                                       onDeny: { reason in
                                           actions.deny(app: app, pid: store.pid,
                                                        requestId: approval.requestId, reason: reason)
                                       })
                    // Upstream keys the panel by request id; a new prompt has
                    // to arrive with an empty reason field.
                    .id(approval.requestId)
            } else if !questions.isEmpty {
                T3PendingUserInputPanel(questions: questions, owned: owned, sending: actions.sending) { submission in
                    switch submission {
                    case let .answers(text): send(.init(kind: .answers, text: text))
                    case let .key(key): send(.init(kind: .key, text: key))
                    }
                }
                .id(userInputRequestId ?? "")
            }
        }
    }

    private func send(_ request: SessionInput.Request) {
        actions.send(request, app: app, pid: store.pid)
    }
}

// MARK: - Previews

/// Sample data for the previews below — the fixture produces an approval and a
/// question, but not on demand.
private enum T3PendingSamples {
    static let approval = T3PendingApprovalItem(requestId: "req-1", toolName: "Bash",
                                                detail: "swift test --filter T3")
    static let questions = [
        T3PendingQuestionItem(id: "q1", question: "Which database should the worker write to?",
                              header: "Storage", multiSelect: false,
                              options: [.init(label: "Postgres", description: "The existing cluster"),
                                        .init(label: "SQLite", description: "One file per worker")]),
        T3PendingQuestionItem(id: "q2", question: "Which checks should run on the branch?",
                              header: "CI", multiSelect: true,
                              options: [.init(label: "test", description: ""),
                                        .init(label: "e2e", description: ""),
                                        .init(label: "linux", description: "")]),
    ]
    static let customAnswerQuestions = [
        questions[0],   // single-select, field offered
        questions[1],   // multi-select, field offered (and its separator rule)
        T3PendingQuestionItem(id: "q3", question: "Which release should this land in?",
                              header: "Release", multiSelect: false, allowCustomAnswer: false,
                              options: [.init(label: "Next", description: "The open milestone"),
                                        .init(label: "Hold", description: "Wait for a decision")]),
    ]
    static let limitNote = "Claude usage limit reached. This turn is paused until the 5-hour limit resets in 2h 14m."
}

#Preview("Approval panel") {
    T3PendingApprovalPanel(approval: T3PendingSamples.approval, pendingCount: 2, owned: true, sending: false,
                           onApprove: {}, onAllowSession: {}, onDeny: { _ in })
        .frame(width: 560)
        .padding(24)
        .t3(platform: .web, scheme: .dark)
        .preferredColorScheme(.dark)
}

#Preview("Approval panel, terminal session") {
    T3PendingApprovalPanel(approval: T3PendingSamples.approval, pendingCount: 1, owned: false, sending: false,
                           onApprove: {}, onAllowSession: {}, onDeny: { _ in })
        .frame(width: 560)
        .padding(24)
        .t3(platform: .web, scheme: .dark)
        .preferredColorScheme(.dark)
}

#Preview("Question panel") {
    T3PendingUserInputPanel(questions: T3PendingSamples.questions, owned: true, sending: false) { _ in }
        .frame(width: 560)
        .padding(24)
        .t3(platform: .web, scheme: .dark)
        .preferredColorScheme(.dark)
}

/// The owned card with its free-text field: a single-select and a multi-select
/// offer it, the third withdrew it (`allowCustomAnswer: false`). The parity
/// fixture is terminal-hosted, so this is the only place the field can be
/// looked at. (The multi-select's separator warning needs typed text, which a
/// preview cannot seed — that line is compile-checked only.)
#Preview("Question panel, custom answer") {
    T3PendingUserInputPanel(questions: T3PendingSamples.customAnswerQuestions,
                            owned: true, sending: false) { _ in }
        .frame(width: 560)
        .padding(24)
        .t3(platform: .web, scheme: .dark)
        .preferredColorScheme(.dark)
}

#Preview("Question panel, terminal session") {
    T3PendingUserInputPanel(questions: T3PendingSamples.questions, owned: false, sending: false) { _ in }
        .frame(width: 560)
        .padding(24)
        .t3(platform: .web, scheme: .dark)
        .preferredColorScheme(.dark)
}

#Preview("Banner stack") {
    T3BannerStack(items: [.error(id: "gone", message: "This session has ended.", dismiss: {}),
                          .usageLimits(notes: [T3PendingSamples.limitNote]) {}])
    .frame(width: 560)
    .padding(24)
    .t3(platform: .web, scheme: .dark)
    .preferredColorScheme(.dark)
}
