import Foundation

/// Spec §8.1: what this identity can read, folded per member into the
/// shapes the app already renders — `Stats.Day` per day (Stats v2 `+`),
/// the latest `now.json`, the session index, crash summaries, and the
/// transcript chunks a session has (decrypted on demand through
/// `transcript`, then `SessionFeedReader.parse` like a live session).
public struct TeamReader {
    public struct Member: Equatable {
        public var kid: String
        public var name: String
        /// "leader" | "member" | "removed" (pre-removal history still readable).
        public var role: String
        public var days: [String: Stats.Day] = [:]
        public var now: TeamDocs.Now?
        public var sessions: [TeamDocs.SessionRow] = []
        public var crashes: [String] = []
        public var fleet: TeamDocs.FleetDoc?
        /// `TeamPublisher.TranscriptSource.key` → chunk store paths in seq order.
        public var transcripts: [String: [String]] = [:]
        /// #220 store lane: command envelopes this sender wrote (store paths).
        public var commands: [String] = []
        /// #220 store lane: this sender's acks by command id.
        public var acks: [String: TeamControl.Ack] = [:]
        public var lastPublished: Int?
        public var kinds: Set<String> = []
        /// Roster approval (#219); nil for a removed sender.
        public var since: Int?
        /// When the roster removed this sender; nil while they are in it.
        public var removedAt: Int?
        public init(kid: String, name: String, role: String, since: Int? = nil, removedAt: Int? = nil) {
            self.kid = kid; self.name = name; self.role = role; self.since = since; self.removedAt = removedAt
        }
    }

    public private(set) var members: [String: Member] = [:]
    /// Leaders' `roster/aggregates/<period>.json`, keyed by period.
    public private(set) var aggregates: [String: TeamDocs.Aggregates] = [:]

    public init() {}

    /// Pure: `read` returns an envelope's plaintext (the client's `read`
    /// in practice). A document that fails to decode or carries a
    /// schema this build does not know is skipped. `unfetched` are the
    /// transcript chunks listed but not fetched (#414): they join a
    /// member's `transcripts` by path when that member's hint says the
    /// transcripts reach `me` — `read` still verifies every envelope.
    public static func fold(headers: [(entry: StoreEntry, header: Envelope.Header)], roster: TeamRoster,
                            unfetched: [StoreEntry] = [], me: String? = nil,
                            read: (String) throws -> Data) -> TeamReader {
        var reader = TeamReader()
        for m in roster.everyone {
            reader.members[m.keys.kid] = Member(kid: m.keys.kid, name: m.name, role: roster.isLeader(m.keys.kid) ? "leader" : "member", since: m.since)
        }
        func decode<T: Decodable>(_ type: T.Type, _ path: String) -> T? {
            guard let data = try? read(path) else { return nil }
            return try? CanonicalJSON.decode(type, from: data)
        }
        for (entry, header) in headers {
            if header.kind == TeamKinds.aggregates {
                // Leaders' documents only: a member can write under
                // roster/ with the store credential, so the sender is checked.
                guard roster.isLeader(header.from),
                      let doc = decode(TeamDocs.Aggregates.self, entry.path), doc.schema == 1 else { continue }
                reader.aggregates[doc.period] = doc
                continue
            }
            var member = reader.members[header.from]
                ?? Member(kid: header.from, name: header.from, role: "removed", removedAt: roster.removed.first { $0.kid == header.from }?.at)
            member.kinds.insert(header.kind)
            member.lastPublished = max(member.lastPublished ?? 0, header.at)
            switch header.kind {
            case TeamKinds.stats:
                // One file per day (spec §4.3): the file is the day, never a slice of it.
                if let doc = decode(TeamDocs.DayDoc.self, entry.path), doc.schema == 1 { member.days[doc.day] = doc.stats }
            case TeamKinds.now:
                if let doc = decode(TeamDocs.Now.self, entry.path), doc.schema == 1 { member.now = doc }
            case TeamKinds.sessions:
                if let doc = decode(TeamDocs.SessionsIndex.self, entry.path), doc.schema == 1 { member.sessions = doc.sessions }
            case TeamKinds.crashes:
                if let doc = decode(TeamDocs.Crashes.self, entry.path), doc.schema == 1 { member.crashes = doc.crashes }
            case TeamKinds.fleet:
                if let doc = decode(TeamDocs.FleetDoc.self, entry.path), doc.schema == 1 { member.fleet = doc }
            case TeamKinds.transcripts:
                if let key = Self.transcriptKey(entry.path) { member.transcripts[key, default: []].append(entry.path) }
            case TeamKinds.command:
                member.commands.append(entry.path)
            case TeamKinds.ack:
                if let doc = decode(TeamControl.Ack.self, entry.path), doc.schema == 1 { member.acks[doc.id] = doc }
            default:
                break
            }
            reader.members[header.from] = member
        }
        // A chunk whose bytes are not here has no header to scan; it is
        // listed all the same, so the session shows and can be opened —
        // `fetchTranscripts(from:session:)` then brings its chunks.
        if let me {
            for entry in unfetched {
                guard let (from, kind) = TeamKinds.expected(at: entry.path), kind == TeamKinds.transcripts,
                      let from, var member = reader.members[from], let key = Self.transcriptKey(entry.path),
                      roster.recipients(for: member.now?.sharesTo[TeamKinds.transcripts] ?? .leaders)
                          .contains(where: { $0.kid == me }) else { continue }
                member.transcripts[key, default: []].append(entry.path)
                reader.members[from] = member
            }
        }
        for kid in reader.members.keys {
            let transcripts = reader.members[kid]!.transcripts
            reader.members[kid]?.transcripts = transcripts.mapValues { paths in
                paths.sorted { Self.seq($0) < Self.seq($1) }
            }
        }
        return reader
    }

    /// Every command id someone acked, whoever the grantor was.
    public var ackIDs: Set<String> { Set(members.values.flatMap { $0.acks.keys }) }

    /// `m/<kid>/transcripts/<key…>/<seq>.jsonl` (or `t/`): the key.
    static func transcriptKey(_ path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 5 else { return nil }
        return parts[3..<(parts.count - 1)].joined(separator: "/")
    }

    static func seq(_ path: String) -> Int {
        Int(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent) ?? 0
    }

    /// Decrypted member docs by store path, remembered with the blob
    /// version they came from (#346): every loop pass re-read each
    /// member's stats, now, sessions, fleet and crash docs through one
    /// git subprocess per blob — some forty spawns, seconds of CPU, for
    /// bytes that only change when the blob's version does. Bounded to
    /// the paths of the current scan by `keep(only:)`.
    public final class DocCache: @unchecked Sendable {
        private let lock = NSLock()
        private var docs: [String: (version: String, data: Data)] = [:]
        public init() {}

        public func read(_ path: String, version: String, miss: () throws -> Data) rethrows -> Data {
            lock.lock()
            if let hit = docs[path], hit.version == version { lock.unlock(); return hit.data }
            lock.unlock()
            let data = try miss()
            lock.lock(); docs[path] = (version, data); lock.unlock()
            return data
        }

        public func keep(only paths: Set<String>) {
            lock.lock(); docs = docs.filter { paths.contains($0.key) }; lock.unlock()
        }

        public var count: Int { lock.lock(); defer { lock.unlock() }; return docs.count }
    }

    /// The last scan and fold, kept under the store fingerprint they came
    /// from (#499): a loop pass whose fetch brought nothing and whose
    /// publish pushed nothing listed every branch, checked every header
    /// and decoded every member's documents again — about a second of CPU
    /// every five minutes — for the same reader. In-memory state (the
    /// transcript choices, pending nearby requests) is folded over the
    /// reader by the caller on every pass, so it still shows on the next
    /// tick.
    public final class ScanCache: @unchecked Sendable {
        private let lock = NSLock()
        private var key: String?
        private var headers: [TeamClient.ReadableHeader] = []
        private var reader: TeamReader?
        private var count = 0
        public init() {}

        /// The cached scan when `fingerprint` is the one it was stored under.
        public func lookup(_ fingerprint: String) -> (headers: [TeamClient.ReadableHeader], reader: TeamReader?)? {
            lock.lock(); defer { lock.unlock() }
            guard key == fingerprint else { return nil }
            count += 1
            return (headers, reader)
        }

        public func store(_ fingerprint: String, headers: [TeamClient.ReadableHeader], reader: TeamReader?) {
            lock.lock(); key = fingerprint; self.headers = headers; self.reader = reader; lock.unlock()
        }

        /// How often `lookup` answered from the cache.
        public var hits: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// `client.readableHeaders()` and `load` over them, answered from
    /// `scans` while the store fingerprint holds. The fingerprint is read
    /// first: a ref that moves between it and the scan stores fresher data
    /// under the older key, and the next pass simply scans again.
    public static func scan(client: TeamClient, docs: DocCache, scans: ScanCache)
        -> (headers: [TeamClient.ReadableHeader], reader: TeamReader?) {
        guard client.roster != nil else { return ([], nil) }
        return scan(fingerprint: try? client.storeFingerprint(), scans: scans,
                    headers: { try client.readableHeaders() },
                    fold: { try load(client: client, headers: $0, cache: docs) })
    }

    /// The cache rule on its own: a pass is stored only when both the
    /// scan and the fold succeeded. A quiet team moves no ref for hours,
    /// so one transient git or decrypt failure cached under the
    /// fingerprint would show an empty roster until someone pushed.
    static func scan(fingerprint: String?, scans: ScanCache,
                     headers: () throws -> [TeamClient.ReadableHeader],
                     fold: ([TeamClient.ReadableHeader]) throws -> TeamReader)
        -> (headers: [TeamClient.ReadableHeader], reader: TeamReader?) {
        if let fingerprint, let hit = scans.lookup(fingerprint) { return hit }
        guard let headers = try? headers() else { return ([], nil) }
        let reader = try? fold(headers)
        if let fingerprint, let reader { scans.store(fingerprint, headers: headers, reader: reader) }
        return (headers, reader)
    }

    /// `headers`: a scan the caller already ran this tick (one per `load()`), else a fresh one.
    /// `cache`: decrypted docs reused while their blob version holds.
    public static func load(client: TeamClient, headers: [TeamClient.ReadableHeader]? = nil,
                            cache: DocCache? = nil) throws -> TeamReader {
        guard let roster = client.roster?.doc else { throw TeamClient.ClientError.noRoster }
        let scanned = try headers ?? client.readableHeaders()
        // Chunks a transcript fetch left out (#414): listed, not read.
        let unfetched = try client.store.list("t/").filter { !$0.present }
        let me = client.identity.kid
        guard let cache else { return fold(headers: scanned, roster: roster, unfetched: unfetched, me: me) { try client.read($0).1 } }
        let versions = Dictionary(scanned.map { ($0.entry.path, $0.entry.version) }, uniquingKeysWith: { a, _ in a })
        cache.keep(only: Set(versions.keys))
        return fold(headers: scanned, roster: roster, unfetched: unfetched, me: me) { path in
            try cache.read(path, version: versions[path] ?? "") { try client.read(path).1 }
        }
    }

    /// One member's period summary in the app's own shape (`Stats.fold`).
    public func summary(kid: String, period: Stats.Period, now: Date = Date(), calendar: Calendar = .current) -> Stats.Summary? {
        guard let member = members[kid] else { return nil }
        return Stats.fold(days: member.days, period: period, now: now, calendar: calendar)
    }

    /// Every member's days summed (Stats v2 `+`) — the team picture.
    public func teamDays() -> [String: Stats.Day] {
        var out: [String: Stats.Day] = [:]
        for member in members.values {
            for (key, day) in member.days { out[key] = (out[key] ?? Stats.Day()) + day }
        }
        return out
    }

    /// A member's session as chat items: every chunk of the session's own
    /// transcript in order, decrypted now, through the same parser the
    /// phone uses for live sessions. Sub-agent chunks are listed under
    /// `transcripts["<session>/subagents/<agent>"]` for a later view.
    public func transcript(kid: String, session: String, client: TeamClient, limit: Int = 200) throws -> [SessionFeedItem] {
        guard let paths = members[kid]?.transcripts[session], !paths.isEmpty else { return [] }
        var lines: [String] = []
        for path in paths {
            let text = String(decoding: try client.read(path).1, as: UTF8.self)
            lines += text.split(separator: "\n").map(String.init)
        }
        return SessionFeedReader.parse(lines: lines, limit: limit)
    }
}
