import SwiftUI
import InfinitusCore
import InfinitusUI

/// What a chat header shows, apart from where it comes from: the feed
/// screen builds it from the live session and its account, Settings
/// builds a sample so every header style can be previewed (user
/// 2026-09-05: "hud settings should show a preview per options").
struct ChatHeaderData {
    var name: String
    /// The engine's raw status ("busy", "waiting", "idle", "shell").
    var status: String
    var accountName: String?
    var plan: String?
    var chips: [WindowChip]
    /// The fleet's one-shot beats for this account (0 = never armed):
    /// the switch celebration, the death hit, the revival fanfare.
    var switchTick = 0
    var deathTick = 0
    var reviveTick = 0
    /// Dying (binding window in the 90s) and All Lucky 7s (RPG).
    var critical = false
    var lucky = false

    /// One window per row of the Fleet card, ready for a line: the
    /// session and weekly windows first, then the per-model ones.
    struct WindowChip: Identifiable {
        let id: String
        let glyph: String
        /// The model's themed name alone ("Dragon"), the glyph for the
        /// session and weekly windows.
        let name: String
        let color: Color
        let window: UsageWindow
        let session: Bool
        /// The bar's pace fire, the Fleet card's rules: 5h calm, 7d the
        /// pref (limit break RPG-only), Fable always limit under RPG.
        let burnStyle: String
        /// The fever digits: the 5h/7d pair only when BOTH sit at 77,
        /// a model bar when it does itself (RPG only).
        let lucky: Bool
        var isModel: Bool { id.hasPrefix("m:") }
    }

    static func chips(_ account: Account, theme: RowTheme, burnStyle: String = "off") -> [WindowChip] {
        var out: [WindowChip] = []
        let pref = theme.plain ? "off" : burnStyle
        let rpg = theme.id == "rpg"
        let at77 = { (w: UsageWindow?) in w.map { Int(GaugeMath.remaining(usedPct: $0.pct)) == 77 } ?? false }
        let pair = rpg && at77(account.usage?.fiveHour) && at77(account.usage?.sevenDay)
        if let w = account.usage?.fiveHour {
            let glyph = theme.plain ? theme.sessionLabel : PopupGlyph.text(theme.sessionLabel)
            out.append(.init(id: "5h", glyph: glyph, name: glyph,
                             color: ThemeColor.resolve(theme.sessionColor), window: w, session: true,
                             burnStyle: "off", lucky: pair))
        }
        if let w = account.usage?.sevenDay {
            let glyph = theme.plain ? theme.weeklyLabel : PopupGlyph.text(theme.weeklyLabel)
            out.append(.init(id: "7d", glyph: glyph, name: glyph,
                             color: ThemeColor.resolve(theme.weeklyColor), window: w, session: false,
                             burnStyle: BurnRules.weekly(pref: pref, theme: theme), lucky: pair))
        }
        for w in account.usage?.scoped ?? [] {
            let name = theme.plain ? (w.name ?? "?") : theme.modelName(w.name)
            out.append(.init(id: "m:" + (w.name ?? "?"),
                             glyph: theme.plain ? name : PopupGlyph.text(theme.scopedPrefix) + name,
                             name: name,
                             color: ThemeColor.resolve(theme.scopedColor), window: w, session: false,
                             burnStyle: BurnRules.scoped(pref: pref, theme: theme), lucky: rpg && at77(w)))
        }
        return out
    }

    static func accountName(_ account: Account) -> String {
        account.alias ?? String(account.email.prefix(while: { $0 != "@" }))
    }

    /// The Settings preview: a busy session on a Max account, part-way
    /// through its windows, under the first name in the theme's pool;
    /// the model window runs ahead of pace so the preview shows the burn.
    static func sample(theme: RowTheme) -> ChatHeaderData {
        let alias = theme.accountNames.first ?? "player1"
        let account = Account(number: 1, email: "\(alias.lowercased())@example.com", active: true,
                              usage: Usage(fiveHour: UsageWindow(pct: 71, expectedPct: 58),
                                           sevenDay: UsageWindow(pct: 34, expectedPct: 41, aheadOfPace: false),
                                           scoped: [UsageWindow(pct: 53, name: "Fable",
                                                                expectedPct: 35, aheadOfPace: true)]),
                              alias: alias, plan: "Max 20x")
        return ChatHeaderData(name: "limitless", status: "busy", accountName: alias, plan: "Max 20x",
                              chips: chips(account, theme: theme, burnStyle: "flame"))
    }
}

/// The chat header in each of its styles — Compact, Stat strip, Game
/// HUD (Settings › Appearance › Chat header). The middle is the route
/// into the session's details when `route` is set; without one (the
/// previews) the header is inert, buttons included.
struct ChatHeaderView: View {
    let style: String
    let theme: RowTheme
    let data: ChatHeaderData
    var route: SessionDetailRoute? = nil
    var onBack: (() -> Void)? = nil
    /// The Fleet card's gate: no flashes, pulses or fire under Reduce Motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch style {
        case "strip":
            titleRow
            statStrip
        case "hud":
            hud
        default:
            compact
        }
    }

    @ViewBuilder private func link<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if let route {
            NavigationLink(value: route) { content().contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel("Session details")
        } else {
            content()
        }
    }

    private var backButton: some View {
        Button { onBack?() } label: {
            Image(systemName: "chevron.left")
                .font(.title3.weight(.semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(onBack != nil)
        .accessibilityLabel("Back")
    }

    /// One tap puts what's on screen into the composer as an attachment
    /// (user 2026-09-05: "put the captured in attachment instead of send
    /// immediately as I need to describe the request").

    private var statusWord: String { SessionWords.status(data.status, theme: theme) }
    private var statusColor: Color { SessionWords.color(data.status) }
    private var planText: String? {
        data.plan.map { theme.plain ? $0 : theme.planLabel($0, compact: true) }
    }

    // MARK: option 1 — Messenger-style, one tier

    /// Back · avatar (the theme's glyph on its tint) · name, then the
    /// state and account on one caption line, then every window as
    /// glyph + value on a third.

    private var compact: some View {
        HStack(spacing: 8) {
            backButton
            link {
                HStack(spacing: 10) {
                    avatar
                    VStack(alignment: .leading, spacing: 2) {
                        Text(data.name).font(.headline).lineLimit(1)
                        HStack(spacing: 4) {
                            Text(statusWord).foregroundStyle(statusColor)
                            if let account = data.accountName {
                                Text("·").foregroundStyle(.tertiary)
                                Text(account).lineLimit(1)
                                if let planText {
                                    Text(planText)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.primary.opacity(0.08), in: Capsule())
                                }
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        if !data.chips.isEmpty {
                            HStack(spacing: 10) {
                                ForEach(data.chips) { chip in
                                    HStack(spacing: 2) {
                                        Text(chip.glyph).foregroundStyle(chip.color)
                                        Text("\(Int(GaugeMath.remaining(usedPct: chip.window.pct)))%")
                                            .monospacedDigit()
                                            .foregroundStyle(chip.window.pct >= 100 ? .red : .primary)
                                    }
                                }
                            }
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4).padding(.trailing, 8).padding(.vertical, 6)
    }

    /// The theme's glyph on its tint; the Off theme gets the session's
    /// initial on its state color.
    private var avatar: some View {
        ZStack {
            Circle().fill(theme.plain ? statusColor.opacity(0.22) : ThemeColor.flash(theme).opacity(0.28))
            if glyph.isEmpty {
                Text(String(data.name.prefix(1)).uppercased())
                    .font(.headline).foregroundStyle(statusColor)
            } else {
                Text(glyph).font(.title3)
            }
        }
        .frame(width: 38, height: 38)
        .overlay(alignment: .bottomTrailing) {
            Circle().fill(statusColor).frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                .offset(x: 1, y: 1)
        }
    }

    private var glyph: String {
        theme.plain ? "" : PopupGlyph.text(theme.activeIcon.isEmpty ? theme.sessionLabel : theme.activeIcon)
    }

    // MARK: option 2 — title row + stat strip

    /// Back · name + state (the tap into the details).
    private var titleRow: some View {
        HStack(spacing: 4) {
            backButton
            link {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(data.name).font(.headline).lineLimit(1)
                        HStack(spacing: 5) {
                            Circle().fill(statusColor).frame(width: 7, height: 7)
                            Text(statusWord)
                            if let account = data.accountName {
                                Text("·").foregroundStyle(.tertiary)
                                Text(account).lineLimit(1)
                                if let planText {
                                    Text(planText)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.primary.opacity(0.08), in: Capsule())
                                }
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4).padding(.trailing, 8).padding(.top, 2)
    }

    /// Every window as a mini gauge on one row; no times, no resets —
    /// those live in the details.
    @ViewBuilder private var statStrip: some View {
        if !data.chips.isEmpty {
            // Sideways scroll rather than a wrap when a fourth window
            // shows up; three fit.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(data.chips) { chip in
                        HStack(spacing: 3) {
                            Text(chip.glyph).font(.caption2.weight(.bold)).foregroundStyle(chip.color)
                            if theme.plain {
                                Text("\(Int(GaugeMath.remaining(usedPct: chip.window.pct)))%")
                                    .font(.caption2.weight(.semibold)).monospacedDigit()
                            } else {
                                GaugeBar(remaining: GaugeMath.remaining(usedPct: chip.window.pct),
                                         color: chip.color,
                                         paceRemaining: chip.window.expectedPct.map { 100 - $0 },
                                         dividers: dividers(chip),
                                         animated: !reduceMotion,
                                         burnStyle: chip.burnStyle,
                                         burnHeat: heat(chip), chill: chill(chip),
                                         lucky: chip.lucky)
                                    .glowOnChange(of: chip.window.pct, color: ThemeColor.flash(theme))
                            }
                        }
                        .fixedSize()
                    }
                }
                .padding(.horizontal, 16)
            }
            .environment(\.gaugeScale, 0.8)
            .padding(.top, 2).padding(.bottom, 8)
        }
    }

    // MARK: option 3 — game HUD (unit frame)

    /// A WoW-style unit frame (user 2026-09-05: "game HUD like WoW's"):
    /// the portrait in a ringed medallion overlapping the left end of a
    /// dark panel, the level on the ring, the name in the theme's color
    /// with the state beside it, the session and weekly windows as
    /// glossy bars with the value inside, and every model window as a
    /// buff square. Off keeps the frame in neutral grey.
    private var ring: Color { theme.plain ? Color.secondary : ThemeColor.flash(theme) }
    private var plate: Color { theme.plain ? Color.primary.opacity(0.08) : Color.black.opacity(0.62) }
    private var ink: Color { theme.plain ? Color.primary : Color.white }
    private var hudCorner: CGFloat { 8 }
    private var portraitSize: CGFloat { 58 }
    private var nameFont: Font { .system(size: 14, weight: .heavy, design: .rounded) }

    private func dividers(_ chip: ChatHeaderData.WindowChip) -> [Double] {
        chip.session ? (1..<5).map { Double($0) * 20 } : (1..<7).map { Double($0) * 100 / 7 }
    }
    private func heat(_ chip: ChatHeaderData.WindowChip) -> Double {
        GaugeMath.burnHeat(usedPct: chip.window.pct, expectedPct: chip.window.expectedPct,
                           ahead: chip.window.aheadOfPace)
    }
    private func chill(_ chip: ChatHeaderData.WindowChip) -> Double {
        GaugeMath.chillDepth(usedPct: chip.window.pct, expectedPct: chip.window.expectedPct,
                             ahead: chip.window.aheadOfPace)
    }

    private var hud: some View {
        HStack(spacing: 2) {
            backButton
            link {
                ZStack(alignment: .leading) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if data.lucky, !reduceMotion {
                                LuckyName(text: data.name, font: nameFont)
                            } else {
                                Text(data.name)
                                    .font(nameFont)
                                    .foregroundStyle(theme.plain ? Color.primary : ring)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Text(statusWord)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(statusColor)
                                .lineLimit(1)
                        }
                        // Every window is a bar, the models' too (user
                        // 2026-09-05: "Dragon is a bar").
                        ForEach(data.chips) { chip in hudBar(chip) }
                        if let account = data.accountName {
                            Text(account)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(ink.opacity(0.7))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .padding(.leading, portraitSize / 2 + 8)
                    .padding(.trailing, 8).padding(.vertical, 6)
                    .background {
                        ZStack {
                            LinearGradient(colors: [plate, plate.opacity(theme.plain ? 0.6 : 0.85)],
                                           startPoint: .top, endPoint: .bottom)
                            // The fever's rainbow wash and orbiting comet,
                            // over the plate and under the content.
                            if data.lucky, !reduceMotion { LuckyRowBackground(cornerRadius: hudCorner) }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: hudCorner))
                    }
                    .overlay(RoundedRectangle(cornerRadius: hudCorner).stroke(ring.opacity(0.75), lineWidth: 1.2))
                    .overlay(RoundedRectangle(cornerRadius: hudCorner - 2).inset(by: 2)
                        .stroke(Color.black.opacity(theme.plain ? 0 : 0.4), lineWidth: 1))
                    // The Fleet card's row effects, on the plate: the dying
                    // alarm, then the same one-shot chain in the same order.
                    .overlay { if data.critical, !reduceMotion { CriticalPulse(cornerRadius: hudCorner) } }
                    .switchFlash(reduceMotion ? 0 : data.switchTick, color: ThemeColor.flash(theme))
                    .deathFlash(reduceMotion ? 0 : data.deathTick)
                    .reviveFlash(reduceMotion ? 0 : data.reviveTick)
                    .padding(.leading, portraitSize / 2)
                    portrait
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4).padding(.trailing, 8).padding(.vertical, 6)
    }

    /// The medallion: the theme's glyph on a radial tint inside a thick
    /// ring with a dark inner rim, the plan tier in a small disc on the
    /// ring bottom-left, the state dot top-right.
    private var portrait: some View {
        ZStack {
            Circle().fill(RadialGradient(
                colors: [ThemeColor.flash(theme).opacity(theme.plain ? 0.15 : 0.45),
                         theme.plain ? Color(.systemBackground) : Color.black.opacity(0.7)],
                center: .center, startRadius: 4, endRadius: portraitSize / 2))
            Circle().strokeBorder(ring, lineWidth: 3.5)
            Circle().inset(by: 4.5).strokeBorder(Color.black.opacity(theme.plain ? 0.15 : 0.55), lineWidth: 1.5)
            if glyph.isEmpty {
                Text(String(data.name.prefix(1)).uppercased())
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(statusColor)
            } else {
                Text(glyph).font(.system(size: 27))
            }
        }
        .frame(width: portraitSize, height: portraitSize)
        .shadow(color: .black.opacity(theme.plain ? 0 : 0.5), radius: 3, y: 1)
        .overlay(alignment: .bottomLeading) {
            if let plan = data.plan {
                let tier = theme.planLabel(plan, compact: true)
                    .replacingOccurrences(of: theme.planPrefix, with: "")
                Text(tier)
                    .font(.system(size: 9, weight: .heavy, design: .rounded)).monospacedDigit().lineLimit(1)
                    .foregroundStyle(theme.plain ? Color.primary : ring)
                    .frame(minWidth: 22, minHeight: 22)
                    .padding(.horizontal, 2)
                    .background(theme.plain ? Color(.systemBackground) : Color.black.opacity(0.88), in: Capsule())
                    .overlay(Capsule().stroke(ring, lineWidth: 1.5))
                    .offset(x: -4, y: 4)
            }
        }
        .overlay(alignment: .topTrailing) {
            Circle().fill(statusColor).frame(width: 11, height: 11)
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                .offset(x: 1, y: -1)
        }
    }

    /// A unit-frame bar: the shared gauge in its HUD skin — the window's
    /// glyph at the left, what's left at the right, a glossy fill in the
    /// window's color — so every effect the Fleet card's bars play plays
    /// here too (#72: "keep bar effects and animation").
    private func hudBar(_ chip: ChatHeaderData.WindowChip) -> some View {
        GeometryReader { geo in
            GaugeBar(remaining: GaugeMath.remaining(usedPct: chip.window.pct),
                     color: chip.color,
                     paceRemaining: chip.window.expectedPct.map { 100 - $0 },
                     dividers: dividers(chip),
                     animated: !reduceMotion,
                     burnStyle: chip.burnStyle,
                     burnHeat: heat(chip), chill: chill(chip),
                     dropAnchor: .center,
                     lucky: chip.lucky,
                     hud: GaugeHUD(glyph: chip.glyph, ink: ink, ring: ring,
                                   plain: theme.plain, width: geo.size.width))
        }
        .frame(height: 14)
        .glowOnChange(of: chip.window.pct, color: ThemeColor.flash(theme))
    }
}

/// The Settings picker with a live preview of each header style, drawn
/// with the current theme on the same tint the chat uses.
struct ChatHeaderPicker: View {
    @Binding var selection: String
    let theme: RowTheme

    private static let styles = [("compact", "Compact"), ("strip", "Stat strip"), ("hud", "Game HUD")]

    var body: some View {
        ForEach(Self.styles, id: \.0) { tag, label in
            Button { selection = tag } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(label).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: selection == tag ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection == tag ? Color.accentColor : Color.secondary)
                    }
                    VStack(spacing: 0) {
                        ChatHeaderView(style: tag, theme: theme, data: .sample(theme: theme))
                    }
                    .background(theme.plain ? Color.clear : ThemeColor.flash(theme).opacity(0.16))
                    .background(.bar)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Room for the whole header: the Form's default insets
            // clipped the strip's third gauge.
            .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            .accessibilityAddTraits(selection == tag ? .isSelected : [])
        }
    }
}
