import SwiftUI
import InfinitusCore
import InfinitusUI

/// Every theme as a live row, the way the Mac's Themes pane and this
/// app's own chat-header picker already do it (critique [P0], iOS: the
/// old pushed picker was thirteen plain names, and the single preview
/// appeared only after committing). Tapping a row selects it — no Done,
/// no second step — and the current one scrolls into view on arrival.
struct ThemeChooserScreen: View {
    @Binding var selection: String
    let themes: [RowTheme]

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(themes) { theme in
                        Button {
                            selection = theme.id
                        } label: {
                            ThemePreviewRow(theme: theme, selected: theme.id == selection)
                        }
                        .buttonStyle(.plain)
                        .id(theme.id)
                        // Room for the tab-bar mock: the Form's default
                        // insets clip its outer two items.
                        .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                    }
                } footer: {
                    Text("Tap a theme to use it — the change is immediate, here and on every other tab.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Theme")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // A scrollTo inside onAppear lands before the list has
                // laid out and does nothing; one runloop later it works.
                let current = selection
                DispatchQueue.main.async {
                    proxy.scrollTo(current, anchor: .center)
                }
            }
        }
    }
}

/// What a theme looks like once it is on: the two window gauges with
/// its labels and colours, the spend and model line with its cash icon,
/// its word for a working session, a mock of the four tab-bar items it
/// renames, and two of the names it draws account aliases from.
struct ThemePreviewRow: View {
    let theme: RowTheme
    var selected = false
    @ScaledMetric(relativeTo: .caption) private var tabIcon = 15.0

    private static let tabs = ["sessions", "fleet", "team", "settings"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(theme.name)
                    .font(.headline)
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .imageScale(.large)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            HStack(spacing: 12) {
                gauge(label: theme.sessionLabel, color: theme.sessionColor,
                      remaining: 62, dividers: (1..<5).map { Double($0) * 20 })
                gauge(label: theme.weeklyLabel, color: theme.weeklyColor,
                      remaining: 38, dividers: (1..<7).map { Double($0) * 100 / 7 })
                Spacer(minLength: 0)
            }
            rateLine
            spendLine
            tabBar
            if let names = nameLine {
                Text(names)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // One announcement in the theme's own words, instead of nine
        // decorative fragments.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOverLabel)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The tokens/minute chip in the theme's own icon and unit (#218):
    /// "🔮 1.2k mana/min" under RPG, the plain bolt and "tokens/min"
    /// where the theme names neither.
    private var rateLine: some View {
        HStack(spacing: 4) {
            if let glyph = theme.rateGlyph {
                Text(PopupGlyph.text(glyph))
            } else {
                Image(systemName: "bolt.horizontal.fill").foregroundStyle(.yellow)
            }
            Text(Self.sampleRate.label(theme: theme))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .font(.caption)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    /// One rate for every row, so the previews differ only by theme.
    private static let sampleRate = TokenRate(perMinute: 1200, peakPerMinute: 1200)

    /// The credit and model cells the fleet rows draw, in miniature.
    private var spendLine: some View {
        HStack(spacing: 10) {
            Text(verbatim: "\(PopupGlyph.text(theme.cashIcon))1,131")
                .foregroundStyle(ThemeColor.resolve(theme.creditColor))
            Text(PopupGlyph.text(theme.scopedPrefix) + theme.modelName("Fable"))
                .foregroundStyle(ThemeColor.resolve(theme.scopedColor))
            Text(theme.sessionWord("busy"))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    /// The most visible thing a theme changes and the one the old picker
    /// never showed: the bottom bar's four names and icons.
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Self.tabs, id: \.self) { tab in
                VStack(spacing: 2) {
                    icon(theme.tabIcon(tab))
                    Text(theme.tabLabel(tab))
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(tab == "sessions" ? ThemeColor.flash(theme) : Color.secondary)
            }
        }
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private func icon(_ name: String) -> some View {
        if name.hasPrefix("sf:") {
            Image(systemName: String(name.dropFirst(3)))
                .font(.system(size: tabIcon))
        } else {
            Text(PopupGlyph.text(name))
                .font(.system(size: tabIcon))
        }
    }

    /// The pool "Randomize names" draws from — omitted for Off and for a
    /// custom theme with no pool of its own (those fall back to every
    /// built-in's, which is not this theme's fact to state).
    private var nameLine: String? {
        let names = theme.accountNames.prefix(2)
        guard names.count == 2 else { return nil }
        return "Names like: " + names.joined(separator: ", ")
    }

    private var voiceOverLabel: String {
        var parts = [theme.name,
                     "Gauges \(theme.sessionLabel) and \(theme.weeklyLabel)",
                     "A working session is “\(theme.sessionWord("busy"))”",
                     "Tabs " + Self.tabs.map(theme.tabLabel).joined(separator: ", ")]
        if theme.rateUnit != nil { parts.append("Rate " + Self.sampleRate.label(theme: theme)) }
        if let names = nameLine { parts.append(names) }
        return parts.joined(separator: ". ")
    }

    @ViewBuilder
    private func gauge(label: String, color: String, remaining: Double,
                       dividers: [Double]) -> some View {
        HStack(spacing: 3) {
            Text(PopupGlyph.text(label))
                .font(PopupFont.caption).bold()
                .foregroundStyle(ThemeColor.resolve(color))
            if theme.plain {
                Text("\(Int(100 - remaining))%")
                    .font(PopupFont.caption).monospacedDigit()
            } else {
                GaugeBar(remaining: remaining, color: ThemeColor.resolve(color),
                         dividers: dividers, animated: false)
            }
        }
    }
}
