import SwiftUI
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

    init(model: MirrorModel, session: SessionDetail, macId: String? = nil) {
        self.model = model
        self.session = session
        self.macId = macId
        _follower = StateObject(wrappedValue: TimelineFollower(pid: Int32(session.pid), mirror: model.mirror(for: macId)))
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

    private var rows: [Row] { Self.rows(of: follower.state.timeline) }
    private var working: Bool { follower.state.facts?.status == .running }

    var body: some View {
        ZStack(alignment: .bottom) {
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
                    .padding(.bottom, 96)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: rows.last?.id) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onChange(of: follower.state.synchronized) { _, now in
                    if now { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            VStack(spacing: 8) {
                if working { workingControl }
                composer
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(title).font(T3Font.mobile(.base, .medium)).lineLimit(1)
                        .foregroundStyle(t3.mobile.foreground.color)
                    Text(subtitle).font(T3Font.mobile(.xxs)).lineLimit(1)
                        .foregroundStyle(t3.mobile.foregroundMuted.color)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Image(systemName: "folder").foregroundStyle(t3.mobile.iconMuted.color)
                Image(systemName: "terminal").foregroundStyle(t3.mobile.iconMuted.color)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear { follower.start() }
        .onDisappear { follower.stop() }
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

    // MARK: composer (T3 `ThreadComposer.tsx`, collapsed capsule)

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 6) {
                // Attachments come with the composer port; the button
                // holds T3's slot.
                Image(systemName: "plus").font(.system(size: 17, weight: .medium))
                    .foregroundStyle(t3.mobile.iconMuted.color)
                    .frame(width: 36, height: 36)
                PasteableTextView(text: $draft, isFocused: $composerFocused,
                                  placeholder: "Ask the repo agent, or run a command…") { _ in }
                    .frame(minHeight: 36, maxHeight: 160)
                    .fixedSize(horizontal: false, vertical: true)
                sendButton
            }
            .padding(6)
            .background(t3.mobile.input.color, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(t3.mobile.inputBorder.color, lineWidth: 1))
            .shadow(color: t3.mobile.drawerShadow.color, radius: 14, y: 6)
            if let note {
                Text(note).font(T3Font.mobile(.xxs)).foregroundStyle(t3.mobile.dangerForeground.color)
                    .padding(.leading, 14)
            }
        }
    }

    private var canSend: Bool { !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var sendButton: some View {
        Button {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            send(.init(kind: .message, text: text)) { draft = "" }
        } label: {
            Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold))
                .foregroundStyle(t3.mobile.primaryForeground.color)
                .frame(width: 36, height: 36)
                .background(canSend ? t3.mobile.primary.color : t3.mobile.subtle.color, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
    }

    private func send(_ request: SessionInput.Request, delivered: @escaping () -> Void = {}) {
        sending = true
        note = nil
        Task {
            defer { sending = false }
            do {
                let reply = try await model.mirror(for: macId).sessionInput(pid: Int32(session.pid), request: request)
                if reply.outcome == "delivered" { delivered() } else { note = reply.detail ?? reply.outcome }
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
        let stamp = Text(message.createdAt.formatted(date: .omitted, time: .shortened))
            .font(T3Font.mobile(.xs, .medium)).monospacedDigit()
            .foregroundStyle(t3.mobile.foregroundTertiary.color)
        if message.role == .user {
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(message.text)
                        .font(T3Font.mobile(.base))
                        .foregroundStyle(t3.mobile.userBubbleForeground.color)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(t3.mobile.userBubble.color, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    stamp
                }
            }
            .padding(.bottom, 20)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                MarkdownText(text: message.text)
                    .font(T3Font.mobile(.base))
                    .foregroundStyle(t3.mobile.foreground.color)
                stamp
            }
            .padding(.bottom, 20)
        }
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
