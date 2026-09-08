import SwiftUI
import InfinitusCore
import InfinitusUI

/// One Home row's facts (T3 clone C-6): a session as T3's thread-list
/// v2 row shows it — project, title, branch · Mac, status — with the
/// attention shelf it sits on.
struct T3HomeEntry: Identifiable, Equatable {
    let session: SessionDetail
    let macId: String?
    let title: String
    let repo: String
    let branch: String?
    let macLabel: String?
    let status: SessionListPresentation.Attention
    let pinnedAt: Date?
    let snoozed: Bool
    let settled: Bool
    let lastActivity: Date
    var id: String { "\(macId ?? "primary"):\(session.pid)" }
}

/// T3's `relativeTime` (`lib/time.ts`): "<1m", "5m", "21h", "3d".
enum T3Time {
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "<1m" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

/// The list's shelves (`threadListV2.ts` until A's reducer lands): the
/// live shelf — pinned first (newest pin on top), then what waits on the
/// user, then by last activity — and the snoozed and settled shelves,
/// each by last activity.
enum T3HomeShelves {
    struct Split: Equatable {
        var live: [T3HomeEntry] = []
        var snoozed: [T3HomeEntry] = []
        var settled: [T3HomeEntry] = []
    }

    static func split(_ entries: [T3HomeEntry]) -> Split {
        var out = Split()
        for e in entries {
            if e.snoozed { out.snoozed.append(e) }
            else if e.settled, e.pinnedAt == nil { out.settled.append(e) }
            else { out.live.append(e) }
        }
        out.live.sort { a, b in
            switch (a.pinnedAt, b.pinnedAt) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            let ra = a.status == .approval || a.status == .input ? 0 : 1
            let rb = b.status == .approval || b.status == .input ? 0 : 1
            if ra != rb { return ra < rb }
            return a.lastActivity > b.lastActivity
        }
        out.snoozed.sort { $0.lastActivity > $1.lastActivity }
        out.settled.sort { $0.lastActivity > $1.lastActivity }
        return out
    }

    static func matches(_ e: T3HomeEntry, search: String) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return e.title.localizedCaseInsensitiveContains(q) || e.repo.localizedCaseInsensitiveContains(q)
            || (e.branch?.localizedCaseInsensitiveContains(q) ?? false)
    }
}

/// The Home list bound to the model: builds the entries from every
/// Mac's live sessions and hands them to `T3HomeBody`.
struct T3HomeList: View {
    @ObservedObject var model: MirrorModel
    @Binding var path: NavigationPath
    @Binding var startSheet: Bool
    let awsLogin: (AwsLogin.Item) -> Void

    private var entries: [T3HomeEntry] {
        var out: [T3HomeEntry] = []
        for (macId, fleets) in [(nil, model.fleets)] + model.others.map { (Optional($0.id), $0.fleets) } {
            for s in fleets.flatMap({ $0.liveSessions?.sessions ?? [] }) {
                let facts = model.facts(macId: macId, pid: s.pid)
                let p = model.progress(macId: macId, pid: s.pid)
                out.append(T3HomeEntry(
                    session: s, macId: macId,
                    title: SessionNaming.displayName(name: p?.name, autoName: p?.autoName, cwd: s.cwd),
                    repo: URL(fileURLWithPath: s.cwd).lastPathComponent, branch: p?.gitBranch,
                    macLabel: model.machineName(macId: macId),
                    status: SessionListPresentation.attention(facts, fallbackStatus: s.status),
                    pinnedAt: facts?.pinnedAt,
                    snoozed: facts.map { SessionListPresentation.isSnoozed($0) } ?? false,
                    settled: facts.map { SessionListPresentation.isSettled($0) } ?? false,
                    lastActivity: p?.lastActivityAt ?? Date(timeIntervalSince1970: s.startedAt / 1000)))
            }
        }
        return out
    }

    private var connection: T3HomeBody.Connection {
        if model.pairToken.isEmpty, model.others.isEmpty { return .unpaired }
        let mac = model.machineName(macId: nil)
        guard let at = model.snapshot?.capturedAt else { return .reconnecting(mac) }
        return Date().timeIntervalSince(at) > 180 ? .reconnecting(mac) : .connected(mac)
    }

    var body: some View {
        T3HomeBody(entries: entries, connection: connection,
                   open: { e in
                       if let macId = e.macId { path.append(OtherSessionRoute(macId: macId, session: e.session)) }
                       else { path.append(e.session) }
                   },
                   compose: { startSheet = true },
                   settings: { model.requestedTab = "settings" },
                   pastSessions: { path.append(PastSessionsRoute()) },
                   awsLogins: model.awsLogins, awsLogin: awsLogin,
                   decorate: { e, row in AnyView(row.modifier(T3HomeSwipe(model: model, entry: e))) })
    }
}

/// The swipe actions T3's rows carry (settle / snooze / pin), the phone's
/// existing ones (#223): the attention route with a client id.
private struct T3HomeSwipe: ViewModifier {
    @ObservedObject var model: MirrorModel
    let entry: T3HomeEntry
    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button {
                    Task { await model.attention(entry.settled ? .unsettle : .settle, macId: entry.macId, pid: entry.session.pid) }
                } label: { Label(entry.settled ? "Unsettle" : "Settle", systemImage: "checkmark.circle") }
                    .tint(.green)
                Button {
                    Task { await model.attention(entry.snoozed ? .unsnooze : .snooze, macId: entry.macId, pid: entry.session.pid,
                                                 until: entry.snoozed ? nil : Date().addingTimeInterval(3600)) }
                } label: { Label(entry.snoozed ? "Unsnooze" : "Snooze", systemImage: "moon.zzz") }
                    .tint(.indigo)
            }
            .swipeActions(edge: .leading) {
                Button {
                    Task { await model.attention(entry.pinnedAt == nil ? .pin : .unpin, macId: entry.macId, pid: entry.session.pid) }
                } label: { Label(entry.pinnedAt == nil ? "Pin" : "Unpin", systemImage: "pin") }
                    .tint(.orange)
            }
    }
}

/// T3's Home (`HomeScreen.tsx` + `thread-list-v2-items.tsx`, the layout
/// `refs/ios-home.png` shows): brand header with the settings button,
/// the flat row list with snoozed and settled shelves, the bottom bar
/// of filter, search and compose pills.
struct T3HomeBody: View {
    enum Connection: Equatable { case unpaired, reconnecting(String), connected(String) }

    let entries: [T3HomeEntry]
    let connection: Connection
    let open: (T3HomeEntry) -> Void
    let compose: () -> Void
    let settings: () -> Void
    var pastSessions: () -> Void = {}
    /// The Mac's AWS logins waiting on the phone (kept from the grouped
    /// list: "not seeing session with aws login button"), rows up top.
    var awsLogins: [AwsLogin.Item] = []
    var awsLogin: (AwsLogin.Item) -> Void = { _ in }
    /// Wraps each row with what needs the model (swipe actions); the
    /// harness passes none. Row-level, so `.swipeActions` lands on the row.
    var decorate: ((T3HomeEntry, AnyView) -> AnyView)? = nil
    @Environment(\.t3) private var t3
    @State private var search = ""
    @State private var showSnoozed = false
    @State private var showSettled = true

    private var shelves: T3HomeShelves.Split { T3HomeShelves.split(entries.filter { T3HomeShelves.matches($0, search: search) }) }

    var body: some View {
        ZStack {
            t3.mobile.screen.color.ignoresSafeArea()
            if connection == .unpaired {
                T3EmptyState(title: "No Macs paired",
                             message: "Pair a Mac from Settings and its sessions show up here.",
                             action: ("Pair a Mac", settings))
                    .padding(.horizontal, 32)
            } else if entries.isEmpty {
                T3EmptyState(title: "No threads yet", message: "Start one with the compose button below.")
                    .padding(.horizontal, 32)
            } else {
                list
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
    }

    // MARK: header (`HomeHeader.tsx`: brand row + settings)

    private var header: some View {
        HStack(spacing: 10) {
            switch connection {
            case .connected(let mac): T3Wordmark(badge: mac)
            case .reconnecting(let mac):
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash").font(.system(size: 17)).foregroundStyle(t3.mobile.iconMuted.color)
                    Text("Reconnecting to \(mac)").font(T3Font.mobileLiteral(21, .medium)).tracking(-0.5).lineLimit(1)
                        .foregroundStyle(t3.mobile.foregroundMuted.color)
                }
            case .unpaired: T3Wordmark()
            }
            Spacer(minLength: 8)
            Button(action: settings) {
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(t3.mobile.icon.color)
                    .frame(width: 44, height: 44)
                    .background(t3.mobile.subtle.color, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open settings")
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
        .background(t3.mobile.screen.color)
    }

    // MARK: list

    private var list: some View {
        let s = shelves
        return List {
            ForEach(awsLogins) { awsRow($0) }
            ForEach(s.live) { rowItem($0) }
            if !s.snoozed.isEmpty {
                shelfHeader(showSnoozed ? "Snoozed" : "Snoozed (\(s.snoozed.count))", expanded: showSnoozed,
                            line: t3.mobile.primary.color.opacity(0.2), text: t3.mobile.foregroundSecondary.color) {
                    showSnoozed.toggle()
                }
                if showSnoozed { ForEach(s.snoozed) { rowItem($0) } }
            }
            if !s.settled.isEmpty {
                shelfHeader(showSettled ? "Settled" : "Settled (\(s.settled.count))", expanded: showSettled,
                            line: t3.mobile.border.color, text: t3.mobile.foregroundTertiary.color) {
                    showSettled.toggle()
                }
                if showSettled { ForEach(s.settled) { rowItem($0) } }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
    }

    private func rowItem(_ e: T3HomeEntry) -> some View {
        let base = AnyView(Button { open(e) } label: { T3HomeRow(entry: e) }.buttonStyle(.plain))
        return (decorate?(e, base) ?? base)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(t3.mobile.screen.color)
    }

    private func awsRow(_ item: AwsLogin.Item) -> some View {
        Button { awsLogin(item) } label: {
            HStack(spacing: 10) {
                Image(systemName: "key.fill").font(.system(size: 15)).foregroundStyle(t3.mobile.warningForeground.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.sessionLabel ?? "Profile \(item.profile)").font(T3Font.mobile(.base, .medium))
                        .foregroundStyle(t3.mobile.foreground.color).lineLimit(1)
                    Text("Needs AWS login · profile \(item.profile) · \(SessionsScreen.awsPhase(item))")
                        .font(T3Font.mobile(.xs)).foregroundStyle(t3.mobile.foregroundMuted.color).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("Sign in").font(T3Font.mobile(.sm, .bold)).foregroundStyle(t3.mobile.warningForeground.color)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(t3.mobile.warning.color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(t3.mobile.screen.color)
    }

    private func shelfHeader(_ label: String, expanded: Bool, line: Color, text: Color, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Text(label).font(T3Font.mobile(.xs, .medium)).foregroundStyle(text)
                Rectangle().fill(line).frame(height: 1)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(t3.mobile.iconMuted.color)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(t3.mobile.screen.color)
    }

    // MARK: bottom bar (iOS 26 mail-style: filter · search · compose)

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Menu {
                Toggle("Show snoozed", isOn: $showSnoozed)
                Toggle("Show settled", isOn: $showSettled)
                Divider()
                Button("Past sessions", systemImage: "clock.arrow.circlepath", action: pastSessions)
            } label: {
                T3GlassSurface {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 18, weight: .medium))
                        .foregroundStyle(t3.mobile.icon.color).frame(width: 52, height: 52)
                }
                .clipShape(Circle())
            }
            .accessibilityLabel("Filter and sort threads")
            T3GlassSurface {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium)).foregroundStyle(t3.mobile.icon.color)
                    TextField("Search", text: $search).font(T3Font.mobile(.lg)).foregroundStyle(t3.mobile.foreground.color)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundStyle(t3.mobile.iconMuted.color)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18).frame(height: 52)
            }
            .clipShape(Capsule())
            Button(action: compose) {
                T3GlassSurface {
                    Image(systemName: "square.and.pencil").font(.system(size: 18, weight: .medium))
                        .foregroundStyle(t3.mobile.icon.color).frame(width: 52, height: 52)
                }
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New task")
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
    }
}

/// T3's v2 thread row (`thread-list-v2-items.tsx` `cardContent`): the
/// project line (folder, name, pin, status or age), the title, and the
/// meta line — `branch · Mac` with the machine glyph, the provider mark
/// at the trailing edge.
struct T3HomeRow: View {
    let entry: T3HomeEntry
    var now: Date = Date()
    @Environment(\.t3) private var t3

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").font(.system(size: 13)).foregroundStyle(t3.mobile.iconMuted.color)
                Text(entry.repo).font(T3Font.mobile(.sm, .medium)).lineLimit(1)
                    .foregroundStyle(t3.mobile.foregroundMuted.color)
                Spacer(minLength: 8)
                if entry.pinnedAt != nil {
                    Image(systemName: "pin").font(.system(size: 11)).foregroundStyle(t3.mobile.foregroundMuted.color)
                }
                if let label = statusLabel {
                    Text(label.text).font(T3Font.mobile(.xs)).monospacedDigit().foregroundStyle(label.color)
                } else {
                    Text(T3Time.relative(entry.lastActivity, now: now)).font(T3Font.mobile(.xs)).monospacedDigit()
                        .foregroundStyle(t3.mobile.foregroundTertiary.color)
                }
            }
            Text(entry.title).font(T3Font.mobile(.base, .medium)).lineLimit(2)
                .foregroundStyle(t3.mobile.foreground.color)
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    if let branch = entry.branch {
                        Text(branch).font(.system(size: 13, design: .monospaced)).lineLimit(1)
                            .foregroundStyle(t3.mobile.foregroundMuted.color)
                    }
                    if let mac = entry.macLabel {
                        if entry.branch != nil {
                            Text("·").font(T3Font.mobile(.xs)).foregroundStyle(t3.mobile.foregroundTertiary.color).padding(.horizontal, 4)
                        }
                        Text(mac).font(T3Font.mobile(.xs)).lineLimit(1).foregroundStyle(t3.mobile.foregroundTertiary.color)
                        Image(systemName: "laptopcomputer").font(.system(size: 11)).foregroundStyle(t3.mobile.foregroundTertiary.color)
                    }
                }
                Spacer(minLength: 0)
                T3ProviderIcon(size: 14).opacity(0.6)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(t3.mobile.borderSubtle.color).frame(height: 1).padding(.leading, 20)
        }
        .contentShape(Rectangle())
    }

    /// `STATUS_LABEL_BY_STATUS`: a waiting or failed row says so where
    /// the others show their age.
    private var statusLabel: (text: String, color: Color)? {
        switch entry.status {
        case .approval: return ("Approval", t3.mobile.warningForeground.color)
        case .input: return ("Input", t3.mobile.foregroundSecondary.color)
        case .working: return ("Working", t3.mobile.foregroundSecondary.color)
        case .failed: return ("Failed", t3.mobile.dangerForeground.color)
        case .ready: return nil
        }
    }
}
