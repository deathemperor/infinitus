import SwiftUI
import InfinitusCore
import InfinitusUI

/// The Sessions tab (#9 native shell): the Mac's live Claude Code
/// sessions as a native list. The second line — what a session is doing,
/// its todo capsule, the quiet timer — is the shared
/// `SessionProgressLine` the Mac popup's card draws.
struct SessionsScreen: View {
    @ObservedObject var model: MirrorModel
    @ObservedObject var progress: MobileSessionProgress
    @State private var path = NavigationPath()
    /// The session whose feed is on screen, if one is.
    @State private var openPid: Int?
    @State private var startSheet = false

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(model.rowTheme.tabLabel("sessions"))
                .onAppear { LeaseReporter.shared.acquire(.sessions, on: .everyMac) }
                .onDisappear { LeaseReporter.shared.release(.sessions, on: .everyMac) }
                .refreshable { await model.refresh() }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { path.append(PastSessionsRoute()) } label: { Image(systemName: "clock.arrow.circlepath") }
                            .accessibilityLabel("Past sessions")
                            .disabled(!model.anyMacAnswered)
                        Button { startSheet = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Start a session")
                            .disabled(!model.anyMacAnswered)
                    }
                }
                .sheet(isPresented: $startSheet) {
                    if model.t3Screens { T3NewTaskSheet(model: model) } else { StartSessionSheet(model: model) }
                }
                .navigationDestination(for: PastSessionsRoute.self) { _ in
                    PastSessionsScreen(model: model)
                }
                .onChange(of: model.requestedPid) { _, _ in openRequestedPid() }
                .onChange(of: model.snapshot?.capturedAt) { _, _ in openRequestedPid() }
                // The pid of a session started on another Mac shows up in
                // THAT Mac's snapshot, which never moves the primary's.
                .onChange(of: model.others.map { $0.snapshot?.capturedAt }) { _, _ in openRequestedPid() }
                .navigationDestination(for: SessionDetail.self) { session in
                    threadScreen(session, macId: nil)
                        .onAppear { openPid = session.pid }
                        .onDisappear { if openPid == session.pid { openPid = nil } }
                }
                // The feed header's tap target (user 2026-09-03: account
                // summary + "a more detail screen when tap on its header
                // title") — a distinct route so it stacks one level past
                // the feed rather than replacing it.
                .navigationDestination(for: SessionDetailRoute.self) { route in
                    SessionDetailScreen(model: model, progress: progress, session: route.session, macId: route.macId)
                }
                .navigationDestination(for: CheckpointsRoute.self) { route in
                    CheckpointsScreen(session: route.session, macId: route.macId)
                }
                // Another Mac's session (#144 phase 2): its own feed, its
                // own Mac. Sits beside the primary's destination so both
                // can stack.
                .navigationDestination(for: OtherSessionRoute.self) { route in
                    threadScreen(route.session, macId: route.macId)
                }
        }
        // A shake staged a capture for a session: open its feed (which
        // takes the capture into its composer). A feed already open for
        // that pid takes it itself — re-pushing a fresh SessionDetail
        // (its status may have moved) would rebuild the feed and lose
        // the capture the old one just took. Any other feed is replaced.
        .onChange(of: model.stagedCapture?.id) { _, _ in
            guard let staged = model.stagedCapture else { return }
            guard openPid != staged.pid else { return }
            guard let session = fleetsWithSessions
                      .flatMap({ $0.liveSessions?.sessions ?? [] })
                      .first(where: { $0.pid == staged.pid })
            else { model.stagedCapture = nil; return }
            path = NavigationPath()
            path.append(session)
        }
        // Same dev seam as `INFINITUS_TAB` — a headless simulator capture
        // can't tap a row, so a pid named here pushes straight to its feed
        // (on appear too: a cached snapshot has the sessions before the
        // change fires).
        .onChange(of: fleetsWithSessions.isEmpty) { _, _ in openSeamFeed() }
        // A push during the stack's own appearance is dropped; a beat later lands.
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { openSeamFeed() } }
    }

    private func openSeamFeed() {
        guard path.isEmpty,
              let pidText = ProcessInfo.processInfo.environment["INFINITUS_FEED_PID"],
              let pid = Int(pidText),
              let session = fleetsWithSessions
                  .flatMap({ $0.liveSessions?.sessions ?? [] })
                  .first(where: { $0.pid == pid })
        else { return }
        path.append(session)
    }

    /// One section per fleet that has sessions to show — in practice
    /// only cswap's `liveSessions` is ever populated, but a fleet with
    /// none simply contributes no section.
    private var fleetsWithSessions: [MirrorFleetModel] {
        model.fleets.filter { !($0.liveSessions?.sessions?.isEmpty ?? true) }
    }

    /// Every OTHER paired Mac (#144 phase 1) that has a session to show —
    /// one appended section per Mac, plain rows (no chat to open yet).
    private var othersWithSessions: [MirrorModel.OtherMac] {
        model.others.filter { other in
            other.fleets.contains { !($0.liveSessions?.sessions?.isEmpty ?? true) }
        }
    }

    @ViewBuilder private var content: some View {
        if !fleetsWithSessions.isEmpty || !othersWithSessions.isEmpty {
            ScrollViewReader { proxy in
                List {
                    awsLoginSection
                    primarySections
                    otherMacSections
                }
                .listStyle(.insetGrouped)
                // A per-Mac widget's tap (#144): from a cold launch the
                // screen mounts after the request was set, so `onAppear`
                // is the only firing — a turn late, once the list is laid
                // out. A Mac still to answer waits for its snapshot.
                .onAppear { DispatchQueue.main.async { scrollToRequestedMac(proxy) } }
                // A warm tap from another tab: the request lands while
                // the tab is still switching — a turn later the list is on.
                .onChange(of: model.requestedSectionMacId) { _, _ in
                    DispatchQueue.main.async { scrollToRequestedMac(proxy) }
                }
                .onChange(of: model.others.map { $0.snapshot?.capturedAt }) { _, _ in scrollToRequestedMac(proxy) }
            }
            .sheet(item: $awsLoginItem) { AwsLoginScreen(item: $0) }
            // A cold launch from the notification asks before the first
            // snapshot is in; the request waits for the login to appear.
            .onChange(of: model.requestedAwsLogin) { _, _ in openRequestedAwsLogin() }
            .onChange(of: model.snapshot?.capturedAt) { _, _ in openRequestedAwsLogin() }
        } else if !model.fleets.isEmpty {
            ThemedPlaceholder(theme: model.rowTheme, key: "noSessions", plainSymbol: "brain",
                              description: "Nothing is running on the Mac right now.")
        } else {
            ThemedPlaceholder(theme: model.rowTheme, key: "searching", plainSymbol: "antenna.radiowaves.left.and.right",
                              description: "Pair with the Mac in Settings to see its sessions.")
        }
    }

    @State private var awsLoginItem: AwsLogin.Item?

    /// The List body is split into three builders — one expression with
    /// all three sections is more than CI's compiler type-checks in time.
    @ViewBuilder private var awsLoginSection: some View {
        if !model.awsLogins.isEmpty {
            // Up top, whatever the session's place in the list
            // (user 2026-09-03 "not seeing session with aws
            // login button"): one row per login the Mac reports,
            // pid-less ones included.
            Section("Needs AWS login") {
                ForEach(model.awsLogins) { item in
                    Button { awsLoginItem = item } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "key.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.sessionLabel ?? "Profile \(item.profile)").font(.headline)
                                Text("profile \(item.profile) · \(awsPhase(item))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Sign in").font(.subheadline.bold()).foregroundStyle(.orange)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Pinned sessions lead, then the active ones with those waiting on
    /// you first, then the snoozed and settled shelves — dimmed, never
    /// hidden, so a Live Activity tap still lands (#223 phase 3).
    private func ordered(_ sessions: [SessionDetail], macId: String? = nil) -> [SessionDetail] {
        func rank(_ s: SessionDetail) -> (Int, Double) {
            guard let f = model.facts(macId: macId, pid: s.pid) else { return (s.status == "waiting" ? 1 : 2, 0) }
            if let p = f.pinnedAt { return (0, p.timeIntervalSince1970) }
            if SessionListPresentation.isSnoozed(f) { return (3, 0) }
            if SessionListPresentation.isSettled(f) { return (4, 0) }
            return (s.status == "waiting" ? 1 : 2, 0)
        }
        return sessions.map { ($0, rank($0)) }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    private var primarySections: some View {
        ForEach(fleetsWithSessions) { fleet in
            let live = fleet.liveSessions!
            Section {
                ForEach(ordered(live.sessions ?? []), id: \.pid) { session in
                    NavigationLink(value: session) { row(session) }
                        .modifier(AttentionActions(model: model, session: session, macId: nil))
                }
            } header: {
                sectionHeader(fleet: fleet, live: live)
            }
        }
    }

    private var otherMacSections: some View {
        ForEach(othersWithSessions) { other in
            let sessions = ordered(other.fleets.flatMap { $0.liveSessions?.sessions ?? [] }, macId: other.id)
            Section {
                ForEach(sessions, id: \.pid) { session in
                    NavigationLink(value: OtherSessionRoute(macId: other.id, session: session)) {
                        row(session, macId: other.id)
                    }
                    .modifier(AttentionActions(model: model, session: session, macId: other.id))
                }
            } header: {
                HStack(spacing: 6) {
                    Text(other.pairing.name)
                    if other.parked {
                        Label("parked", systemImage: "moon.zzz").labelStyle(.titleAndIcon)
                    }
                }
            }
            .id(Self.sectionID(macId: other.id))
        }
    }

    private static func sectionID(macId: String) -> String { "mac:\(macId)" }

    /// A per-Mac widget's tap (#144): the list scrolls to that Mac's
    /// section once it has one. Dropped: the primary's key, a Mac
    /// forgotten while the tap was in flight, and a Mac that has
    /// answered with no session to show — a request kept past that
    /// would jump the list minutes later, when one starts.
    private func scrollToRequestedMac(_ proxy: ScrollViewProxy) {
        guard let macId = model.requestedSectionMacId else { return }
        guard macId != WidgetBridge.primary, let mac = model.other(macId) else {
            model.requestedSectionMacId = nil
            return
        }
        guard othersWithSessions.contains(where: { $0.id == macId }) else {
            if mac.snapshot != nil { model.requestedSectionMacId = nil }
            return
        }
        model.requestedSectionMacId = nil
        path = NavigationPath()
        withAnimation { proxy.scrollTo(Self.sectionID(macId: macId), anchor: .top) }
    }

    /// A session started from the + sheet or Past sessions: its chat
    /// opens the moment its Mac's snapshot lists the pid — on the
    /// primary's route, or the other Mac's (#144 phase 3).
    private func openRequestedPid() {
        guard let pid = model.requestedPid else { return }
        if let macId = model.requestedMacId {
            guard let other = model.other(macId) else {
                // Forgotten while we waited — nothing to open.
                model.requestedMacId = nil
                model.requestedPid = nil
                return
            }
            guard let session = other.fleets.flatMap({ $0.liveSessions?.sessions ?? [] })
                .first(where: { $0.pid == pid }) else { return }
            model.requestedMacId = nil
            model.requestedPid = nil
            path = NavigationPath()
            path.append(OtherSessionRoute(macId: macId, session: session))
            return
        }
        guard let session = fleetsWithSessions.flatMap({ $0.liveSessions?.sessions ?? [] })
            .first(where: { $0.pid == pid }) else { return }
        model.requestedPid = nil
        path = NavigationPath()
        path.append(session)
    }

    private func openRequestedAwsLogin() {
        guard let id = model.requestedAwsLogin,
              let item = model.awsLogins.first(where: { $0.id == id }) else { return }
        model.requestedAwsLogin = nil
        awsLoginItem = item
    }

    private func awsPhase(_ item: AwsLogin.Item) -> String {
        switch item.state?.phase {
        case nil: return "tap to sign in"
        case .starting: return "starting"
        case .waitingForBrowser: return "sign-in page ready"
        case .waitingForCode: return "waiting for the code"
        case .done: return "signed in"
        case .failed: return "failed — tap to retry"
        }
    }

    private func row(_ session: SessionDetail, macId: String? = nil) -> some View {
        // The host's facts decide the dot and the word when the phone
        // leases the session (#223 phase 3); the status word until then.
        let facts = model.facts(macId: macId, pid: session.pid)
        let attention = SessionListPresentation.attention(facts, fallbackStatus: session.status)
        let shelf = facts.flatMap { AttentionActions.shelfLabel($0) }
        return HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(SessionWords.color(attention, raw: session.status))
                .frame(width: 9, height: 9)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    // "Infinitus · limitless": the session's name and its
                    // repo (user 2026-09-03 "show repo too").
                    if model.awsLogin(macId: macId, pid: session.pid) != nil {
                        Image(systemName: "key.fill").foregroundStyle(.orange)
                            .accessibilityLabel("needs AWS login")
                    }
                    // The row wears the theme like the chat header does
                    // (user 2026-09-05: "sessions list to honor colors
                    // too"): the name in the theme's accent, the state
                    // word in its state color. Off keeps the stock list.
                    Text(title(session, macId: macId))
                        .font(.headline).lineLimit(1)
                        .foregroundStyle(model.rowTheme.plain ? Color.primary : ThemeColor.flash(model.rowTheme))
                    Spacer(minLength: 8)
                    if attention == .approval || attention == .input {
                        Image(systemName: attention == .approval ? "hand.raised.fill" : "questionmark.circle.fill")
                            .font(.caption).foregroundStyle(.yellow)
                            .accessibilityLabel(attention == .approval ? "waiting for approval" : "asking a question")
                    }
                    Text(SessionWords.status(attention, raw: session.status, theme: model.rowTheme))
                        .font(.caption)
                        .foregroundStyle(model.rowTheme.plain && attention == .ready ? Color.secondary
                                         : SessionWords.color(attention, raw: session.status))
                    Text(SessionWords.age(since: session.startedAt))
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                Text(shortCwd(session.cwd))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
                // Metadata line: branch · model · kind · output tokens.
                Text(metadata(session, macId: macId))
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    .lineLimit(1).truncationMode(.middle)
                if let p = model.progress(macId: macId, pid: session.pid), p.hasProgressSignal {
                    SessionProgressLine(progress: p)
                }
                if let plan = SessionListPresentation.planLine(facts) {
                    Label(plan, systemImage: "checklist")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if let shelf {
                    Label(shelf.text, systemImage: shelf.icon)
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .opacity(shelf == nil ? 1 : 0.55)
        .padding(.vertical, 4)
        .frame(minHeight: 44)
    }

    /// The summary line wears the theme (user 2026-09-04 "style the
    /// header info of sessions with theme"): the theme's session glyph in
    /// its gauge color on a wash of the theme's accent — the tint the
    /// Fleet screen's rows already wear. The Off theme keeps the stock
    /// list header.
    private func sectionHeader(fleet: MirrorFleetModel, live: LiveSessions) -> some View {
        let theme = fleet.rowTheme
        let summary = model.fleets.count > 1
            ? "\(fleet.fleetLabel?.engineName ?? fleet.engineID) — \(SessionSummary.tooltip(live))"
            : SessionSummary.tooltip(live)
        return Group {
            if theme.plain {
                Text(summary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(PopupGlyph.text(theme.sessionLabel))
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(ThemeColor.resolve(theme.sessionColor))
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(ThemeColor.flash(theme).opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                .textCase(nil)
            }
        }
    }

    /// A session opens in the phone's feed, or in the T3 clone's thread
    /// (#223 §5) while the `T3 screens` setting is on.
    @ViewBuilder
    private func threadScreen(_ session: SessionDetail, macId: String?) -> some View {
        if model.t3Screens {
            T3ThreadScreen(model: model, session: session, macId: macId)
        } else {
            SessionFeedScreen(model: model, session: session, macId: macId)
        }
    }

    /// Same colors the Mac's sessions card uses for each status.
    private func title(_ session: SessionDetail, macId: String? = nil) -> String {
        let repo = repoName(session.cwd)
        let p = model.progress(macId: macId, pid: session.pid)
        let name = SessionNaming.displayName(name: p?.name, autoName: p?.autoName, cwd: session.cwd)
        guard name != repo else { return repo }
        return "\(name) · \(repo)"
    }

    private func repoName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func shortCwd(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func metadata(_ session: SessionDetail, macId: String? = nil) -> String {
        let p = model.progress(macId: macId, pid: session.pid)
        var parts: [String] = []
        // Born from a profile / in a permission mode (#163/#165) leads.
        if let chip = model.birth(macId: macId, pid: session.pid)?.chip { parts.append(chip) }
        if let branch = p?.gitBranch { parts.append("⎇ \(branch)") }
        if let model = p?.model { parts.append(shortModel(model)) }
        if session.kind != "interactive", !session.kind.isEmpty { parts.append(SessionWords.kind(session.kind)) }
        if let tokens = p?.outputTokens, tokens > 0 { parts.append("\(compact(tokens)) out") }
        return parts.joined(separator: " · ")
    }

    /// `claude-opus-4-1-20250805` → `opus 4.1`, `claude-fable-5` → `fable 5`.
    private func shortModel(_ id: String) -> String {
        var s = id
        if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
        if let dash = s.range(of: "-20", options: .backwards) { s = String(s[..<dash.lowerBound]) }
        let pieces = s.split(separator: "-")
        guard let family = pieces.first else { return id }
        let version = pieces.dropFirst().joined(separator: ".")
        return version.isEmpty ? String(family) : "\(family) \(version)"
    }

    private func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6)
            : n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }

}

/// Swipe and long-press actions over a session row (#223 phase 3, T3's
/// settle / snooze / pin overlays): leading swipe pins, trailing swipe
/// settles or snoozes an hour; the menu adds "until tomorrow". Every
/// action is a `POST /sessions/<pid>/attention` on that session's Mac.
private struct AttentionActions: ViewModifier {
    @ObservedObject var model: MirrorModel
    let session: SessionDetail
    let macId: String?

    private var facts: SessionFacts? { model.facts(macId: macId, pid: session.pid) }
    private var pinned: Bool { facts?.pinnedAt != nil }
    private var snoozed: Bool { facts.map { SessionListPresentation.isSnoozed($0) } ?? false }
    private var settled: Bool { facts.map { SessionListPresentation.isSettled($0) } ?? false }

    static func shelfLabel(_ f: SessionFacts) -> (text: String, icon: String)? {
        if SessionListPresentation.isSnoozed(f), let until = f.snoozedUntil {
            let date: Date.FormatStyle.DateStyle = Calendar.current.isDateInToday(until) ? .omitted : .abbreviated
            return ("snoozed until " + until.formatted(date: date, time: .shortened), "moon.zzz")
        }
        if SessionListPresentation.isSettled(f) { return ("settled", "checkmark.circle") }
        return nil
    }

    private func act(_ action: AttentionStore.Action, until: Date? = nil) {
        Task { await model.attention(action, macId: macId, pid: session.pid, until: until) }
    }
    private var tomorrowMorning: Date {
        let cal = Calendar.current
        let start = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: Date())!)
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: start) ?? start
    }

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { act(pinned ? .unpin : .pin) } label: {
                    Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin")
                }.tint(.orange)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button { act(settled ? .unsettle : .settle) } label: {
                    Label(settled ? "Unsettle" : "Settle", systemImage: settled ? "arrow.uturn.backward" : "checkmark.circle")
                }.tint(.green)
                Button { snoozed ? act(.unsnooze) : act(.snooze, until: Date().addingTimeInterval(3600)) } label: {
                    Label(snoozed ? "Unsnooze" : "Snooze 1h", systemImage: snoozed ? "bell" : "moon.zzz")
                }.tint(.indigo)
            }
            .contextMenu {
                Button { act(pinned ? .unpin : .pin) } label: { Label(pinned ? "Unpin" : "Pin", systemImage: "pin") }
                Button { act(settled ? .unsettle : .settle) } label: { Label(settled ? "Unsettle" : "Settle", systemImage: "checkmark.circle") }
                if snoozed {
                    Button { act(.unsnooze) } label: { Label("Unsnooze", systemImage: "bell") }
                } else {
                    Button { act(.snooze, until: Date().addingTimeInterval(3600)) } label: { Label("Snooze 1 hour", systemImage: "moon.zzz") }
                    Button { act(.snooze, until: tomorrowMorning) } label: { Label("Snooze until tomorrow", systemImage: "sunrise") }
                }
                Button { UIPasteboard.general.string = session.cwd } label: { Label("Copy path", systemImage: "doc.on.doc") }
            }
    }
}
