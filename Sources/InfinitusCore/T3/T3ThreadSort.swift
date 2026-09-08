import Foundation

/// `threadSort.ts`: fractional order keys over the alphabet `a–z` and the
/// sorts every T3 list shares.
public enum T3ThreadSort {
    public struct Assignment: Sendable, Equatable {
        public let id: String, orderKey: String
        public init(id: String, orderKey: String) { self.id = id; self.orderKey = orderKey }
    }
    public enum Direction: Sendable { case up, down }
    public enum SortOrder: String, Sendable { case createdAt = "created_at", updatedAt = "updated_at" }

    static let digits = Array("abcdefghijklmnopqrstuvwxyz")

    static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { digits.contains($0) } && key.last != digits[0]
    }

    /// Midpoint of two digit strings read as fractions in (0, 1); "" is the open bound.
    static func midpoint(_ a: String, _ b: String) -> String {
        if !b.isEmpty {
            var n = 0
            let ac = Array(a), bc = Array(b)
            while n < bc.count, (n < ac.count ? ac[n] : digits[0]) == bc[n] { n += 1 }
            if n > 0 { return String(bc[0..<n]) + midpoint(String(ac.dropFirst(n)), String(bc.dropFirst(n))) }
        }
        let da = a.isEmpty ? 0 : digits.firstIndex(of: a.first!)!
        let db = b.isEmpty ? digits.count : digits.firstIndex(of: b.first!)!
        if db - da > 1 { return String(digits[Int((Double(da + db) / 2).rounded())]) }
        if b.count > 1 { return String(b.first!) }
        return String(digits[da]) + midpoint(String(a.dropFirst()), "")
    }

    public static func pinOrderKeyBetween(_ before: String?, _ after: String?) -> String? {
        let a = before ?? "", b = after ?? ""
        if !a.isEmpty, !isValidKey(a) { return nil }
        if !b.isEmpty, !isValidKey(b) { return nil }
        if !b.isEmpty, a >= b { return nil }
        return midpoint(a, b)
    }

    public static func spreadPinOrderKeys(count: Int) -> [String] {
        var width = 2, space = digits.count * digits.count
        while space <= (count + 1) * 2 { width += 1; space *= digits.count }
        let step = Double(space) / Double(count + 1)
        return (0..<count).map { i in
            var value = Int((step * Double(i + 1)).rounded())
            if value % digits.count == 0 { value += 1 }
            var key = ""
            for _ in 0..<width { key = String(digits[value % digits.count]) + key; value /= digits.count }
            return key
        }
    }

    public static func planPinnedReorder(orderedIds: [String], keysById: [String: String?], movedId: String) -> [Assignment] {
        let visible = Set(orderedIds)
        let reserved = Set(keysById.compactMap { id, key in visible.contains(id) ? nil : key })
        guard let idx = orderedIds.firstIndex(of: movedId) else { return [] }
        let beforeId = idx > 0 ? orderedIds[idx - 1] : nil
        let afterId = idx < orderedIds.count - 1 ? orderedIds[idx + 1] : nil
        let beforeKey = beforeId.flatMap { keysById[$0] ?? nil }
        let afterKey = afterId.flatMap { keysById[$0] ?? nil }
        if beforeId == nil || beforeKey != nil, afterId == nil || afterKey != nil {
            var key = pinOrderKeyBetween(beforeKey, afterKey)
            while let k = key, reserved.contains(k) { key = pinOrderKeyBetween(k, afterKey) }
            if let key { return [Assignment(id: movedId, orderKey: key)] }
        }
        let keys = spreadPinOrderKeys(count: orderedIds.count + reserved.count).filter { !reserved.contains($0) }.prefix(orderedIds.count)
        return zip(orderedIds, keys).compactMap { id, key in (keysById[id] ?? nil) == key ? nil : Assignment(id: id, orderKey: key) }
    }

    public static func planPinnedMove(orderedIds: [String], keysById: [String: String?], movedId: String, direction: Direction) -> [Assignment]? {
        guard let from = orderedIds.firstIndex(of: movedId) else { return nil }
        let to = direction == .up ? from - 1 : from + 1
        guard to >= 0, to < orderedIds.count else { return nil }
        var order = orderedIds; order.remove(at: from); order.insert(movedId, at: to)
        return planPinnedReorder(orderedIds: order, keysById: keysById, movedId: movedId)
    }

    static func identity(_ l: T3Thread, _ r: T3Thread) -> Bool {
        l.id != r.id ? l.id < r.id : l.environmentId < r.environmentId
    }

    /// New and reopened threads lead; arranged threads follow their keys.
    public static func sortActive(_ threads: [T3Thread]) -> [T3Thread] {
        func anchor(_ t: T3Thread) -> Date { max(t.createdAt, t.unsettledAt ?? .distantPast) }
        return threads.sorted { l, r in
            switch (l.activeOrderKey, r.activeOrderKey) {
            case (nil, .some): return true
            case (.some, nil): return false
            case let (lk?, rk?): return lk != rk ? lk < rk : identity(l, r)
            case (nil, nil):
                let la = anchor(l), ra = anchor(r)
                return la != ra ? la > ra : identity(l, r)
            }
        }
    }

    /// Arranged keys first (id tiebreak), then keyless newest-created first.
    public static func sortPinned(_ threads: [T3Thread]) -> [T3Thread] {
        let keyed = threads.filter { $0.pinOrderKey != nil }.sorted { l, r in
            l.pinOrderKey! != r.pinOrderKey! ? l.pinOrderKey! < r.pinOrderKey! : identity(l, r)
        }
        let keyless = threads.filter { $0.pinOrderKey == nil }.sorted { l, r in
            l.createdAt != r.createdAt ? l.createdAt > r.createdAt : identity(l, r)
        }
        return keyed + keyless
    }

    /// settledAt when stamped, else the latest message or turn stamp, else updatedAt.
    public static func settledTimestamp(_ t: T3Thread) -> Date? {
        if let s = t.settledAt { return s }
        let latest = [t.latestUserMessageAt, t.latestTurn?.requestedAt, t.latestTurn?.startedAt, t.latestTurn?.completedAt].compactMap { $0 }.max()
        return latest ?? t.updatedAt
    }

    public static func sortThreads(_ threads: [T3Thread], by order: SortOrder) -> [T3Thread] {
        func stamp(_ t: T3Thread) -> Date { order == .createdAt ? t.createdAt : (t.latestUserMessageAt ?? t.updatedAt) }
        return threads.sorted { l, r in
            let ls = stamp(l), rs = stamp(r)
            return ls != rs ? ls > rs : l.id > r.id
        }
    }
}
