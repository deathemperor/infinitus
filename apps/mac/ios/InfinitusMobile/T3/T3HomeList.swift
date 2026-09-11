import SwiftUI
import InfinitusCore
import InfinitusUI

/// One Home row (T3 clone C-6): the session as a `T3Thread` for the list
/// reducers, plus what the row draws — project, title, branch · Mac.
struct T3HomeEntry: Identifiable, Equatable {
    let session: SessionDetail
    let macId: String?
    let thread: T3Thread
    let repo: String
    let branch: String?
    let macLabel: String?
    let lastActivity: Date
    /// `T3AccountBadge.label`: nil when the Mac has one account.
    var accountBadge: String? = nil
    var id: String { thread.key }
    var title: String { thread.title }
    var status: T3ThreadStatus { T3ThreadStatus(thread) }
}

/// The phone's environment id for a Mac: the primary has none in the
/// mirror, other Macs carry their pairing id. The thread itself is the
/// Core bridge's `T3Thread(session:facts:progress:environmentId:now:)`.
enum T3HomeThreads {
    static func environmentId(_ macId: String?) -> String { macId ?? "primary" }
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

/// The Home list bound to the model: builds the entries from every
/// Mac's live sessions and hands them to `T3HomeBody`.
struct T3HomeList: View {
    @ObservedObject var model: MirrorModel
    @Binding var path: NavigationPath
    @Binding var startSheet: Bool
    @Binding var settingsSheet: Bool
    let awsLogin: (AwsLogin.Item) -> Void

    private var entries: [T3HomeEntry] {
        var out: [T3HomeEntry] = []
        for (macId, fleets) in [(nil, model.fleets)] + model.others.map { (Optional($0.id), $0.fleets) } {
            for s in fleets.flatMap({ $0.liveSessions?.sessions ?? [] }) {
                let facts = model.facts(macId: macId, pid: s.pid)
                let p = model.progress(macId: macId, pid: s.pid)
                let lastActivity = p?.lastActivityAt ?? Date(timeIntervalSince1970: s.startedAt / 1000)
                out.append(T3HomeEntry(
                    session: s, macId: macId,
                    thread: T3Thread(session: s, facts: facts, progress: p,
                                     environmentId: T3HomeThreads.environmentId(macId), now: Date()),
                    repo: URL(fileURLWithPath: s.cwd).lastPathComponent, branch: p?.gitBranch,
                    macLabel: model.machineName(macId: macId), lastActivity: lastActivity,
                    accountBadge: T3AccountBadge.label(accountCount: fleets.reduce(0) { $0 + $1.accounts.count },
                                                       summary: model.accountSummary(macId: macId, pid: s.pid))))
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
                   settings: { settingsSheet = true },
                   pastSessions: { path.append(PastSessionsRoute()) },
                   awsLogins: model.awsLogins, awsLogin: awsLogin,
                   decorate: { e, item, row in AnyView(row.modifier(T3HomeSwipe(model: model, entry: e, item: item))) })
            // The Mac computes facts only for leased sessions; the list holds
            // the fleet lease the grouped screen held.
            .onAppear { LeaseReporter.shared.acquire(.sessions, on: .everyMac) }
            .onDisappear { LeaseReporter.shared.release(.sessions, on: .everyMac) }
    }
}

/// The swipe actions `T3ThreadList.swipeActions` hands a row — settle or
/// unsettle (slim rows), snooze while snoozable, unsnooze while snoozed —
/// on the attention route with a client id; pin stays on the leading
/// edge as the phone had it.
private struct T3HomeSwipe: ViewModifier {
    @ObservedObject var model: MirrorModel
    let entry: T3HomeEntry
    let item: T3ThreadList.Item
    func body(content: Content) -> some View {
        let actions = T3ThreadList.swipeActions(variant: item.variant, settlementSupported: true, snoozeSupported: true,
                                                snoozable: T3ThreadSettled.canSnooze(entry.thread, now: Date()), snoozed: item.snoozed)
        content
            .contextMenu { menu(secondary: actions.secondary) }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                swipe(actions.primary)
                if let secondary = actions.secondary { swipe(secondary) }
            }
            .swipeActions(edge: .leading) {
                Button {
                    Task { await model.attention(entry.thread.pinnedAt == nil ? .pin : .unpin, macId: entry.macId, pid: entry.session.pid) }
                } label: { Label(entry.thread.pinnedAt == nil ? "Pin" : "Unpin", systemImage: "pin") }
                    .tint(.orange)
            }
    }

    /// The long-press menu `thread-list-v2-items.tsx` builds per variant —
    /// card: Settle, Snooze ▸ presets, Pin; slim: Un-settle (+ Pin while
    /// pinned); snoozed: Wake thread. Delete and title regeneration are
    /// left out: the phone has no equivalent action (as upstream omits
    /// them where unsupported).
    @ViewBuilder private func menu(secondary: T3ThreadList.SwipeAction?) -> some View {
        let pid = entry.session.pid, macId = entry.macId
        let pinButton = Button {
            Task { await model.attention(entry.thread.pinnedAt == nil ? .pin : .unpin, macId: macId, pid: pid) }
        } label: { Label(entry.thread.pinnedAt == nil ? "Pin" : "Unpin", systemImage: entry.thread.pinnedAt == nil ? "pin" : "pin.slash") }
        if item.snoozed {
            Button { Task { await model.attention(.unsnooze, macId: macId, pid: pid) } } label: { Label("Wake thread", systemImage: "clock") }
        } else if item.variant == .slim {
            Button { Task { await model.attention(.unsettle, macId: macId, pid: pid) } } label: { Label("Un-settle", systemImage: "arrow.uturn.backward") }
            if entry.thread.pinnedAt != nil { pinButton }
        } else {
            Button { Task { await model.attention(.settle, macId: macId, pid: pid) } } label: { Label("Settle", systemImage: "checkmark") }
            if secondary == .snooze {
                Menu {
                    ForEach(T3ThreadSettled.snoozePresets(now: Date()), id: \.id) { preset in
                        Button { Task { await model.attention(.snooze, macId: macId, pid: pid, until: preset.snoozedUntil) } } label: {
                            Text(preset.label)
                            Text(Self.whenLabel(preset))
                        }
                    }
                } label: { Label("Snooze", systemImage: "clock") }
            }
            pinButton
        }
    }

    /// `whenLabel`: the wake time, with the weekday for next week.
    static func whenLabel(_ preset: T3ThreadSettled.Preset) -> String {
        let time = preset.snoozedUntil.formatted(date: .omitted, time: .shortened)
        return preset.id == .nextWeek ? preset.snoozedUntil.formatted(.dateTime.weekday(.abbreviated)) + " " + time : time
    }

    @ViewBuilder private func swipe(_ action: T3ThreadList.SwipeAction) -> some View {
        let pid = entry.session.pid, macId = entry.macId
        switch action {
        case .settle:
            Button { Task { await model.attention(.settle, macId: macId, pid: pid) } } label: { Label("Settle", systemImage: "checkmark.circle") }
                .tint(.green)
        case .unsettle:
            Button { Task { await model.attention(.unsettle, macId: macId, pid: pid) } } label: { Label("Unsettle", systemImage: "arrow.uturn.backward.circle") }
                .tint(.green)
        case .snooze:
            Button { Task { await model.attention(.snooze, macId: macId, pid: pid, until: Date().addingTimeInterval(3600)) } } label: { Label("Snooze", systemImage: "moon.zzz") }
                .tint(.indigo)
        case .unsnooze:
            Button { Task { await model.attention(.unsnooze, macId: macId, pid: pid) } } label: { Label("Unsnooze", systemImage: "sun.max") }
                .tint(.indigo)
        case .archive:
            EmptyView()   // no archive on the phone (settlement is always supported)
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
    var decorate: ((T3HomeEntry, T3ThreadList.Item, AnyView) -> AnyView)? = nil
    @Environment(\.t3) private var t3
    @State private var search = ""
    @State private var showSnoozed = false
    @State private var showSettled = true
    /// The settled tail renders in pages (`HomeScreen.tsx` settledVisibleCount):
    /// ten, then twenty-five more per "Show more"; a search flip starts over.
    @State private var settledVisible = T3ThreadList.settledInitialCount

    /// `threadListV2.ts` over the entries: pinned and active cards, the
    /// snoozed shelf, the settled tail — search by title, as upstream.
    private var listItems: [T3ThreadList.ListItem] { listLayout.items }
    private var listLayout: (items: [T3ThreadList.ListItem], hiddenSettled: Int) {
        let now = Date()
        var input = T3ThreadList.Input(threads: entries.map(\.thread), now: now)
        input.searchQuery = search
        input.snoozedShelfExpanded = showSnoozed
        input.settledShelfExpanded = showSettled
        input.settledLimit = settledVisible
        let layout = T3ThreadList.buildItems(input)
        let items = T3ThreadList.buildListItems(items: layout.items, pendingTasks: [], snoozedCount: layout.snoozedCount,
                                                snoozedShelfExpanded: showSnoozed, snoozedShelfHeaderIndex: layout.snoozedShelfHeaderIndex,
                                                settledCount: layout.settledCount, settledShelfExpanded: showSettled,
                                                settledShelfHeaderIndex: layout.settledShelfHeaderIndex, snoozeLabelNow: now)
        return (items, layout.hiddenSettledCount)
    }
    private var entriesByKey: [String: T3HomeEntry] { Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }

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
        let byKey = entriesByKey
        let layout = listLayout
        return List {
            ForEach(awsLogins) { awsRow($0) }
            ForEach(layout.items) { listItem in
                switch listItem {
                case let .thread(item, snoozeWakeLabel):
                    if let e = byKey[item.thread.key] { rowItem(e, item: item, snoozeLabel: snoozeWakeLabel) }
                case let .snoozedShelf(count, expanded):
                    shelfHeader(expanded ? "Snoozed" : "Snoozed (\(count))", expanded: expanded,
                                line: t3.mobile.primary.color.opacity(0.2), text: t3.mobile.foregroundSecondary.color) {
                        showSnoozed.toggle()
                    }
                case let .settledShelf(count, expanded):
                    shelfHeader(expanded ? "Settled" : "Settled (\(count))", expanded: expanded,
                                line: t3.mobile.border.color, text: t3.mobile.foregroundTertiary.color) {
                        showSettled.toggle()
                    }
                case .pending:
                    EmptyView()   // queued drafts arrive with the new-task flow's pending tasks
                }
            }
            if showSettled, layout.hiddenSettled > 0 { showMore(hidden: layout.hiddenSettled) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .onChange(of: search) { _, _ in settledVisible = T3ThreadList.settledInitialCount }
    }

    /// The Home list's footer (`HomeScreen.tsx` ListFooterComponent): a
    /// dashed capsule reading "Show more (N settled hidden)".
    private func showMore(hidden: Int) -> some View {
        Button { settledVisible += T3ThreadList.settledPageCount } label: {
            Text("Show more (\(hidden) settled hidden)")
                .font(T3Font.mobile(.xs, .medium)).foregroundStyle(t3.mobile.foregroundMuted.color)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(t3.mobile.border.color))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(min(hidden, T3ThreadList.settledPageCount)) more settled threads")
        .padding(.horizontal, 16).padding(.top, 8)
        .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(t3.mobile.screen.color)
    }

    private func rowItem(_ e: T3HomeEntry, item: T3ThreadList.Item, snoozeLabel: String?) -> some View {
        let base = AnyView(Button { open(e) } label: { T3HomeRow(entry: e, snoozeLabel: snoozeLabel) }.buttonStyle(.plain))
        return (decorate?(e, item, base) ?? base)
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
                    Text("\(item.needLabel) · \(item.subjectLabel) · \(SessionsScreen.awsPhase(item))")
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
    /// "Wakes 5:00 PM" on a snoozed (slim) row, where the age would be.
    var snoozeLabel: String? = nil
    var now: Date = Date()
    @Environment(\.t3) private var t3

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // `ProjectFavicon` size 15: the folder fallback is 0.78 of it, icon-subtle.
                Image(systemName: "folder.fill").font(.system(size: 15 * 0.78)).foregroundStyle(t3.mobile.iconSubtle.color)
                Text(entry.repo).font(T3Font.mobile(.sm, .medium)).lineLimit(1)
                    .foregroundStyle(t3.mobile.foregroundMuted.color)
                Spacer(minLength: 8)
                if entry.thread.pinnedAt != nil {
                    Image(systemName: "pin").font(.system(size: 11)).foregroundStyle(t3.mobile.foregroundMuted.color)
                }
                if let snoozeLabel {
                    Text(snoozeLabel).font(T3Font.mobile(.xs)).monospacedDigit().foregroundStyle(t3.mobile.foregroundTertiary.color)
                } else if let label = statusLabel {
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
                // `ProviderInstanceIcon`: the glyph at 60 %, the account
                // bubble full strength in its bottom-right corner (12 pt,
                // card fill, a hairline in the screen colour to cut it out).
                T3ProviderIcon(size: 14).opacity(0.6)
                    .overlay(alignment: .bottomTrailing) {
                        if let badge = entry.accountBadge {
                            Text(badge).font(.system(size: 7, weight: .semibold))
                                .foregroundStyle(t3.mobile.foregroundMuted.color)
                                .padding(.horizontal, 2)
                                .frame(minWidth: 12).frame(height: 12)
                                .background(t3.mobile.card.color, in: Capsule())
                                .overlay(Capsule().stroke(t3.mobile.screen.color, lineWidth: 1))
                                .offset(x: 3, y: 3)
                        }
                    }
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
        // `text-adaptive-sky-600-400` (upstream 357b8d521): the Mac's sky.
        case .working:
            let sky = t3.scheme == .dark ? T3Tailwind.sky400 : T3Tailwind.sky600
            return ("Working", Color(.sRGB, red: Double(sky.r) / 255, green: Double(sky.g) / 255, blue: Double(sky.b) / 255))
        case .failed: return ("Failed", t3.mobile.dangerForeground.color)
        case .ready: return nil
        }
    }
}
