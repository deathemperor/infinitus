import SwiftUI
import InfinitusCore
import InfinitusUI

/// The Fleet tab (#9 native shell): a real inset-grouped `List` of the
/// mirrored accounts, one section per engine fleet (#9 issue 9). The
/// SHELL is iOS — navigation stack, large title, pull-to-refresh, row
/// taps into a sheet, context menu, haptics — while every gauge, marker,
/// label and effect inside a row is the shared vocabulary
/// (`AccountHeaderLine` / `AccountUsageLines` over `AccountCells`), in
/// the Mac's own order.
struct NativeFleetScreen: View {
    @ObservedObject var model: MirrorModel
    @ObservedObject var usage: MobileUsage
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var detail: AccountRef?
    @State private var scanning = false
    @State private var pairedWith: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Row width, for the wide (landscape / regular) row order. Measured
    /// from a background probe rather than a GeometryReader WRAPPER — a
    /// wrapper between the navigation stack and the list breaks the
    /// large title (it collapsed to an inline one, first run).
    @State private var width: CGFloat = 0

    /// `.sheet(item:)` needs identity; an account number alone collides
    /// across fleets (two engines can both have a #1), so the ref also
    /// carries which fleet it came from.
    private struct AccountRef: Identifiable {
        let engineID: String
        let number: Int
        var id: String { "\(engineID)/\(number)" }
    }

    var body: some View {
        NavigationStack {
            content(wide: width > 600 || sizeClass == .regular)
                .navigationTitle(model.rowTheme.tabLabel("fleet"))
                .refreshable { await model.refresh() }
                .background {
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { measure(geo.size) }
                            .onChange(of: geo.size) { _, size in measure(size) }
                    }
                }
                .onAppear { usage.loadIfNeeded() }
                .navigationDestination(isPresented: $model.outlookShown) { OutlookScreen(model: model) }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink { StatsScreen(model: model) } label: { Image(systemName: "chart.bar.xaxis") }
                            .accessibilityLabel("Stats")
                    }
                }
        }
        // The one shared cue that has a phone equivalent: a switch is a
        // success beat, an account dying is a warning one. The trigger is
        // the ACTIVE ACCOUNT, not switchFlashTick — the tick also bumps on
        // every intro replay (i.e. every foregrounding), which would buzz
        // the phone for nothing.
        .sensoryFeedback(.success, trigger: model.activeNumber)
        .sensoryFeedback(.warning, trigger: deathCount)
        .sheet(item: $detail) { ref in
            if let fleet = model.fleets.first(where: { $0.engineID == ref.engineID }),
               let account = fleet.accounts.first(where: { $0.number == ref.number }) {
                AccountDetailSheet(fleet: fleet, usage: usage, account: account)
            }
        }
        // The bars take their fill-up cue from the environment, not the
        // model (GaugeBar has no model) — same wiring as the Mac popup.
        .environment(\.introTick, model.introTick)
        .environment(\.introBarDelay, model.introBarDelay)
    }

    @ViewBuilder private func content(wide: Bool) -> some View {
        if model.fleets.allSatisfy({ $0.accounts.isEmpty }) {
            // Pairing starts here (critique 2026-09-04: it had no
            // beginning — the empty state described a path in prose).
            ContentUnavailableView {
                Label {
                    Text("Not paired with a Mac")
                } icon: {
                    if model.rowTheme.plain || model.rowTheme.loadingIcon.isEmpty {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    } else {
                        ThemedIcon(theme: model.rowTheme, moving: false)
                    }
                }
            } description: {
                Text(model.error ?? "Scan the QR code in the Mac app's Settings → Devices to see its accounts here.")
            } actions: {
                if PairScanner.isSupported {
                    Button { scanning = true } label: {
                        Label("Scan the Mac's QR code", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .sheet(isPresented: $scanning) {
                PairScannerSheet { payload in
                    if model.applyPairing(payload) { pairedWith = "the Mac" }
                }
            }
            .alert("Paired", isPresented: Binding(get: { pairedWith != nil }, set: { if !$0 { pairedWith = nil } })) {
                Button("OK") {}
            } message: {
                Text("Paired with \(model.snapshot?.machineName ?? pairedWith ?? "the Mac"). Its accounts and sessions show up as soon as it answers.")
            }
            .sensoryFeedback(.success, trigger: pairedWith)
        } else {
            let visibleFleets = model.fleets.filter { fleet in
                !(fleet.engineID.hasPrefix("claude-code-") && fleet.accounts.isEmpty)
            }
            List {
                allDeadSection
                heroSection
                outlookSection
                ForEach(visibleFleets) { fleet in
                    accountSection(fleet, isFirst: fleet.id == visibleFleets.first?.id, wide: wide)
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    /// The one-second glance the lock screen already gives (critique
    /// 2026-09-04): the active account in full, who's next, and the
    /// sessions line — tap it for what's waiting.
    @ViewBuilder private var heroSection: some View {
        if let fleet = model.primary, let active = fleet.accounts.first(where: { $0.active }) {
            Section {
                row(active, fleet: fleet, index: 0, wide: false, full: true)
                HStack(spacing: 12) {
                    if let next = fleet.nextCandidate.flatMap({ n in fleet.accounts.first { $0.number == n } }) {
                        Label(AccountSummaryFormat.accountShortName(next), systemImage: "arrow.right.circle")
                            .lineLimit(1).truncationMode(.middle)
                            .accessibilityLabel("Next: \(AccountSummaryFormat.accountShortName(next))")
                    }
                    Spacer(minLength: 0)
                    if let live = fleet.liveSessions {
                        Button { model.requestedTab = "sessions" } label: {
                            HStack(spacing: 4) {
                                Text(sessionsLine(live)).monospacedDigit()
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle((live.waiting ?? 0) > 0 ? Color.orange : Color.secondary)
                    }
                }
                .font(.subheadline)
                .padding(.vertical, 2)
            } header: {
                statusHeader
            }
        }
    }

    private func sessionsLine(_ live: LiveSessions) -> String {
        var parts = ["\(live.busy) of \(live.total) working"]
        if let waiting = live.waiting, waiting > 0 { parts.append("\(waiting) waiting on you") }
        return parts.joined(separator: " · ")
    }

    /// The large title's subtitle line — `.navigationSubtitle` is macOS
    /// only, so the machine/as-of caption (and the staleness capsule)
    /// ride the first fleet section's header.
    @ViewBuilder private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let snapshot = model.snapshot {
                // Fresh: machine + as-of on one caption. Stale: the
                // capsule below carries the as-of, so the caption drops
                // it rather than printing the same time twice.
                Text(isStale(snapshot.capturedAt)
                     ? snapshot.machineName
                     : "\(snapshot.machineName) · as of "
                       + snapshot.capturedAt.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline).foregroundStyle(.secondary)
                if isStale(snapshot.capturedAt) {
                    Label("as of \(snapshot.capturedAt.formatted(date: .omitted, time: .shortened)) — is the Mac awake?",
                          systemImage: "clock.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.yellow.opacity(0.18), in: Capsule())
                }
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .textCase(nil)
        .padding(.bottom, 2)
    }

    /// Every account at a limit: the shared banner (recovering account +
    /// live countdown) in a card of its own, themed tint.
    @ViewBuilder private var allDeadSection: some View {
        if model.nextCandidate == nil, model.nextRecovery != nil {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "heart.slash.fill")
                        .font(.title3).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fleet is out").font(.headline)
                        AllDeadBanner(model: model)
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(ThemeColor.flash(model.rowTheme).opacity(0.18))
            }
        }
    }

    /// #7 on the phone: the Mac's run-rate projection and battle plan
    /// (the popup's error-slot lines), when the fleet isn't all-dead —
    /// the all-dead card already carries them via AllDeadBanner.
    @ViewBuilder private var outlookSection: some View {
        if model.nextCandidate != nil, model.forecast != nil || model.battlePlan != nil {
            Section {
                NavigationLink {
                    OutlookScreen(model: model)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        UsageForecastLine(model: model)
                        BattlePlanLine(model: model)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Outlook · tap for the full picture").textCase(nil)
            }
        }
    }

    /// One fleet's rows, headed by the machine/as-of caption (first
    /// fleet only) and — when more than one fleet is on screen — a slim
    /// "provider · engine" line, the native equivalent of the Mac
    /// popup's `FleetHeader`.
    private func accountSection(_ fleet: MirrorFleetModel, isFirst: Bool, wide: Bool) -> some View {
        // The primary fleet's active account lives in the hero above.
        let accounts = fleet.displayAccounts.filter { !(fleet.id == model.primary?.id && $0.active) }
        return Section {
            ForEach(Array(accounts.enumerated()),
                    id: \.element.number) { index, account in
                row(account, fleet: fleet, index: index, wide: wide,
                    full: account.active || fleet.nextCandidate == account.number || needsFullLines(account))
            }
        } header: {
            VStack(alignment: .leading, spacing: 6) {
                if isFirst, model.primary?.accounts.contains(where: { $0.active }) != true { statusHeader }
                if model.fleets.count > 1, let label = fleet.fleetLabel {
                    HStack(spacing: 6) {
                        Text(label.provider.displayName).fontWeight(.semibold)
                        Text("·").foregroundStyle(.tertiary)
                        Text(label.engineName).foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .textCase(nil)
                }
            }
        }
    }

    /// Limited or attention-needing accounts keep their full lines — the
    /// reset time and the re-login action are the point of the row.
    private func needsFullLines(_ account: Account) -> Bool {
        SentinelNotes.note(for: account.usageStatus) != nil || AccountRowVitals.isDead(account)
    }

    /// Standby accounts in one line: name · worst window · reset.
    private func compactUsage(_ account: Account) -> String {
        var parts: [String] = []
        if let five = account.usage?.fiveHour { parts.append("5h \(Int(five.pct))%") }
        if let seven = account.usage?.sevenDay { parts.append("7d \(Int(seven.pct))%") }
        if let reset = ResetLabel.compact(account.usage?.fiveHour) { parts.append("resets \(reset)") }
        return parts.isEmpty ? "no usage yet" : parts.joined(separator: " · ")
    }

    private func row(_ account: Account, fleet: MirrorFleetModel, index: Int, wide: Bool,
                     full: Bool) -> some View {
        // A Button, not an onTapGesture: inside a List that's the tap
        // target that actually fires (and gets the press highlight for
        // free) — a gesture on the row content never did.
        Button {
            detail = AccountRef(engineID: fleet.engineID, number: account.number)
        } label: {
            VStack(alignment: .leading, spacing: full ? 8 : 3) {
                AccountHeaderLine(model: fleet, usage: usage, account: account)
                if full {
                    AccountUsageLines(model: fleet, usage: usage,
                                      account: account, wide: wide)
                        // The gauges carry no tap of their own on a phone;
                        // the whole row is the target.
                        .allowsHitTesting(false)
                } else {
                    Text(compactUsage(account))
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(ThemeColor.resolve(
                            AccountHeadroom.colorName(forPct: AccountHeadroom.worstPct(account))))
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Paused accounts read dimmed; the ⏸ marker is in the name.
            .opacity((account.disabled ?? false) ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                UIPasteboard.general.string = account.email
            } label: {
                Label("Copy email", systemImage: "doc.on.doc")
            }
        }
        .listRowBackground(rowBackground(account, fleet: fleet))
        // The Mac's dying alarm, over the row's own bounds.
        .overlay {
            if AccountRowVitals.isCritical(account), !reduceMotion { CriticalPulse() }
        }
        // Same effect chain, same order as the Mac's stacked cards —
        // none of it under Reduce Motion.
        .switchFlash(account.active && !reduceMotion ? fleet.switchFlashTick : 0,
                     color: ThemeColor.flash(fleet.rowTheme))
        .deathFlash(reduceMotion ? 0 : fleet.deathTicks[account.number] ?? 0)
        .reviveFlash(reduceMotion ? 0 : fleet.reviveTicks[account.number] ?? 0)
        .introRowUnlessReduced(fleet, index: index, reduced: reduceMotion)
    }

    /// The Mac's active band, as a native row fill: the theme's flash
    /// tint (the app accent when the theme sets none).
    @ViewBuilder private func rowBackground(_ account: Account, fleet: MirrorFleetModel) -> some View {
        ZStack {
            // The list's own row fill, explicitly: a listRowBackground
            // replaces it, so without this the rows read as holes in the
            // grouped card (first run, light mode).
            Color(.secondarySystemGroupedBackground)
            if AccountRowVitals.isLucky(account, theme: fleet.rowTheme) {
                LuckyRowBackground(cornerRadius: 0)
            }
            if account.active {
                ThemeColor.flash(fleet.rowTheme).opacity(0.22)
            }
        }
    }

    private func measure(_ size: CGSize) {
        width = size.width
        // The Mac-popup view reads the same orientation cue.
        model.isLandscape = size.width > size.height
    }

    private var deathCount: Int {
        model.fleets.reduce(0) { $0 + $1.deathTicks.values.reduce(0, +) }
    }

    private func isStale(_ capturedAt: Date) -> Bool {
        Date().timeIntervalSince(capturedAt) > 180
    }
}

/// A row tap opens the whole account: every window in full (labels,
/// gauges, percentages, absolute reset times), plus the plan and the
/// cash estimate. Read-only by design — the phone drives no engine.
private struct AccountDetailSheet: View {
    @ObservedObject var fleet: MirrorFleetModel
    @ObservedObject var usage: MobileUsage
    let account: Account
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Slot", value: "#\(account.number)")
                    LabeledContent("Email", value: account.email)
                    if let plan = account.plan {
                        LabeledContent("Plan", value: plan)
                    }
                    LabeledContent("State", value: stateText)
                } header: {
                    Text("Account")
                }
                Section("Windows") {
                    AccountWindowDetails(model: fleet, account: account)
                }
                // usage.report is cswap-only data (the mirror carries no
                // other engine's cash cache) — gated so a same-numbered
                // account on another fleet never borrows cswap's figure.
                if fleet.engineID == MirrorFleetModel.cswapEngineID, let report = usage.report,
                   let row = report.accounts.first(where: { $0.number == account.number }) {
                    Section("Estimated spend") {
                        LabeledContent("Last \(report.days) days",
                                       value: "$\(Int(row.estimatedUSD).formatted())")
                        Text("An API-price estimate, never a bill.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(account.alias ?? account.email)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var stateText: String {
        if account.active { return "active" }
        if account.disabled ?? false { return "disabled" }
        if AccountRowVitals.isDead(account) { return "at a limit" }
        if fleet.nextCandidate == account.number { return "next up" }
        return "standby"
    }
}

private extension View {
    /// The rows' entrance slide, skipped under Reduce Motion.
    @ViewBuilder
    func introRowUnlessReduced<M: FleetModel>(_ model: M, index: Int, reduced: Bool) -> some View {
        if reduced { self } else { introRow(model, index: index) }
    }
}
