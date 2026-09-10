import Foundation

/// Port of T3 Code's timeline minimap logic
/// (`MessagesTimeline.logic.ts:34-38`, `:171-275`, plus
/// `deriveTimelineMinimapItems`/`resolveFinalAssistantTextForTurn`/
/// `compactMinimapPreview` from `MessagesTimeline.tsx:929-971`), written in the
/// upstream order so the two files diff side by side. Foundation only — every
/// geometry answer is a number the view applies.
///
/// The two CSS-string results are ported as points: upstream's
/// `min(<natural>px, calc(100vh - 18rem))` height becomes
/// `naturalStripHeight` + `stripHeight(itemCount:availableHeight:)`, and
/// `resolveTimelineMinimapInteractiveWidth`'s `"22rem"` becomes 352.
public enum T3TimelineMinimap {
    /// `TIMELINE_MINIMAP_ITEM_SPACING` (`:34`).
    static let itemSpacing: Double = 8
    /// `TIMELINE_MINIMAP_MIN_ITEMS` (`:35`): below two turns there is nothing
    /// to navigate, so the strip does not render at all.
    public static let minItems = 2
    /// `TIMELINE_MINIMAP_MAX_HEIGHT_CSS`'s `18rem` (`:36`). Upstream measures
    /// its cap against `100vh` — the whole window; the caller here passes the
    /// timeline viewport, which is shorter by the top bar.
    static let maxHeightInset: Double = 288
    /// `TIMELINE_CONTENT_MAX_WIDTH` (`:37`), the rows' own `max-w-3xl`.
    static let contentMaxWidth: Double = 768
    /// `TIMELINE_MINIMAP_PERSISTENT_GUTTER` (`:38`).
    static let persistentGutter: Double = 48
    /// `TIMELINE_MINIMAP_HIT_STRIP_LEFT` (`:238`), the strip's `left-3`.
    static let hitStripLeft: Double = 12
    /// `TIMELINE_MINIMAP_HIT_STRIP_MAX_WIDTH` (`:239`).
    static let hitStripMaxWidth: Double = 40
    /// `TIMELINE_MINIMAP_EXPANDED_HIT_STRIP_WIDTH` (`:240`), `22rem`.
    static let expandedHitStripWidth: Double = 352

    /// `TimelineMinimapItem` (`MessagesTimeline.tsx:914-919`): one mark per user
    /// turn, carrying the turn's own text and its final answer for the preview.
    public struct Item: Sendable, Equatable, Hashable, Identifiable {
        public var id: String
        public var rowIndex: Int
        public var userText: String?
        public var assistantText: String?

        public init(id: String, rowIndex: Int, userText: String?, assistantText: String?) {
            self.id = id; self.rowIndex = rowIndex
            self.userText = userText; self.assistantText = assistantText
        }
    }

    /// One entry of `resolveTimelineMinimapCurrentIndex`'s `itemBounds`
    /// (`:200-206`). `nil` `top` is upstream's unmeasured row.
    public struct ItemBounds: Sendable, Equatable {
        public var top: Double?
        public var height: Double?

        public init(top: Double?, height: Double?) {
            self.top = top; self.height = height
        }
    }

    /// `deriveTimelineMinimapItems` (`MessagesTimeline.tsx:929-946`).
    public static func items(rows: [T3TimelineRows.Row]) -> [Item] {
        var items: [Item] = []
        for (index, row) in rows.enumerated() {
            guard case let .message(id, _, message, _, _, _, _, _, _) = row, message.role == .user else {
                continue
            }
            items.append(Item(id: id, rowIndex: index,
                              userText: compactPreview(message.text),
                              assistantText: compactPreview(finalAssistantText(rows: rows, userRowIndex: index))))
        }
        return items
    }

    /// `resolveFinalAssistantTextForTurn` (`:948-967`): the LAST assistant
    /// message before the next user turn — the answer, not its commentary.
    static func finalAssistantText(rows: [T3TimelineRows.Row], userRowIndex: Int) -> String? {
        var finalText: String?
        var index = userRowIndex + 1
        while index < rows.count {
            defer { index += 1 }
            // Only `message` rows: an `assistant-meta` row repeats the same
            // message and the work rows between carry no answer text.
            guard case let .message(_, _, message, _, _, _, _, _, _) = rows[index] else { continue }
            if message.role == .user { break }
            if message.role == .assistant { finalText = message.text }
        }
        return finalText
    }

    /// `compactMinimapPreview` (`:969-972`): whitespace collapsed, empty → nil.
    static func compactPreview(_ text: String?) -> String? {
        let compact = (text ?? "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return compact.isEmpty ? nil : compact
    }

    /// `resolveTimelineMinimapHeightStyle`'s natural height (`:171-174`).
    public static func naturalStripHeight(itemCount: Int) -> Double {
        max(1, Double(itemCount - 1) * itemSpacing)
    }

    /// The same `min(…)` the CSS resolves at layout time (`:173`), against the
    /// height the strip is allowed to occupy.
    public static func stripHeight(itemCount: Int, availableHeight: Double) -> Double {
        min(naturalStripHeight(itemCount: itemCount), availableHeight - maxHeightInset)
    }

    /// `resolveTimelineMinimapTopPercent` (`:176-181`).
    public static func topPercent(index: Int, itemCount: Int) -> Double {
        guard itemCount > 1 else { return 0 }
        return Double(max(0, min(index, itemCount - 1))) / Double(itemCount - 1) * 100
    }

    /// `resolveTimelineMinimapIndexFromPointer` (`:183-198`).
    public static func indexFromPointer(itemCount: Int, railTop: Double, railHeight: Double,
                                        pointerY: Double) -> Int? {
        guard itemCount > 0, railHeight > 0 else { return nil }
        guard itemCount > 1 else { return 0 }
        let progress = max(0, min(1, (pointerY - railTop) / railHeight))
        return max(0, min(itemCount - 1, Int((progress * Double(itemCount - 1)).rounded())))
    }

    /// `resolveTimelineMinimapCurrentIndex` (`:200-226`): the first turn whose
    /// row is on screen, else the last one above it.
    public static func currentIndex(scrollTop: Double, scrollBottom: Double,
                                    itemBounds: [ItemBounds]) -> Int? {
        var precedingIndex: Int?
        for (index, item) in itemBounds.enumerated() {
            guard let top = item.top else { continue }
            let inView = top < scrollBottom && top + max(1, item.height ?? 1) > scrollTop
            if inView {
                // The first visible marker is the turn at the reader's current position.
                return index
            }
            if top <= scrollTop { precedingIndex = index }
        }
        return precedingIndex
    }

    /// `resolveTimelineMinimapHasPersistentGutter` (`:228-236`): a wide enough
    /// gutter keeps the strip visible instead of revealing it on hover.
    public static func hasPersistentGutter(viewportWidth: Double) -> Bool {
        guard viewportWidth.isFinite, viewportWidth > 0 else { return false }
        return sideGutter(viewportWidth: viewportWidth) >= persistentGutter
    }

    /// `resolveTimelineMinimapHitStripWidth` (`:241-266`): the strip is
    /// width-capped to the gutter so it never overlays the centred content
    /// column and swallows its clicks; 0 disables the strip.
    public static func hitStripWidth(viewportWidth: Double) -> Double {
        guard viewportWidth.isFinite, viewportWidth > 0 else { return 0 }
        return max(0, min(hitStripMaxWidth, sideGutter(viewportWidth: viewportWidth).rounded(.down) - hitStripLeft))
    }

    /// `resolveTimelineMinimapInteractiveWidth` (`:268-275`): once the preview
    /// is open, the strip widens to keep the preview and the space leading to
    /// it interactive.
    public static func interactiveWidth(collapsedWidth: Double, expanded: Bool) -> Double {
        expanded ? expandedHitStripWidth : collapsedWidth
    }

    private static func sideGutter(viewportWidth: Double) -> Double {
        let contentWidth = min(viewportWidth, contentMaxWidth)
        return max(0, (viewportWidth - contentWidth) / 2)
    }
}
