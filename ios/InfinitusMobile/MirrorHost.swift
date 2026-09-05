import Foundation
import InfinitusCore

// MARK: - Multi-host pairing (windows plan 04-phone, W13)
//
// The phone used to know ONE machine: one token (`mirror_pair_token`),
// one route list (`mirror_manual_endpoints`), so scanning a Windows
// daemon's QR unpaired the Mac. A host record is everything that was
// global, scoped to one machine — a label and emoji for the merged
// sessions list, its own failover routes, and the token that host alone
// accepts.

/// One paired machine's record.
struct MirrorHost: Codable, Identifiable, Equatable, Hashable, Sendable {
    /// Minted once at pairing. Snapshots, fleets, feed calls and the
    /// sessions list all key off it — never off a pid or a name alone,
    /// since two machines can run the same pid.
    var id: String
    /// `snapshot.machineName` once the first snapshot named it, editable.
    var label: String
    /// User-picked; empty until the first snapshot (or the user) picks.
    var emoji: String
    /// This host's failover list — LAN, tailnet, tunnel — in pair order.
    var endpoints: [String]
    /// Normalised 24×base32. This host alone accepts it.
    var token: String
    /// The route that last answered, tried first next time.
    var lastGood: String?

    init(id: String = UUID().uuidString, label: String = "", emoji: String = "",
         endpoints: [String] = [], token: String = "", lastGood: String? = nil) {
        self.id = id
        self.label = label
        self.emoji = emoji
        self.endpoints = endpoints
        self.token = token
        self.lastGood = lastGood
    }

    /// Stored endpoints with the last-successful one moved to the front —
    /// the order candidates are tried in, so a host that answered last
    /// time answers first this time.
    var candidateEndpoints: [String] {
        var list = endpoints
        if let lastGood, let index = list.firstIndex(of: lastGood), index != 0 {
            list.remove(at: index)
            list.insert(lastGood, at: 0)
        }
        return list
    }

    /// Normalised on the way in; still run through here so a token typed
    /// with lowercase or dashes keeps matching.
    var normalizedToken: String { MirrorPairing.normalize(token) }

    /// The emoji a host starts with, from the shape of its first
    /// snapshot: a Windows daemon advertises a `claude-code-windows`
    /// engine, a cswap Mac is the 🍎 the phone has always mirrored,
    /// anything else gets the generic box.
    static func defaultEmoji(for snapshot: MirrorSnapshot) -> String {
        let engine = snapshot.fleets?.first?.engineID ?? ""
        if engine.hasPrefix("claude-code-windows") { return "🪟" }
        if engine.isEmpty || engine == MirrorFleetModel.cswapEngineID { return "🍎" }
        return "🖥️"
    }
}

/// A session's address once two hosts merge into one list — a pid
/// alone can't tell two machines' sessions apart.
typealias SessionKey = MobileSessionProgress.SessionKey

/// A session scoped to the host that owns it — feeds, inputs, and detail
/// screens route through this pair.
struct HostSession: Hashable, Identifiable {
    let host: MirrorHost
    let session: SessionDetail

    var id: SessionKey { SessionKey(hostID: host.id, pid: session.pid) }
    var pid: Int { session.pid }
}

/// `mirror_hosts` — where the host list lives and the pairing rules that
/// come with it. Everything reads it fresh per fetch (the transport's
/// old rule: a Settings edit takes effect at once), so there's no cache
/// to invalidate.
enum MirrorHostStore {
    static let key = "mirror_hosts"

    static func load(_ defaults: UserDefaults = .standard) -> [MirrorHost] {
        migrateIfNeeded(defaults)
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([MirrorHost].self, from: data)) ?? []
    }

    static func save(_ hosts: [MirrorHost], _ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        defaults.set(data, forKey: key)
    }

    /// Pairing a scanned QR or a typed address + token (windows plan
    /// README): the same token is the same machine and its routes are
    /// replaced, any other token is a NEW host appended to the list — a
    /// scan never unpairs another host. Label and emoji stay empty until
    /// the first snapshot names the machine.
    @discardableResult
    static func upsert(endpoints: [String], token: String,
                       _ defaults: UserDefaults = .standard) -> MirrorHost {
        var hosts = load(defaults)
        let token = MirrorPairing.normalize(token)
        if let index = hosts.firstIndex(where: { $0.normalizedToken == token }) {
            hosts[index].endpoints = endpoints
            save(hosts, defaults)
            return hosts[index]
        }
        let fresh = MirrorHost(endpoints: endpoints, token: token)
        hosts.append(fresh)
        save(hosts, defaults)
        return fresh
    }

    /// The transport's per-host writes (a new last-good endpoint, a
    /// swapped quick-tunnel URL) and Settings' edits all come through
    /// here: read, change, save — no cached copy to go stale.
    static func update(_ id: String, _ defaults: UserDefaults = .standard,
                       _ change: (inout MirrorHost) -> Void) {
        var hosts = load(defaults)
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        change(&hosts[index])
        save(hosts, defaults)
    }

    /// First launch after the multi-host update: the one Mac's token and
    /// route list become host #0, so nothing re-pairs. The legacy keys
    /// stay on disk for a rollback but are never read again — this only
    /// runs while `mirror_hosts` is absent.
    static func migrateIfNeeded(_ defaults: UserDefaults = .standard) {
        guard defaults.data(forKey: key) == nil else { return }
        let endpoints = NetworkFleetMirror.storedEndpoints(defaults)
        let token = MirrorPairing.normalize(
            defaults.string(forKey: NetworkFleetMirror.tokenKey) ?? "")
        guard !endpoints.isEmpty || !token.isEmpty else {
            save([], defaults)   // mark migrated: a later pair writes a host, not the dead key
            return
        }
        save([MirrorHost(label: "Mac", emoji: "🍎", endpoints: endpoints,
                         token: token,
                         lastGood: defaults.string(forKey: NetworkFleetMirror.lastGoodKey))],
             defaults)
    }

    // MARK: fixtures

    /// `INFINITUS_MIRROR_PATHS` (dev seam): colon- or newline-separated
    /// snapshot files, each standing in for a paired host — so a
    /// simulator shows two machines side by side with no daemon running.
    static func fixturePaths(_ spec: String) -> [String] {
        spec.split(whereSeparator: { $0 == ":" || $0.isNewline })
            .map(String.init).filter { !$0.isEmpty }
    }

    /// The fixture spec as host records, labelled and emoji'd from each
    /// snapshot. A file that won't decode is skipped — the model only
    /// shows hosts it can read.
    static func fixtureHosts(_ spec: String) -> [(host: MirrorHost, snapshot: MirrorSnapshot)] {
        var out: [(host: MirrorHost, snapshot: MirrorSnapshot)] = []
        for path in fixturePaths(spec) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let snapshot = try? decodeSnapshot(data) else { continue }
            out.append((MirrorHost(label: snapshot.machineName,
                                   emoji: MirrorHost.defaultEmoji(for: snapshot)), snapshot))
        }
        return out
    }

    static func decodeSnapshot(_ data: Data) throws -> MirrorSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MirrorSnapshot.self, from: data)
    }
}
