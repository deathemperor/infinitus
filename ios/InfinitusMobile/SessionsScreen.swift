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
                .refreshable { await model.refresh() }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { path.append(PastSessionsRoute()) } label: { Image(systemName: "clock.arrow.circlepath") }
                            .accessibilityLabel("Past sessions")
                            .disabled(model.snapshot == nil)
                        Button { startSheet = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Start a session")
                            .disabled(model.snapshot == nil)
                    }
                }
                .sheet(isPresented: $startSheet) { StartSessionSheet(model: model) }
                .navigationDestination(for: PastSessionsRoute.self) { _ in
                    PastSessionsScreen(model: model)
                }
                .onChange(of: model.requestedPid) { _, _ in openRequestedPid() }
                .onChange(of: model.snapshot?.capturedAt) { _, _ in openRequestedPid() }
                .navigationDestination(for: SessionDetail.self) { session in
                    SessionFeedScreen(model: model, session: session)
                        .onAppear { openPid = session.pid }
                        .onDisappear { if openPid == session.pid { openPid = nil } }
                }
                // The feed header's tap target (user 2026-09-03: account
                // summary + "a more detail screen when tap on its header
                // title") — a distinct route so it stacks one level past
                // the feed rather than replacing it.
                .navigationDestination(for: SessionDetailRoute.self) { route in
                    SessionDetailScreen(model: model, progress: progress, session: route.session)
                }
                .navigationDestination(for: CheckpointsRoute.self) { route in
                    CheckpointsScreen(session: route.session)
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
            List {
                awsLoginSection
                primarySections
                otherMacSections
            }
            .listStyle(.insetGrouped)
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

    /// Sessions waiting on you first — they're what the phone is opened for.
    private func waitingFirst(_ sessions: [SessionDetail]) -> [SessionDetail] {
        sessions.sorted { ($0.status == "waiting" ? 0 : 1) < ($1.status == "waiting" ? 0 : 1) }
    }

    private var primarySections: some View {
        ForEach(fleetsWithSessions) { fleet in
            let live = fleet.liveSessions!
            Section {
                ForEach(waitingFirst(live.sessions ?? []), id: \.pid) { session in
                    NavigationLink(value: session) { row(session) }
                }
            } header: {
                sectionHeader(fleet: fleet, live: live)
            }
        }
    }

    private var otherMacSections: some View {
        ForEach(othersWithSessions) { other in
            let sessions = waitingFirst(other.fleets.flatMap { $0.liveSessions?.sessions ?? [] })
            Section {
                ForEach(sessions, id: \.pid) { session in
                    row(session).foregroundStyle(.secondary)
                }
            } header: {
                Text(other.pairing.name)
            } footer: {
                Text("Make this Mac primary in Settings › Devices to open its chats.")
            }
        }
    }

    /// A session started from the + sheet: its chat opens the moment the
    /// snapshot lists the pid.
    private func openRequestedPid() {
        guard let pid = model.requestedPid,
              let session = fleetsWithSessions.flatMap({ $0.liveSessions?.sessions ?? [] })
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

    private func row(_ session: SessionDetail) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(color(for: session.status))
                .frame(width: 9, height: 9)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    // "Infinitus · limitless": the session's name and its
                    // repo (user 2026-09-03 "show repo too").
                    if model.awsLogin(for: session.pid) != nil {
                        Image(systemName: "key.fill").foregroundStyle(.orange)
                            .accessibilityLabel("needs AWS login")
                    }
                    // The row wears the theme like the chat header does
                    // (user 2026-09-05: "sessions list to honor colors
                    // too"): the name in the theme's accent, the state
                    // word in its state color. Off keeps the stock list.
                    Text(title(session))
                        .font(.headline).lineLimit(1)
                        .foregroundStyle(model.rowTheme.plain ? Color.primary : ThemeColor.flash(model.rowTheme))
                    Spacer(minLength: 8)
                    Text(SessionWords.status(session.status, theme: model.rowTheme))
                        .font(.caption)
                        .foregroundStyle(model.rowTheme.plain ? Color.secondary : color(for: session.status))
                    Text(SessionWords.age(since: session.startedAt))
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                Text(shortCwd(session.cwd))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
                // Metadata line: branch · model · kind · output tokens.
                Text(metadata(session))
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    .lineLimit(1).truncationMode(.middle)
                if let p = progress.byPid[session.pid], p.hasProgressSignal {
                    SessionProgressLine(progress: p)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(minHeight: 44)
        .contextMenu {
            Button {
                UIPasteboard.general.string = session.cwd
            } label: {
                Label("Copy path", systemImage: "doc.on.doc")
            }
        }
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

    /// Same colors the Mac's sessions card uses for each status.
    private func color(for status: String) -> Color {
        switch status {
        case "busy": return .orange
        case "waiting": return .yellow
        case "idle": return .green
        case "shell": return .blue
        default: return .gray
        }
    }

    private func title(_ session: SessionDetail) -> String {
        let repo = repoName(session.cwd)
        let p = progress.byPid[session.pid]
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

    private func metadata(_ session: SessionDetail) -> String {
        let p = progress.byPid[session.pid]
        var parts: [String] = []
        // Born from a profile / in a permission mode (#163/#165) leads.
        if let chip = model.snapshot?.births?[session.pid]?.chip { parts.append(chip) }
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
