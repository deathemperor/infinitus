import SwiftUI
import InfinitusCore
import InfinitusUI

/// `TimelineMinimap` (`MessagesTimeline.tsx:988-1211`): one mark per user turn
/// in the timeline's side gutter, a preview of the turn under the pointer, and
/// the previous/next-turn arrows above and below the strip.
///
/// Geometry is `T3TimelineMinimap`; this file is placement and paint only. The
/// strip lives at the timeline's LEFT edge because upstream's does (`:1064`,
/// `absolute inset-y-0 left-0` in a `w-18` box, the strip itself `left-3`
/// centred vertically), and it renders nothing below two turns
/// (`TIMELINE_MINIMAP_MIN_ITEMS`) — which is why a two-message thread shows no
/// strip at all.
///
/// Not ported: the strip button's own keyboard navigation (`:1105-1125`,
/// Arrow/Home/End/Enter on the focused strip — a focus-scoped handler, not a
/// shortcut; `.focusable()` here would put the strip in the window's tab loop
/// ahead of the composer), `[@media(pointer:fine)]` (`:1064`, always fine on a
/// Mac), and the preview's selectable text (`:1170`, `cursor-text select-text`
/// — the preview has to stay hit-transparent so moving onto it does not read as
/// leaving the strip).
struct T3TimelineMinimapStrip: View {
    /// The published `(currentIndex, inView)` pair, the only thing here that
    /// changes while the reader scrolls.
    @ObservedObject var anchors: T3Anchors
    let items: [T3TimelineMinimap.Item]
    /// The timeline viewport, `resolveTimelineMinimapHitStripWidth`'s and
    /// `…HeightStyle`'s inputs. (Upstream's height caps against `100vh`, the
    /// whole window; this is the viewport, shorter by the top bar.)
    let viewport: CGSize
    let onSelect: (T3TimelineMinimap.Item) -> Void

    @Environment(\.t3) private var t3
    /// `activeIndex` (`:1002`): the mark the pointer is on, which owns the
    /// preview and the marks' widths.
    @State private var activeIndex: Int?
    /// The container's reveal (`:1066-1068`): upstream gets it from CSS `:hover`
    /// on the pointer-events-none wrapper, which a hovered descendant still
    /// triggers. Here the descendants report it.
    @State private var hoverStrip = false
    @State private var hoverNav = false

    /// `w-18` (`:1064`).
    private static let gutterWidth: Double = 72
    /// The strip's `left-3` inside that box, and the rail's own `left-3`.
    private static let stripLeft: Double = 12
    /// `h-0.5` marks, `w-6`/`w-4`/`w-2.5`/`w-2` by distance from the pointer.
    private static let markHeight: Double = 2
    /// The preview's `left-8 w-80`.
    private static let previewLeft: Double = 32
    private static let previewWidth: Double = 320

    var body: some View {
        // `:1057-1059`.
        if items.count >= T3TimelineMinimap.minItems {
            strip
                .frame(width: Self.gutterWidth, alignment: .leading)
                .padding(.leading, Self.stripLeft)
                // `inset-y-0` + the strip's own `top-1/2 -translate-y-1/2`.
                .frame(maxHeight: .infinity)
        }
    }

    private var revealed: Bool {
        T3TimelineMinimap.hasPersistentGutter(viewportWidth: viewport.width) || hoverStrip || hoverNav
    }

    private var strip: some View {
        let count = items.count
        let hitWidth = T3TimelineMinimap.hitStripWidth(viewportWidth: viewport.width)
        let height = max(1, T3TimelineMinimap.stripHeight(itemCount: count, availableHeight: viewport.height))
        let active = activeIndex.flatMap { $0 >= 0 && $0 < count ? $0 : nil }
        let width = max(1, T3TimelineMinimap.interactiveWidth(collapsedWidth: hitWidth, expanded: active != nil))
        let current = anchors.minimap.currentIndex.flatMap { $0 >= 0 && $0 < count ? $0 : nil }
        return ZStack(alignment: .topLeading) {
            // `absolute top-0 left-3 h-full w-px bg-border/15` (`:1138`).
            Rectangle()
                .fill(t3.web.border.color.opacity(0.15))
                .frame(width: 1, height: height)
                .offset(x: Self.stripLeft)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, _ in
                mark(index: index, count: count, height: height, active: active)
            }
            if let active, let item = items[safe: active] {
                preview(item, index: active, count: count, height: height)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        // The strip is width-capped to the gutter, so with no usable gutter it
        // goes inert rather than swallowing the message column's clicks
        // (`:1071-1076`). The arrows stay live either way — they are
        // `pointer-events-auto` in a `pointer-events-none` box upstream, which
        // in SwiftUI means they cannot sit under this modifier.
        .contentShape(Rectangle())
        .allowsHitTesting(hitWidth > 0)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case let .active(point):
                hoverStrip = true
                // Past the collapsed strip the pointer is over the preview,
                // which upstream keeps open by stopping the move event
                // (`:1168`) — the same "leave the active mark alone" rule.
                guard point.x <= max(hitWidth, 1) else { return }
                activeIndex = T3TimelineMinimap.indexFromPointer(itemCount: count, railTop: 0,
                                                                 railHeight: height, pointerY: point.y)
            case .ended:
                hoverStrip = false
                activeIndex = nil   // `onMouseLeave` (`:1127`)
            }
        }
        // `onClick` (`:1096-1108`) re-resolves the mark from the pointer and
        // ignores a click that landed on the preview.
        .gesture(SpatialTapGesture(coordinateSpace: .local).onEnded { value in
            guard value.location.x <= max(hitWidth, 1) else { return }
            guard let index = T3TimelineMinimap.indexFromPointer(itemCount: count, railTop: 0,
                                                                railHeight: height, pointerY: value.location.y),
                  let item = items[safe: index] else { return }
            onSelect(item)
        })
        // `bottom-[calc(100%+2px)]` / `top-[calc(100%+2px)]`, `left-1` on a
        // `-translate-x-1/2` (`:1224-1227`): centred on x = 4, 2 pt clear of
        // the strip's ends.
        .overlay(alignment: .topLeading) {
            navButton(.previous, target: current.flatMap { items[safe: $0 - 1] })
                .offset(x: 4 - 10, y: -22)
        }
        .overlay(alignment: .bottomLeading) {
            navButton(.next, target: current.flatMap { items[safe: $0 + 1] })
                .offset(x: 4 - 10, y: 22)
        }
        // `opacity-0 transition-opacity duration-150 hover:opacity-100`
        // unless the gutter is wide enough to keep it out (`:1066-1068`).
        .opacity(revealed ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: revealed)
    }

    // MARK: - The marks

    private func mark(index: Int, count: Int, height: Double, active: Int?) -> some View {
        let distance = active.map { abs(index - $0) }
        let inView = anchors.minimap.inView.contains(index)
        let width: Double = distance == 0 ? 24 : distance == 1 ? 16 : distance == 2 ? 10 : 8
        // `data-[in-view=true]:bg-foreground/90` is an attribute selector, so it
        // outranks the hovered mark's own `bg-muted-foreground/75` (`:1145`).
        let color = inView
            ? t3.web.foreground.color.opacity(0.9)
            : t3.web.mutedForeground.color.opacity(distance == 0 ? 0.75 : 0.35)
        return Capsule()
            .fill(color)
            .frame(width: width, height: Self.markHeight)
            // `-translate-y-1/2` on a `top: <percent>` of the strip.
            .offset(y: T3TimelineMinimap.topPercent(index: index, itemCount: count) / 100 * height
                    - Self.markHeight / 2)
            // `transition-[background-color,width] duration-150`.
            .animation(.easeInOut(duration: 0.15), value: width)
            .animation(.easeInOut(duration: 0.15), value: inView)
    }

    // MARK: - The hovered turn's preview

    private func preview(_ item: T3TimelineMinimap.Item, index: Int, count: Int,
                         height: Double) -> some View {
        // `transform: translateY(-50% | 0% | -100%)` (`:1015-1021`): the card is
        // centred on its mark, except at the ends where it is pushed inward.
        // A zero-height anchor carries that exactly — no measured height, so no
        // first-frame jump.
        let alignment: Alignment = index == 0 ? .top : index == count - 1 ? .bottom : .center
        return Color.clear
            .frame(width: Self.previewWidth, height: 0)
            .overlay(alignment: alignment) {
                previewCard(item)
                    .frame(width: Self.previewWidth)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .offset(x: Self.previewLeft,
                    y: T3TimelineMinimap.topPercent(index: index, itemCount: count) / 100 * height)
            // Hit-transparent on purpose (see the type comment): the strip has
            // to keep receiving moves while the pointer is over the card.
            .allowsHitTesting(false)
    }

    private func previewCard(_ item: T3TimelineMinimap.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {   // `mt-1` on the answer
            // `text-sm font-medium`, one line with an ellipsis (`:1176`).
            Text(item.userText ?? "User message")
                .font(T3Font.web(.sm, .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if let assistantText = item.assistantText {
                // `WebkitLineClamp: 3` in `muted-foreground` (`:1180-1189`).
                Text(assistantText)
                    .font(T3Font.web(.sm))
                    .foregroundStyle(t3.web.mutedForeground.color)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)   // `p-3`
        .foregroundStyle(t3.web.popoverForeground.color)
        // `dropdown-glass` (index.css:331-339) is `--popover` behind a backdrop
        // blur; this window has no CABackdropLayer host, so a flat popover fill
        // with the same hairline (`T3ComposerMenu` makes the same call).
        .background {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)   // `rounded-xl`
            shape.fill(t3.web.popover.color)
                .overlay(shape.stroke(t3.web.border.color, lineWidth: 1))
        }
        // `shadow-xl shadow-black/25`.
        .shadow(color: .black.opacity(0.25), radius: 12, y: 8)
    }

    // MARK: - The previous/next-turn arrows

    /// `TimelineMinimapNavigationButton` (`:1213-1247`): an `icon-micro`
    /// `ghost-muted` button around a `size-4` chevron, itself hidden until
    /// hovered, disabled once there is no turn that way.
    private func navButton(_ direction: NavDirection,
                           target: T3TimelineMinimap.Item?) -> some View {
        T3Tooltip(direction.label) {
            T3MinimapNavButton(direction: direction, disabled: target == nil,
                               hover: $hoverNav) {
                if let target { onSelect(target) }
            }
        }
    }

    enum NavDirection {
        case previous, next
        var label: String { self == .previous ? "Previous turn" : "Next turn" }
        var icon: Lucide { self == .previous ? .chevronUp : .chevronDown }
    }
}

private struct T3MinimapNavButton: View {
    let direction: T3TimelineMinimapStrip.NavDirection
    let disabled: Bool
    @Binding var hover: Bool
    let action: () -> Void
    @Environment(\.t3) private var t3
    /// This button's own `opacity-0 … hover:opacity-100` (`:1226`), separate
    /// from the container's reveal.
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // `<Icon className="size-4 text-foreground/90" />` (`:1243`).
            LucideIcon(direction.icon, size: 16)
                .foregroundStyle(t3.web.foreground.color.opacity(0.9))
                // `size-5 rounded-sm`, `ghost-muted`'s `hover:bg-accent`.
                .frame(width: 20, height: 20)
                .background(hovering && !disabled ? t3.web.accent.color : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        // `disabled:opacity-64` under the button's own reveal.
        .opacity((hovering ? 1 : 0) * (disabled ? 0.64 : 1))
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .onHover { inside in
            hovering = inside
            hover = inside
        }
        .accessibilityLabel(direction.label)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
