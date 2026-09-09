import SwiftUI
import InfinitusCore
import InfinitusUI

/// The composer's `/` and `@` menu (`ComposerCommandMenu.tsx:62-195`): the
/// rows a trigger opened, one label with its description, the highlighted row
/// in `accent`, ⏎ picking it.
///
/// Upstream draws it in a `ComposerBanner.Surface` attached above the composer
/// (`:92-96`) and portals it through `ComposerCommandMenuLayer`
/// (`ChatComposer.tsx:5046-5059`); this is a plain overlay on the composer card
/// in the `popover` tokens — the drawer surface (`T3BannerRoot`) is private to
/// the pending panels and a menu is not one of that file's banners.
///
/// The rows carry no glyph for a command (upstream gives one only to a `path`
/// item, `:165-171`) and the vendored Lucide set has neither `slash` nor
/// `at-sign` (Lucide.generated.swift) — nothing here needs either, so no SF
/// Symbol stands in for them; a file row gets `file`, the nearest vendored
/// glyph to upstream's `PierreEntryIcon`.

/// The open menu's measured height, so the composer can lift it clear of the
/// card (the same mechanism `T3ComposerHeightKey` uses one level up).
struct T3ComposerMenuHeightKey: PreferenceKey {
    static let defaultValue: Double = 0
    static func reduce(value: inout Double, nextValue: () -> Double) { value = max(value, nextValue()) }
}

struct T3ComposerMenuItem: Identifiable, Equatable {
    /// `path:<path>` / a `SlashCommand`'s own id — the identity the highlight
    /// is tracked by (`composerMenuHighlight.ts`).
    let id: String
    let label: String
    let description: String
    let icon: Lucide?
}

struct T3ComposerMenu: View {
    let items: [T3ComposerMenuItem]
    /// `activeItemId` (`ComposerCommandMenu.tsx:68`).
    let activeID: String?
    /// `:114-126`'s copy for the state the menu is in.
    let emptyText: String
    let onHighlight: (String) -> Void
    let onPick: (T3ComposerMenuItem) -> Void
    @Environment(\.t3) private var t3

    /// `CommandItem` `px-3 py-2` on a `text-xs` line over a 14 pt icon
    /// (`:152`, `:172`): every row is one line, so the height is fixed and the
    /// list needs no measurement pass.
    private static let rowHeight: Double = 32
    /// `CommandList` `max-h-72` (`:98`) and its `not-empty:p-2`
    /// (`ui/command.tsx:131`).
    private static let maxListHeight: Double = 288
    private static let listPadding: Double = 8

    var body: some View {
        Group {
            if items.isEmpty { empty } else { list }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            shape
                .fill(t3.web.popover.color)
                .overlay(shape.stroke(t3.web.border.color, lineWidth: 1))
        }
        .foregroundStyle(t3.web.popoverForeground.color)
        // The drawer sits on the card (`ComposerBanner.Surface` is attached);
        // this one floats, so it keeps the banner stack's own 4 pt gap.
        .padding(.bottom, 4)
        // How far the composer must lift it to clear the card: an overlay
        // cannot be pushed above its container by an alignment guide alone.
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: T3ComposerMenuHeightKey.self, value: geometry.size.height)
            }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { row($0) }
                }
                // `not-empty:p-2` is on the scrolling element itself
                // (`ui/command.tsx:131`), so it insets the rows INSIDE the box
                // `max-h-72` caps — it is not a margin around it.
                .padding(Self.listPadding)
            }
            .frame(height: min(Self.maxListHeight,
                               Double(items.count) * Self.rowHeight + Self.listPadding * 2))
            .scrollBounceBehavior(.basedOnSize)
            // `scrollIntoView({ block: "nearest" })` (`:74-80`) — `anchor: nil`
            // is SwiftUI's "nearest": it scrolls the least that shows the row.
            .onChange(of: activeID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: nil)
            }
        }
    }

    private func row(_ item: T3ComposerMenuItem) -> some View {
        let active = item.id == activeID
        return HStack(spacing: 12) {   // `gap-3`
            if let icon = item.icon {
                LucideIcon(icon, size: 14)
                    .foregroundStyle(active ? t3.web.accentForeground.color : t3.web.mutedForeground.color)
            }
            // `max-w-[45%] shrink-0 truncate font-sans text-xs font-medium`
            // (`:173`): a fixed fraction is not a SwiftUI layout, so the label
            // simply wins the space it needs and the description yields.
            Text(item.label)
                .font(T3Font.web(.xs, .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            // `flex-1 truncate text-left text-secondary-label text-xs` (`:183`).
            Text(item.description)
                .font(T3Font.web(.xs))
                .foregroundStyle(active ? t3.web.accentForeground.color : t3.web.secondaryLabel.color)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)   // `px-3`
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // `data-active` (`:153`): `bg-accent! text-accent-foreground!`.
        .foregroundStyle(active ? t3.web.accentForeground.color : t3.web.popoverForeground.color)
        .background(active ? t3.web.accent.color : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))   // `rounded-lg`
        .contentShape(Rectangle())
        // `onMouseMove` highlights the row under the pointer (`:155-157`).
        .onHover { inside in if inside, !active { onHighlight(item.id) } }
        .onTapGesture { onPick(item) }
        .id(item.id)
    }

    /// `:113-127`: `px-5 pt-3.5 pb-7`, `text-secondary-label text-xs`.
    private var empty: some View {
        Text(emptyText)
            .font(T3Font.web(.xs))
            .foregroundStyle(t3.web.secondaryLabel.color)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 28)
    }
}

#Preview("Command menu") {
    T3ComposerMenu(items: [
        .init(id: "user:review", label: "/review", description: "Review the working tree", icon: nil),
        .init(id: "project:ship", label: "/ship", description: "Open a pull request and merge it", icon: nil),
    ], activeID: "user:review", emptyText: "No matching command.", onHighlight: { _ in }, onPick: { _ in })
    .frame(width: 520)
    .padding()
}

#Preview("File menu") {
    T3ComposerMenu(items: [
        .init(id: "path:Sources/Infinitus/T3Window/T3ComposerView.swift",
              label: "T3ComposerView.swift", description: "Sources/Infinitus/T3Window", icon: .file),
        .init(id: "path:README.md", label: "README.md", description: "", icon: .file),
    ], activeID: "path:README.md", emptyText: "No matching files or folders.",
       onHighlight: { _ in }, onPick: { _ in })
    .frame(width: 520)
    .padding()
}
