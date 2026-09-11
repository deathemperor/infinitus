import SwiftUI
import InfinitusCore
import InfinitusUI

/// One motion option: the tag stored in defaults, the name, and the
/// sentence that says what it does where the drawing can't (what a bar
/// does when Reduce Motion is on, which theme a style needs).
struct MotionOption: Identifiable {
    let id: String
    let label: String
    let caption: String
}

/// The house rule for a chooser whose options can be SHOWN: a pushed
/// screen, one row per option, the row IS the option (the Mac's Themes
/// pane, this app's chat-header picker, and now these). Tapping selects
/// immediately and replays that row's preview; there is no Done.
struct MotionChooserScreen<Preview: View>: View {
    let title: String
    let footer: String
    let options: [MotionOption]
    @Binding var selection: String
    @ViewBuilder let preview: (MotionOption, Int) -> Preview

    /// Bumped on a tap; the tiles watch it and play once.
    @State private var playTick = 0

    var body: some View {
        List {
            Section {
                ForEach(options) { option in
                    Button {
                        selection = option.id
                        playTick += 1
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.label)
                                        .foregroundStyle(.primary)
                                    Text(option.caption)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: selection == option.id
                                      ? "checkmark.circle.fill" : "circle")
                                    .imageScale(.large)
                                    .foregroundStyle(selection == option.id
                                                     ? Color.accentColor : Color.secondary)
                            }
                            preview(option, selection == option.id ? playTick : 0)
                        }
                        .contentShape(Rectangle())
                        // One announcement per tile, on the label like
                        // ThemeChooserScreen's rows.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(option.label). \(option.caption)")
                        .accessibilityAddTraits(selection == option.id
                                                ? [.isButton, .isSelected] : [.isButton])
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                }
            } footer: {
                Text(footer)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - pace fire

/// The real thing: `GaugeBar` draws the burn itself, on a Core
/// Animation `LayerEffect` host, so a screen of four burning bars costs
/// nothing at idle. The RAW style tag goes in, so each row shows its own
/// effect whatever theme is on (BurnRules would fold "limit" into
/// "ember" outside RPG — the footer says so instead of hiding it).
struct PaceFireTile: View {
    let style: String
    let theme: RowTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Text(PopupGlyph.text(theme.weeklyLabel))
                .font(PopupFont.caption).bold()
                .foregroundStyle(ThemeColor.resolve(theme.weeklyColor))
            GaugeBar(remaining: 34,
                     color: ThemeColor.resolve(theme.weeklyColor),
                     paceRemaining: 59,
                     dividers: (1..<7).map { Double($0) * 100 / 7 },
                     animated: !reduceMotion,
                     burnStyle: style,
                     burnHeat: style == "off" ? 0 : 0.85)
            Spacer(minLength: 0)
        }
        .environment(\.gaugeScale, 1.6)
        // No fill-from-empty on a settings tile; the bar sits at its
        // value and burns. Load-bearing, not cosmetic: GaugeBar arms the
        // burn in the same else-branch that skips the fill, so a tile
        // that plays the entrance never ignites.
        .environment(\.gaugeIntroOnAppear, false)
        // BurnOverlay rises 11pt above the capsule (BurnEffect.swift);
        // without the pad the list row clips the flames.
        .padding(.top, 14)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - launch intro

/// Three rows entering the way the content does at launch. The offsets
/// and the springs are IntroContentReveal / IntroRowSlide's own
/// (Animations.swift), scaled to the tile; the whole thing is one shot
/// on a tap, so nothing ticks while the screen sits open.
///
/// At REST the tile still has to tell the four options apart, or the
/// chooser is four identical pictures again: a ghost of where the rows
/// come FROM sits behind them at a quarter opacity (offset up, down or
/// staggered to the right; dashed outlines for the fade, which comes
/// from nowhere).
struct EntranceTile: View {
    let style: String
    var playTick: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Grows with the reader's text so the wordmark tile beside it and
    /// this one stay one height and nothing clips at accessibility sizes.
    @ScaledMetric(relativeTo: .headline) private var tileHeight = 74.0
    @State private var settled = true

    private var dy: CGFloat {
        switch style {
        case "top": -18
        case "bottom": 18
        default: 0
        }
    }
    private var dx: CGFloat { style == "rows" ? 34 : 0 }
    /// Each row's own ghost offset — "rows" staggers, the others move as
    /// one, "fade" stays put and shows an outline instead.
    private func ghostOffset(_ row: Int) -> CGSize {
        style == "rows" ? CGSize(width: dx * Double(3 - row) / 3, height: 0)
                        : CGSize(width: 0, height: dy)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            VStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { row in
                    Capsule()
                        .fill(Color.accentColor.opacity(0.7))
                        .frame(height: 7)
                        .opacity(settled ? 1 : 0)
                        .offset(x: settled ? 0 : dx, y: settled ? 0 : dy)
                        .animation(.spring(duration: 0.55, bounce: 0.2)
                            .delay(style == "rows" ? Double(row) * 0.09 : 0),
                                   value: settled)
                        .background {
                            // Where this row starts from, drawn so the
                            // option reads without a tap.
                            if style == "fade" {
                                Capsule()
                                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                    .foregroundStyle(Color.accentColor.opacity(0.35))
                            } else {
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.25))
                                    .offset(ghostOffset(row))
                            }
                        }
                }
            }
            .padding(12)
        }
        .frame(height: tileHeight)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: playTick) { _, tick in if tick > 0 { play() } }
    }

    private func play() {
        guard !reduceMotion else { return }
        // Reset without animating, then let the value-driven spring run
        // once. A repeatForever animation here would cost a CA
        // transaction per frame for as long as the screen is open.
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { settled = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { settled = true }
    }
}

/// The title landing, with IntroTitleFlourish's own start transforms and
/// springs (Animations.swift) — the real glyph and wordmark, one shot.
/// At rest a ghost of the START transform sits behind it, so a dot (zoom
/// and spin), a big tilted stamp (slam) or nothing at all (off) tells
/// the four apart before anyone taps.
struct FlourishTile: View {
    let style: String
    let theme: RowTheme
    var playTick: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = true
    @State private var glow = 0.0
    /// The glyph sits beside `.headline` text, so it tracks the reader's
    /// size with it rather than shrinking away at accessibility sizes.
    @ScaledMetric(relativeTo: .headline) private var glyphSize = 20.0
    /// The wordmark neared the ceiling at accessibility sizes and clipped.
    @ScaledMetric(relativeTo: .headline) private var tileHeight = 74.0

    private var startScale: CGFloat {
        switch style {
        case "slam": 3.4
        case "spin", "zoom": 0.1
        default: 1
        }
    }
    private var startRotation: Double {
        switch style {
        case "slam": -12
        case "spin": -720
        default: 0
        }
    }
    private var spring: Animation {
        switch style {
        case "slam": .spring(duration: 0.5, bounce: 0.35)
        case "spin": .spring(duration: 0.9, bounce: 0.3)
        default: .spring(duration: 0.7, bounce: 0.55)
        }
    }
    private var tint: Color {
        theme.plain ? .secondary : ThemeColor.flash(theme)
    }

    /// The wordmark, once as the ghost of where it starts and once live.
    private var wordmark: some View {
        HStack(spacing: 6) {
            InfinitusGlyph()
                .frame(width: glyphSize, height: glyphSize)
            Text("Infinitus")
                .font(.headline)
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            if style != "off" {
                wordmark
                    .foregroundStyle(tint.opacity(0.25))
                    .scaleEffect(startScale)
                    .rotationEffect(.degrees(startRotation))
            }
            wordmark
                .foregroundStyle(tint)
                .scaleEffect(settled ? 1 : startScale)
                .rotationEffect(.degrees(settled ? 0 : startRotation))
                .opacity(settled ? 1 : 0)
                .brightness(glow)
                .animation(spring, value: settled)
        }
        .frame(height: tileHeight)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: playTick) { _, tick in if tick > 0 { play() } }
    }

    private func play() {
        guard !reduceMotion, style != "off" else { return }
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { settled = false; glow = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            settled = true
            // The impact flash, the way the real flourish does it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                glow = 0.8
                withAnimation(.easeOut(duration: 0.8)) { glow = 0 }
            }
        }
    }
}

// MARK: - the three screens

struct PaceFireChooser: View {
    @Binding var selection: String
    let theme: RowTheme

    private static let options = [
        MotionOption(id: "off", label: "Off", caption: "The bar just empties."),
        MotionOption(id: "ember", label: "Ember glow", caption: "Coals along the fill."),
        MotionOption(id: "flame", label: "Flame licks", caption: "Tongues above the bar."),
        MotionOption(id: "limit", label: "Limit break", caption: "A running rainbow marquee."),
    ]

    var body: some View {
        MotionChooserScreen(
            title: "Pace fire",
            footer: "A bar catches fire when its account is spending faster than the clock — the weekly bar and each model's. Limit break needs the RPG theme; under any other it burns like Ember glow. With Reduce Motion on, the bars stay still.",
            options: Self.options,
            selection: $selection
        ) { option, _ in
            PaceFireTile(style: option.id, theme: theme)
        }
    }
}

struct ContentEntranceChooser: View {
    @Binding var selection: String

    private static let options = [
        MotionOption(id: "top", label: "Slide from top", caption: "The accounts drop in together."),
        MotionOption(id: "bottom", label: "Slide from bottom", caption: "The accounts rise in together."),
        MotionOption(id: "fade", label: "Fade in", caption: "The accounts appear in place."),
        MotionOption(id: "rows", label: "Rows slide from right", caption: "One account after another."),
    ]

    var body: some View {
        MotionChooserScreen(
            title: "Content entrance",
            footer: "How the accounts arrive when the app opens; the faded rows behind each one show where they come from. Tap a row to see it. With Reduce Motion on, they arrive in place.",
            options: Self.options,
            selection: $selection
        ) { option, tick in
            EntranceTile(style: option.id, playTick: tick)
        }
    }
}

struct TitleFlourishChooser: View {
    @Binding var selection: String
    let theme: RowTheme

    private static let options = [
        MotionOption(id: "zoom", label: "Zoom bounce", caption: "Grows from a dot and overshoots."),
        MotionOption(id: "slam", label: "Stamp slam", caption: "Stamps down at a tilt."),
        MotionOption(id: "spin", label: "Spin up", caption: "Two turns on the way in."),
        MotionOption(id: "off", label: "Off", caption: "The title is simply there."),
    ]

    var body: some View {
        MotionChooserScreen(
            title: "Title flourish",
            footer: "How the Infinitus title lands, a beat after the bars have filled; the faded title behind each one shows where it starts. Tap a row to see it. With Reduce Motion on, it lands without the flourish.",
            options: Self.options,
            selection: $selection
        ) { option, tick in
            FlourishTile(style: option.id, theme: theme, playTick: tick)
        }
    }
}
