import Foundation

/// A phone this Mac has served (user 2026-09-09: "build a devices
/// list… support more than one phones"): the durable counterpart of
/// `MirrorClient`, which forgets everything at relaunch. One record per
/// install id; any number of phones may pair with the same token, and
/// every one that has fetched shows here until it is forgotten.
public struct PairedPhone: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var route: String
    public let firstSeen: Date
    public var lastSeen: Date

    public init(id: String, name: String, route: String, firstSeen: Date, lastSeen: Date) {
        self.id = id
        self.name = name
        self.route = route
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }

    public func isActive(now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastSeen) < MirrorClient.activeWindow
    }
}

public enum PairedPhones {
    /// A poll lands every few seconds; the list is written only when it
    /// says something new — a name or route change, or `lastSeen`
    /// moving on by at least this much.
    public static let persistEvery: TimeInterval = 60

    /// The list with `client` folded in, newest first, and whether the
    /// fold is worth persisting.
    public static func merge(_ client: MirrorClient, into list: [PairedPhone]) -> (list: [PairedPhone], changed: Bool) {
        var out = list
        let changed: Bool
        if let i = out.firstIndex(where: { $0.id == client.id }) {
            var phone = out[i]
            changed = phone.name != client.name || phone.route != client.route
                || client.lastSeen.timeIntervalSince(phone.lastSeen) >= persistEvery
            phone.name = client.name
            phone.route = client.route
            phone.lastSeen = client.lastSeen
            out.remove(at: i)
            out.insert(phone, at: 0)
        } else {
            out.insert(PairedPhone(id: client.id, name: client.name, route: client.route,
                                   firstSeen: client.lastSeen, lastSeen: client.lastSeen), at: 0)
            changed = true
        }
        return (out, changed)
    }

    public static func forget(id: String, in list: [PairedPhone]) -> [PairedPhone] {
        list.filter { $0.id != id }
    }

    /// What a phone holds on this Mac, from its push registrations:
    /// lock-screen cards (an update or push-to-start token of either
    /// kind) and alerts.
    public static func pushSummary(_ kinds: Set<ActivityPushRegistration.Kind>) -> String {
        let cards = !kinds.isDisjoint(with: [.working, .revival, .workingStart, .revivalStart])
        let alerts = kinds.contains(.alert)
        switch (cards, alerts) {
        case (true, true): return "lock-screen cards + alerts"
        case (true, false): return "lock-screen cards"
        case (false, true): return "alerts"
        case (false, false): return "no push tokens"
        }
    }
}
