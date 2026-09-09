import SwiftUI
import InfinitusCore
import InfinitusUI

/// Settings → Usage: the Limits view as T3 draws it at upstream 6c583620f
/// (`apps/mobile/src/features/usage/UsageLimitsPooled.tsx`, which replaced
/// the per-account rows the refs predate). One group per Mac and engine
/// fleet; inside it one card per window pooled across the fleet's accounts:
/// quota left, pace, the next refill, a numbered segment per account and a
/// row per account. Countdowns anchor to `now` and move only on refresh.
/// The Usage (cost) tab lands separately.
struct T3UsageScreen: View {
    @ObservedObject var model: MirrorModel
    @Environment(\.t3) private var t3
    @State private var now = Date()
    /// nil = every Mac; otherwise the Macs kept (nil member = this phone's primary).
    @State private var selectedMacs: Set<String?>? = nil

    private struct Group: Identifiable {
        let macId: String?
        let fleet: MirrorFleetModel
        let macName: String
        var id: String { "\(macId ?? "")/\(fleet.id)" }
    }

    private var groups: [Group] {
        var out = model.fleets.map { Group(macId: nil, fleet: $0, macName: model.machineName(macId: nil)) }
        for mac in model.others {
            out += mac.fleets.map { Group(macId: mac.id, fleet: $0, macName: mac.pairing.name) }
        }
        return out.filter { selectedMacs?.contains($0.macId) ?? true }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                let shown = groups
                if shown.isEmpty {
                    Text(selectedMacs?.isEmpty == true ? "Select a Mac to see limits."
                                                        : "No account on the selected Macs reports subscription limits.")
                        .font(T3Font.mobile(.base)).foregroundStyle(t3.mobile.foregroundMuted.color)
                        .frame(maxWidth: .infinity).padding(.vertical, 48)
                }
                ForEach(shown) { group in
                    T3UsageLimitsGroup(macId: group.macId, fleet: group.fleet,
                                       macName: model.others.isEmpty ? nil : group.macName, now: now)
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 36)
        }
        .background(t3.mobile.sheet.color.ignoresSafeArea())
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.others.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { macFilter }
            }
        }
        .refreshable {
            await model.refresh()
            await model.refresh(macId: model.others.first?.id)
            now = Date()
        }
        .onAppear { now = Date() }
        .navigationDestination(for: T3UsageAccountRoute.self) { route in
            T3UsageAccountScreen(model: model, route: route)
        }
    }

    /// T3's environment filter: every Mac, or a checked subset.
    private var macFilter: some View {
        let macs: [(String?, String)] = [(nil, model.machineName(macId: nil))] + model.others.map { ($0.id, $0.pairing.name) }
        return Menu {
            Button { selectedMacs = nil } label: {
                if selectedMacs == nil { Label("All Macs", systemImage: "checkmark") } else { Text("All Macs") }
            }
            ForEach(macs, id: \.0) { id, name in
                Button {
                    var set = selectedMacs ?? Set(macs.map(\.0))
                    if set.contains(id) { set.remove(id) } else { set.insert(id) }
                    selectedMacs = set.count == macs.count ? nil : set
                } label: {
                    if selectedMacs?.contains(id) ?? true { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        } label: {
            Image(systemName: selectedMacs == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(t3.mobile.icon.color)
        }
        .accessibilityLabel("Filter Macs")
    }
}

/// Where a tapped segment or row goes; the account is resolved again on
/// arrival so live quota keeps reaching the open detail.
struct T3UsageAccountRoute: Hashable {
    let macId: String?
    let fleetId: String
    let number: Int
    let poolId: String
}

/// Claude's brand orange in both themes; the neutral engines flip with the
/// theme or their bars vanish (`usageProviders.ts`).
enum T3UsageColors {
    static func bar(_ provider: Provider, dark: Bool) -> Color {
        switch provider {
        case .claude: return Color(.sRGB, red: 0xd9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
        case .codex: return dark ? Color(.sRGB, red: 0xe6 / 255, green: 0xe6 / 255, blue: 0xe6 / 255)
                                 : Color(.sRGB, red: 0x3c / 255, green: 0x3c / 255, blue: 0x43 / 255)
        default: return dark ? Color(.sRGB, red: 0xa1 / 255, green: 0xa1 / 255, blue: 0xaa / 255)
                             : Color(.sRGB, red: 0x52 / 255, green: 0x52 / 255, blue: 0x5b / 255)
        }
    }
}

/// One fleet: the provider heading, a card per pooled window, then the
/// accounts whose status has a line to add.
private struct T3UsageLimitsGroup: View {
    let macId: String?
    @ObservedObject var fleet: MirrorFleetModel
    let macName: String?
    let now: Date
    @Environment(\.t3) private var t3

    var body: some View {
        let members = fleet.accounts.map { T3UsageLimits.member($0, now: now) }
        let pools = T3UsageLimits.pools(members, now: now)
        let notices = T3UsageLimits.notices(fleet.accounts)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                T3ProviderIcon(size: 18)
                Text(fleet.provider.displayName + (macName.map { " · \($0)" } ?? ""))
                    .font(T3Font.mobile(.base, .medium)).foregroundStyle(t3.mobile.foreground.color)
            }
            .padding(.horizontal, 4)
            if pools.isEmpty {
                Text("No limits reported.").font(T3Font.mobile(.sm)).foregroundStyle(t3.mobile.foregroundMuted.color)
                    .padding(.horizontal, 4)
            }
            ForEach(pools, id: \.id) { pool in
                T3PoolWindowCard(pool: pool, color: T3UsageColors.bar(fleet.provider, dark: t3.scheme == .dark),
                                 now: now, route: { T3UsageAccountRoute(macId: macId, fleetId: fleet.id, number: $0, poolId: pool.id) })
            }
            ForEach(notices, id: \.self) { notice in
                Text(notice).font(T3Font.mobile(.sm)).foregroundStyle(t3.mobile.foregroundMuted.color)
                    .padding(.horizontal, 4)
            }
        }
    }
}

private struct T3PoolWindowCard: View {
    let pool: T3UsageLimits.Pool
    let color: Color
    let now: Date
    let route: (Int) -> T3UsageAccountRoute
    @Environment(\.t3) private var t3

    private static let paceLabel: [T3UsageLimits.Pace: String] = [.ahead: "Ahead of pace", .on: "On pace", .under: "Under pace"]

    var body: some View {
        let p = t3.mobile
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pool.label).font(T3Font.mobile(.sm, .medium)).foregroundStyle(p.foreground.color)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(pool.remainingPct)%").font(T3Font.mobile(.xxxl, .bold)).monospacedDigit()
                            .foregroundStyle(p.foreground.color)
                        Text("left").font(T3Font.mobile(.sm)).foregroundStyle(p.foregroundMuted.color)
                    }
                }
                Spacer(minLength: 0)
                if let pace = pool.pace {
                    Text(Self.paceLabel[pace]!).font(T3Font.mobile(.xs)).foregroundStyle(p.foregroundTertiary.color)
                }
            }
            if let refill = pool.nextRefill {
                Text("↻ +\(refill.restoresPct)% " + (refill.at <= now ? "now" : "in \(T3UsageLimits.formatDuration(refill.at.timeIntervalSince(now)))"))
                    .font(T3Font.mobile(.xs)).monospacedDigit().foregroundStyle(p.foregroundMuted.color)
            }
            HStack(spacing: 4) {
                ForEach(Array(pool.columns.enumerated()), id: \.offset) { index, column in
                    if let window = column.window {
                        NavigationLink(value: route(column.member.number)) {
                            T3AccountSegment(remaining: window.remainingPct, color: color, pending: window.resetsAt != nil)
                                .overlay {
                                    Text("\(index + 1)").font(T3Font.mobile(.xs, .medium)).monospacedDigit()
                                        .foregroundStyle(p.foreground.color)
                                }
                                .frame(height: 28).frame(maxWidth: .infinity)
                                .background(p.subtle.color)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Segment \(index + 1), \(column.member.name), \(window.remainingPct)% left")
                        .accessibilityHint("Show account details")
                    } else {
                        Color.clear.frame(height: 28).frame(maxWidth: .infinity)
                    }
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(pool.columns.enumerated()), id: \.offset) { index, column in
                    if let window = column.window {
                        let resetsIn = T3UsageLimits.resetsIn(window, now: now)
                        NavigationLink(value: route(column.member.number)) {
                            HStack(spacing: 8) {
                                Text("\(index + 1)").font(T3Font.mobile(.xs, .medium)).monospacedDigit()
                                    .foregroundStyle(p.foreground.color)
                                    .frame(width: 20, height: 20)
                                    .background(p.subtleStrong.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                Text(column.member.name).font(T3Font.mobile(.sm, .medium)).lineLimit(1)
                                    .foregroundStyle(p.foreground.color)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(window.remainingPct)%").font(T3Font.mobile(.sm, .medium)).monospacedDigit()
                                    .foregroundStyle(p.foreground.color)
                                if let resetsIn {
                                    Text(resetsIn.replacingOccurrences(of: "resets in ", with: "↻ "))
                                        .font(T3Font.mobile(.xs)).monospacedDigit().foregroundStyle(p.foregroundMuted.color)
                                }
                            }
                            .frame(minHeight: 44)
                            .opacity(column.member.disabled ? 0.55 : 1)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Segment \(index + 1), \(column.member.name), \(window.remainingPct)% left" + (resetsIn.map { ", \($0)" } ?? ""))
                        .accessibilityHint("Show account details")
                    }
                }
            }
        }
        .padding(16)
        .background(p.card.color, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// The remaining share in the bar's colour; the spent share hatched while a
/// reset is pending to bring it back (`AccountSegment`).
private struct T3AccountSegment: View {
    let remaining: Int
    let color: Color
    let pending: Bool

    var body: some View {
        GeometryReader { geo in
            let split = geo.size.width * Double(remaining) / 100
            ZStack(alignment: .leading) {
                if pending {
                    Hatch().stroke(color.opacity(0.22), lineWidth: 1)
                        .frame(width: geo.size.width - split).offset(x: split)
                        .clipped()
                }
                color.opacity(0.35).frame(width: split)
            }
        }
    }

    private struct Hatch: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            var x = rect.minX - rect.height
            while x < rect.maxX {
                p.move(to: CGPoint(x: x, y: rect.maxY))
                p.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                x += 6
            }
            return p
        }
    }
}

/// `UsageLimitAccountScreen`: the account's name, masked email and plan, the
/// tapped window in full, and the Mac it is signed in on.
struct T3UsageAccountScreen: View {
    @ObservedObject var model: MirrorModel
    let route: T3UsageAccountRoute
    @Environment(\.t3) private var t3
    @State private var revealed = false
    @State private var now = Date()

    var body: some View {
        let p = t3.mobile
        let fleet = model.fleets(macId: route.macId).first { $0.id == route.fleetId }
        let account = fleet?.accounts.first { $0.number == route.number }
        let members = fleet?.accounts.map { T3UsageLimits.member($0, now: now) } ?? []
        let pool = T3UsageLimits.pools(members, now: now).first { $0.id == route.poolId }
        let window = pool?.columns.first { $0.member.number == route.number }?.window
        let reset = pool?.resets.first { $0.member.number == route.number }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let account, let fleet, let window {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            T3ProviderIcon(size: 24)
                            Text(T3UsageLimits.name(alias: account.alias, email: account.email))
                                .font(T3Font.mobile(.xl, .bold)).foregroundStyle(p.foreground.color)
                        }
                        if !account.email.isEmpty {
                            Button { revealed.toggle() } label: {
                                Text(revealed ? account.email : "••••••@••••••")
                                    .font(T3Font.mobile(.sm)).foregroundStyle(p.foregroundMuted.color)
                                    .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(revealed ? "Hide account email" : "Reveal account email")
                        }
                        if let plan = account.plan {
                            Text(plan).font(T3Font.mobile(.sm)).foregroundStyle(p.foregroundMuted.color).textSelection(.enabled)
                        }
                    }
                    card {
                        Text(window.label).font(T3Font.mobile(.sm, .medium)).foregroundStyle(p.foreground.color)
                        Text("\(window.remainingPct)% left").font(T3Font.mobile(.xxxl, .bold)).monospacedDigit()
                            .foregroundStyle(p.foreground.color)
                        if let at = window.resetsAt {
                            Text("Resets \(at.formatted(date: .abbreviated, time: .shortened))")
                                .font(T3Font.mobile(.sm)).foregroundStyle(p.foregroundMuted.color).textSelection(.enabled)
                        }
                        if let reset, reset.restoresPct > 0 {
                            Text("Restores \(reset.restoresPct)% of the pool")
                                .font(T3Font.mobile(.sm)).foregroundStyle(p.foregroundMuted.color)
                        }
                    }
                    card {
                        Text("Signed in").font(T3Font.mobile(.sm, .medium)).foregroundStyle(p.foreground.color)
                        Text(model.machineName(macId: route.macId) + " · " + fleet.provider.displayName)
                            .font(T3Font.mobile(.sm)).foregroundStyle(p.foregroundMuted.color)
                    }
                } else {
                    Text("This account is no longer reporting limits on the selected Macs.")
                        .font(T3Font.mobile(.base)).foregroundStyle(p.foregroundMuted.color)
                }
            }
            .padding(20).padding(.bottom, 24)
        }
        .background(p.sheet.color.ignoresSafeArea())
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(t3.mobile.card.color, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
