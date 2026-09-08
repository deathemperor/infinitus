import Foundation

/// `Sidebar.logic.ts`: the Mac sidebar's sortable list, its drop rules and the small selectors around it.
public enum T3SidebarList {
    public enum Section: String, Sendable, Equatable { case pinned, active, snoozed, settled }
    public enum Marker: String, Sendable, Equatable {
        case pinnedHeader = "pinned-header", activePlaceholder = "active-placeholder", settledPlaceholder = "settled-placeholder"
        case pinnedDivider = "pinned-divider", snoozedHeader = "snoozed-header", settledHeader = "settled-header"
    }
    static let markerPrefix = "sidebar-marker-"
    public enum ListItem: Sendable, Equatable, Identifiable {
        case thread(key: String, section: Section)
        case marker(Marker)
        public var id: String {
            switch self { case let .thread(key, _): return key; case let .marker(m): return markerPrefix + m.rawValue }
        }
    }
    public struct DropTarget: Sendable, Equatable {
        public let section: Section, pinnedOrder: [String], activeOrder: [String]
        public init(section: Section, pinnedOrder: [String], activeOrder: [String]) { self.section = section; self.pinnedOrder = pinnedOrder; self.activeOrder = activeOrder }
    }

    static func section(at index: Int, in items: [ListItem]) -> Section {
        var s = Section.pinned
        for item in items.prefix(index) {
            guard case let .marker(m) = item else { continue }
            switch m { case .pinnedDivider: s = .active; case .snoozedHeader: s = .snoozed; case .settledHeader: s = .settled; default: break }
        }
        return s
    }

    public static func dropTarget(items: [ListItem], activeKey: String, overId: String) -> DropTarget? {
        guard let activeIndex = items.firstIndex(where: { $0.id == activeKey }), let overIndex = items.firstIndex(where: { $0.id == overId }),
              case .thread = items[activeIndex] else { return nil }
        var moved = items; let lifted = moved.remove(at: activeIndex); moved.insert(lifted, at: overIndex)
        let section = self.section(at: overIndex, in: moved)
        if section == .snoozed { return nil }
        var pinned: [String] = [], active: [String] = [], current = Section.pinned
        loop: for item in moved {
            switch item {
            case .marker(.pinnedDivider): current = .active
            case .marker(.snoozedHeader), .marker(.settledHeader): break loop
            case .marker: continue
            case let .thread(key, _): if current == .pinned { pinned.append(key) } else { active.append(key) }
            }
        }
        return DropTarget(section: section, pinnedOrder: pinned, activeOrder: active)
    }

    public enum DropVerb: String, Sendable { case pin, unpin, settle, unsettle, wake }
    public static func dropVerb(from: Section, to: Section?) -> DropVerb? {
        guard let to, to != from, to != .snoozed else { return nil }
        if to == .pinned { return .pin }
        if to == .settled { return .settle }
        if from == .pinned { return .unpin }
        if from == .settled { return .unsettle }
        return .wake
    }

    public enum DropPlan: Sendable, Equatable {
        case none
        case reorderPinned(order: [String], assignments: [T3ThreadSort.Assignment])
        case pin(order: [String], orderKey: String?, extraAssignments: [T3ThreadSort.Assignment])
        case moveActive(order: [String], assignments: [T3ThreadSort.Assignment], unpin: Bool, unsettle: Bool, unsnooze: Bool)
        case settle
    }
    public struct DropInput: Sendable {
        public var activeKey: String, activeSection: Section
        public var activePinned: Bool? = nil, activeSettled: Bool? = nil, supportsSettlement = true
        public var target: DropTarget
        public var pinnedOrder: [String], pinnedKeysById: [String: String?], reorderableKeys: Set<String>? = nil
        public var activeOrder: [String], activeKeysById: [String: String?], activeReorderableKeys: Set<String>? = nil
        public init(activeKey: String, activeSection: Section, target: DropTarget, pinnedOrder: [String], pinnedKeysById: [String: String?],
                    activeOrder: [String], activeKeysById: [String: String?]) {
            self.activeKey = activeKey; self.activeSection = activeSection; self.target = target
            self.pinnedOrder = pinnedOrder; self.pinnedKeysById = pinnedKeysById; self.activeOrder = activeOrder; self.activeKeysById = activeKeysById
        }
    }

    public static func planDrop(_ i: DropInput) -> DropPlan {
        let activePinned = i.activePinned ?? (i.activeSection == .pinned)
        let activeSettled = i.activeSettled ?? (i.activeSection == .settled)
        if !i.supportsSettlement, i.target.section == .settled || activeSettled { return .none }
        switch i.target.section {
        case .active:
            let order = i.target.activeOrder
            if i.activeSection == .active, order == i.activeOrder { return .none }
            let a = T3ThreadSort.planPinnedReorder(orderedIds: order, keysById: i.activeKeysById, movedId: i.activeKey)
            if let ok = i.activeReorderableKeys, a.contains(where: { !ok.contains($0.id) }) { return .none }
            return .moveActive(order: order, assignments: a, unpin: activePinned, unsettle: activeSettled, unsnooze: i.activeSection == .snoozed)
        case .settled:
            return i.activeSection == .settled ? .none : .settle
        case .pinned:
            let order = i.target.pinnedOrder
            if i.activeSection == .pinned, order == i.pinnedOrder { return .none }
            let a = T3ThreadSort.planPinnedReorder(orderedIds: order, keysById: i.pinnedKeysById, movedId: i.activeKey)
            if let ok = i.reorderableKeys, a.contains(where: { !ok.contains($0.id) }) { return .none }
            if i.activeSection == .pinned { return a.isEmpty ? .none : .reorderPinned(order: order, assignments: a) }
            return .pin(order: order, orderKey: a.first { $0.id == i.activeKey }?.orderKey,
                        extraAssignments: activePinned ? a : a.filter { $0.id != i.activeKey })
        case .snoozed:
            return .none
        }
    }

    /// Project a drop's lifecycle fields before sorting its destination.
    public static func applyDrop(_ thread: T3Thread, section: Section, now: Date, orderKey: String? = nil) -> T3Thread {
        var t = thread
        let wasSettled = t.settledOverride == .settled
        t.snoozedAt = nil; t.snoozedUntil = nil
        if section == .settled {
            t.pinnedAt = nil; t.pinOrderKey = nil; t.activeOrderKey = nil
            t.settledOverride = .settled; t.settledAt = wasSettled ? (thread.settledAt ?? now) : now; t.unsettledAt = nil
            return t
        }
        if wasSettled { t.settledOverride = .active; t.settledAt = nil; t.unsettledAt = now }
        t.pinnedAt = section == .pinned ? (thread.pinnedAt ?? now) : nil
        t.pinOrderKey = section == .pinned ? (orderKey ?? thread.pinOrderKey) : nil
        if section == .active, let orderKey { t.activeOrderKey = orderKey }
        return t
    }

    public static func hasUnseenCompletion(_ t: T3Thread) -> Bool {
        guard let completedAt = t.latestTurn?.completedAt, let visited = t.lastVisitedAt else { return false }
        return completedAt > visited
    }

    public enum Traversal: Sendable { case previous, next }
    public static func adjacentThreadId<T: Equatable>(_ ids: [T], current: T?, direction: Traversal) -> T? {
        guard !ids.isEmpty else { return nil }
        guard let current else { return direction == .previous ? ids.last : ids.first }
        guard let i = ids.firstIndex(of: current) else { return nil }
        if direction == .previous { return i > 0 ? ids[i - 1] : nil }
        return i < ids.count - 1 ? ids[i + 1] : nil
    }

    public static func orderByPreferredIds<Item, ID: Hashable>(_ items: [Item], preferred: [ID], id: (Item) -> ID, preferenceIds: ((Item) -> [ID])? = nil) -> [Item] {
        if preferred.isEmpty { return items }
        var indexes: [ID: [Int]] = [:]
        for (i, item) in items.enumerated() {
            for p in Set(preferenceIds?(item) ?? [id(item)]) { indexes[p, default: []].append(i) }
        }
        var emitted = Set<Int>(), ordered: [Item] = []
        for p in preferred {
            guard let i = indexes[p]?.first(where: { !emitted.contains($0) }) else { continue }
            emitted.insert(i); ordered.append(items[i])
        }
        return ordered + items.enumerated().filter { !emitted.contains($0.offset) }.map(\.element)
    }

    /// Visible rows prewarmed into the detail cache; each holds a live subscription, so keep it small.
    public static func threadIdsToPrewarm<ID>(_ visible: [ID], limit: Int = 3) -> [ID] { Array(visible.prefix(max(0, limit))) }

    public enum RowBackground: Sendable, Equatable { case active, selected, none }
    public enum RowForeground: Sendable, Equatable { case foreground, muted }
    public struct RowStyle: Sendable, Equatable {
        public let background: RowBackground, foreground: RowForeground, medium: Bool
        public init(background: RowBackground, foreground: RowForeground, medium: Bool) { self.background = background; self.foreground = foreground; self.medium = medium }
    }
    /// `resolveThreadRowClassName` as tokens: `bg-sidebar-row-active … font-medium` for an active row, `bg-sidebar-row-selected` for a selected one, muted otherwise.
    public static func rowStyle(isActive: Bool, isSelected: Bool) -> RowStyle {
        if isActive { return RowStyle(background: .active, foreground: .foreground, medium: true) }
        if isSelected { return RowStyle(background: .selected, foreground: .foreground, medium: false) }
        return RowStyle(background: .none, foreground: .muted, medium: false)
    }

    /// `searchSidebarThreadsByTitle`: an empty (or whitespace-only) query matches nothing.
    public static func searchByTitle(_ threads: [T3Thread], query: String) -> [T3Thread] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return [] }
        return threads.filter { $0.title.lowercased().contains(q) }
    }
}
