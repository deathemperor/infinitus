import Foundation

/// `threadListV2.ts`: the phone's Home list — pinned and active cards in
/// saved order, a snoozed shelf, then a settled tail by recency.
public enum T3ThreadList {
    public static let settledInitialCount = 10
    public static let settledPageCount = 25
    public enum Variant: Sendable, Equatable { case card, slim }
    public enum Section: Sendable { case pinned, active }
    public struct ProjectRef: Sendable, Equatable, Hashable {
        public let environmentId: String, projectId: String
        public init(environmentId: String, projectId: String) { self.environmentId = environmentId; self.projectId = projectId }
        var key: String { "\(environmentId):\(projectId)" }
    }
    public struct Item: Sendable, Equatable, Identifiable {
        public let thread: T3Thread, variant: Variant, snoozed: Bool, pinned: Bool
        public fileprivate(set) var isLast: Bool
        public var id: String { thread.key }
    }
    public struct Layout: Sendable, Equatable {
        public let items: [Item], hiddenSettledCount: Int, snoozedCount: Int, snoozedShelfHeaderIndex: Int?
        public let settledCount: Int, settledShelfHeaderIndex: Int?, nextSnoozeWakeAt: Date?
    }
    public struct Input: Sendable {
        public var threads: [T3Thread]
        public var environmentId: String? = nil
        public var projectRefs: [ProjectRef]? = nil
        public var searchQuery = ""
        public var matchedThreadKeys: Set<String>? = nil
        public var settlementEnvironmentIds: Set<String>? = nil
        public var snoozeEnvironmentIds: Set<String>? = nil
        public var settledLimit: Int? = nil
        public var now: Date
        public var snoozedShelfExpanded = false
        public var settledShelfExpanded = true
        public var selectedThreadKey: String? = nil
        public var queuedThreadKeys: Set<String> = []
        public init(threads: [T3Thread], now: Date) { self.threads = threads; self.now = now }
    }

    public static func searchMatchKey(environmentId: String, threadId: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [environmentId, threadId], options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func stamp(_ d: Date?) -> Date { d ?? .distantPast }   // parseTimestampMs: malformed sinks to the epoch

    /// Canonical card section for Move up/down, independent of search or scope.
    public static func orderedSection(_ threads: [T3Thread], section: Section, now: Date,
                                      settlementEnvironmentIds: Set<String>? = nil, snoozeEnvironmentIds: Set<String>? = nil,
                                      queuedThreadKeys: Set<String> = []) -> [T3Thread] {
        let rows = threads.filter { t in
            if t.archivedAt != nil { return false }
            if settlementEnvironmentIds?.contains(t.environmentId) ?? true, t.settledOverride == .settled, !queuedThreadKeys.contains(t.key) { return false }
            if snoozeEnvironmentIds?.contains(t.environmentId) ?? true, T3ThreadSettled.effectiveSnoozed(t, now: now) { return false }
            return (t.pinnedAt != nil) == (section == .pinned)
        }
        return section == .pinned ? T3ThreadSort.sortPinned(rows) : T3ThreadSort.sortActive(rows)
    }

    public static func buildItems(_ input: Input) -> Layout {
        let now = input.now
        let query = input.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let projectKeys = input.projectRefs.map { Set($0.map(\.key)) }
        var pinned: [T3Thread] = [], active: [T3Thread] = [], settled: [T3Thread] = [], snoozed: [T3Thread] = []
        var nextWake: Date? = nil
        for t in input.threads {
            if let env = input.environmentId, t.environmentId != env { continue }
            if let projectKeys, !projectKeys.contains("\(t.environmentId):\(t.projectId)") { continue }
            if !query.isEmpty, !t.title.lowercased().contains(query),
               !(input.matchedThreadKeys?.contains(searchMatchKey(environmentId: t.environmentId, threadId: t.id)) ?? false) { continue }
            let supportsSettlement = input.settlementEnvironmentIds?.contains(t.environmentId) ?? true
            let supportsSnooze = input.snoozeEnvironmentIds?.contains(t.environmentId) ?? true
            if supportsSnooze, T3ThreadSettled.effectiveSnoozed(t, now: now) {
                snoozed.append(t)
                if let until = t.snoozedUntil, nextWake.map({ until < $0 }) ?? true { nextWake = until }
                continue
            }
            let queued = input.queuedThreadKeys.contains(t.key)
            if supportsSettlement, t.settledOverride == .settled, !queued { settled.append(t) }
            else if t.pinnedAt != nil { pinned.append(t) }
            else { active.append(t) }
        }
        let orderedActive = T3ThreadSort.sortActive(active)
        let orderedSnoozed = snoozed.sorted { stamp($0.snoozedUntil) < stamp($1.snoozedUntil) }
        let selected = input.selectedThreadKey
        let visibleSnoozed = input.snoozedShelfExpanded ? orderedSnoozed : orderedSnoozed.filter { $0.key == selected }
        let orderedSettled = settled.sorted { stamp(T3ThreadSort.settledTimestamp($0)) > stamp(T3ThreadSort.settledTimestamp($1)) }
        var paged = orderedSettled
        if let limit = input.settledLimit, orderedSettled.count > limit {
            paged = Array(orderedSettled.prefix(limit))
            if let sel = orderedSettled.dropFirst(limit).first(where: { $0.key == selected }) { paged.append(sel) }
        }
        let visibleSettled = input.settledShelfExpanded ? paged : paged.filter { $0.key == selected }

        var items: [Item] = []
        for t in T3ThreadSort.sortPinned(pinned) { items.append(Item(thread: t, variant: .card, snoozed: false, pinned: true, isLast: false)) }
        for t in orderedActive { items.append(Item(thread: t, variant: .card, snoozed: false, pinned: false, isLast: false)) }
        let snoozedHeader = orderedSnoozed.isEmpty ? nil : items.count
        for t in visibleSnoozed { items.append(Item(thread: t, variant: .slim, snoozed: true, pinned: false, isLast: false)) }
        let settledHeader = orderedSettled.isEmpty ? nil : items.count
        for t in visibleSettled { items.append(Item(thread: t, variant: .slim, snoozed: false, pinned: false, isLast: false)) }
        if !items.isEmpty { items[items.count - 1].isLast = true }
        return Layout(items: items, hiddenSettledCount: orderedSettled.count - paged.count, snoozedCount: orderedSnoozed.count,
                      snoozedShelfHeaderIndex: snoozedHeader, settledCount: orderedSettled.count, settledShelfHeaderIndex: settledHeader,
                      nextSnoozeWakeAt: nextWake)
    }

    public struct PendingTask: Sendable, Equatable {
        public let key: String, title: String
        public init(key: String, title: String) { self.key = key; self.title = title }
    }
    public enum ListItem: Sendable, Equatable, Identifiable {
        case thread(Item, snoozeWakeLabel: String?)
        case pending(PendingTask, showDivider: Bool)
        case snoozedShelf(count: Int, expanded: Bool)
        case settledShelf(count: Int, expanded: Bool)
        public var id: String {
            switch self {
            case let .thread(item, _): return "v2-thread:\(item.thread.key)"
            case let .pending(task, _): return "v2-\(task.key)"
            case .snoozedShelf: return "v2-snoozed-shelf"
            case .settledShelf: return "v2-settled-shelf"
            }
        }
    }

    /// Shared mobile order: active → pending → snoozed shelf → settled.
    public static func buildListItems(items: [Item], pendingTasks: [PendingTask], snoozedCount: Int = 0, snoozedShelfExpanded: Bool = false,
                                      snoozedShelfHeaderIndex: Int? = nil, settledCount: Int = 0, settledShelfExpanded: Bool = true,
                                      settledShelfHeaderIndex: Int? = nil, snoozeLabelNow: Date? = nil) -> [ListItem] {
        let threadItems: [ListItem] = items.map { item in
            var label: String? = nil
            if item.snoozed, let until = item.thread.snoozedUntil, let now = snoozeLabelNow {
                label = T3ThreadSettled.snoozeWakeLabel(until: until, now: now)
            }
            return .thread(item, snoozeWakeLabel: label)
        }
        let pendingItems: [ListItem] = pendingTasks.enumerated().map { .pending($1, showDivider: $0 == 0) }
        let activeEnd = snoozedShelfHeaderIndex ?? settledShelfHeaderIndex ?? threadItems.count
        let snoozedEnd = settledShelfHeaderIndex ?? threadItems.count
        var result = Array(threadItems[0..<activeEnd]) + pendingItems
        if let h = snoozedShelfHeaderIndex, snoozedCount > 0 {
            result.append(.snoozedShelf(count: snoozedCount, expanded: snoozedShelfExpanded))
            result += threadItems[h..<snoozedEnd]
        }
        if let h = settledShelfHeaderIndex, settledCount > 0 {
            result.append(.settledShelf(count: settledCount, expanded: settledShelfExpanded))
            result += threadItems[h...]
        }
        return result
    }

    public enum SwipeAction: Sendable, Equatable { case archive, settle, unsettle, snooze, unsnooze }
    public static func swipeActions(variant: Variant, settlementSupported: Bool, snoozeSupported: Bool, snoozable: Bool, snoozed: Bool = false)
        -> (primary: SwipeAction, secondary: SwipeAction?) {
        if snoozed { return (.unsnooze, nil) }
        let primary: SwipeAction = settlementSupported ? (variant == .slim ? .unsettle : .settle) : .archive
        return (primary, snoozeSupported && snoozable ? .snooze : nil)
    }
}
