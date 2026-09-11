import Foundation

/// The phone's terminal (#507 spec F): frames, request/reply bodies and the
/// mirror routes for a PTY-backed shell, Foundation-only so the Linux tray
/// links this too. No host lives here yet — `TerminalHost` (forkpty,
/// `Sources/Infinitus`) and the routes that actually serve these come in
/// #507 step 3; this is the wire both ends agree on, reviewed in the issue.
///
/// Names and shapes are upstream's `packages/contracts/src/terminal.ts`
/// verbatim wherever #507's sketch and the review didn't rule otherwise —
/// see the doc comments below for every place they part ways.
///
/// **Sequence model** (this repo's own invention, not upstream's): `sequence`
/// on `output` and `snapshot` frames is the cumulative count of UTF-8 bytes
/// this terminal has ever emitted, as of the end of that frame's payload.
/// `since` on the stream route echoes the last `sequence` a client saw.
/// `ringStart`/`ringEnd` are the same counter's bounds for what the host's
/// 256 KB ring currently holds. `resumePlan` turns a `since` into either a
/// fresh `snapshot` (the ring no longer has that far back, or the value is
/// nonsense) or `.outputFrom(seq)` — replay ring bytes starting at `seq`,
/// no history resend needed.
public enum T3Terminal: Sendable {

    // MARK: - Caps (#507 review ruling; upstream's `terminal.ts` constants)

    /// `TerminalWriteInput`'s cap, measured in UTF-8 bytes (upstream caps
    /// UTF-16 code units at the same 65,536 number — bytes is what a POST
    /// body actually counts).
    public static let maxWriteBytes = 64 * 1024
    /// #507's table says cols 1…500; upstream's `TerminalColsSchema` allows
    /// up to 1000. Implementing #507 as briefed — flagged in the PR report.
    public static let minCols = 1
    public static let maxCols = 500
    /// #507's table says rows 1…200; upstream's `TerminalRowsSchema` allows
    /// up to 500. Implementing #507 as briefed — flagged in the PR report.
    public static let minRows = 1
    public static let maxRows = 200
    /// Upstream's `MAX_HISTORY_CHUNK_LENGTH`: the initial snapshot's history
    /// is cut into pieces no larger than this so one giant history frame
    /// never blocks the stream.
    public static let historyChunkLength = 16 * 1024
    /// The host's history ring size (#507 Mac side, step 3) — Core only
    /// needs the number for `resumePlan`'s math.
    public static let ringBytes = 256 * 1024
    /// Upstream's `DEFAULT_TERMINAL_ID` (`terminal.ts:10`) — "the client-side
    /// id for the FIRST shell opened on a thread; ids are uniformly `term-N`,
    /// there's no 'default' intrinsic". #507's table shows the literal
    /// `"default"`; using upstream's actual constant instead, per the
    /// brief's explicit instruction — flagged in the PR report.
    public static let defaultTerminalId = "term-1"
    /// `TerminalIdSchema`'s cap (`terminal.ts:19`: a trimmed non-empty string,
    /// max length 128). An id outside it is refused rather than keyed: an
    /// empty one would make a map entry no route could ever address (the
    /// path parser's `percentDecoded` returns nil for an empty component).
    public static let maxTerminalIdLength = 128
    /// How many terminals one session pid may hold at once. Upstream has NO
    /// per-thread cap: `MAX_TERMINALS_PER_GROUP = 4` (`apps/web/src/types.ts:30`,
    /// used at `ThreadTerminalDrawer.tsx:1233`) limits one SPLIT GROUP, and a
    /// thread may hold several groups; the server's only limit evicts already
    /// exited sessions (`Manager.ts:1957-1977`). 8 is this host's own number —
    /// a forkpty each, so the refusal is a real one, not bookkeeping.
    public static let maxTerminalsPerSession = 8
    /// The `closed` frame's `reason` when the host dropped the stream for
    /// backpressure (#507 review ruling 5) rather than the shell exiting —
    /// the phone matches this literal to know it may resume with `since`
    /// instead of treating the terminal as gone.
    public static let closedReasonBackpressure = "backpressure"

    // MARK: - Session status (upstream's `TerminalSessionStatus`)

    public enum SessionStatus: String, Codable, Sendable, Equatable {
        case starting, running, exited, error
    }

    // MARK: - Frame payloads (field names verbatim from `terminal.ts`)

    /// The stream's first frame(s): the history ring's contents so far.
    /// `status`/`exitCode`/`exitSignal` mirror upstream's
    /// `TerminalSessionSnapshot` (nullable there, optional here — same
    /// "may be absent" wire shape). Upstream nests this under a `snapshot`
    /// key inside its attach event and carries several more session fields
    /// (`threadId`, `cwd`, `label`, `updatedAt`, …); ours is flat and
    /// carries only what the phone's screen needs, ruled in review.
    public struct SnapshotPayload: Codable, Sendable, Equatable {
        public let history: String
        public let status: SessionStatus
        public let sequence: Int?
        public let exitCode: Int?
        public let exitSignal: Int?
        public init(history: String, status: SessionStatus, sequence: Int? = nil,
                    exitCode: Int? = nil, exitSignal: Int? = nil) {
            self.history = history; self.status = status; self.sequence = sequence
            self.exitCode = exitCode; self.exitSignal = exitSignal
        }
    }

    public struct OutputPayload: Codable, Sendable, Equatable {
        public let data: String
        public let sequence: Int
        public init(data: String, sequence: Int) {
            self.data = data; self.sequence = sequence
        }
    }

    public struct ExitedPayload: Codable, Sendable, Equatable {
        public let exitCode: Int?
        public let exitSignal: Int?
        public init(exitCode: Int?, exitSignal: Int?) {
            self.exitCode = exitCode; self.exitSignal = exitSignal
        }
    }

    /// `reason` is not in upstream's `terminal.ts` `TerminalClosedEvent` at
    /// all — the #507 review ruled it in (ruling 5: "log a closed frame
    /// reason so the phone can tell drop from exit"). Implementing the
    /// review, flagged in the PR report.
    public struct ClosedPayload: Codable, Sendable, Equatable {
        public let reason: String?
        public init(reason: String? = nil) {
            self.reason = reason
        }
    }

    public struct ErrorPayload: Codable, Sendable, Equatable {
        public let message: String
        public init(message: String) {
            self.message = message
        }
    }

    // MARK: - Frame (NDJSON: exactly one JSON object per line)

    /// One line of the stream. The wire is flat — `{"type":"output",
    /// "data":…,"sequence":n}`, never a nested payload object — so encoding
    /// writes the discriminator and the payload's own keys into the same
    /// JSON object, and decoding reads the payload from the same decoder
    /// once the discriminator says which shape to expect.
    public enum Frame: Codable, Sendable, Equatable {
        case snapshot(SnapshotPayload)
        case output(OutputPayload)
        case exited(ExitedPayload)
        case closed(ClosedPayload)
        case error(ErrorPayload)

        private enum Kind: String, Codable { case snapshot, output, exited, closed, error }
        private enum CodingKeys: String, CodingKey { case type }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .type) {
            case .snapshot: self = .snapshot(try SnapshotPayload(from: decoder))
            case .output: self = .output(try OutputPayload(from: decoder))
            case .exited: self = .exited(try ExitedPayload(from: decoder))
            case .closed: self = .closed(try ClosedPayload(from: decoder))
            case .error: self = .error(try ErrorPayload(from: decoder))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .snapshot(let payload):
                try container.encode(Kind.snapshot, forKey: .type)
                try payload.encode(to: encoder)
            case .output(let payload):
                try container.encode(Kind.output, forKey: .type)
                try payload.encode(to: encoder)
            case .exited(let payload):
                try container.encode(Kind.exited, forKey: .type)
                try payload.encode(to: encoder)
            case .closed(let payload):
                try container.encode(Kind.closed, forKey: .type)
                try payload.encode(to: encoder)
            case .error(let payload):
                try container.encode(Kind.error, forKey: .type)
                try payload.encode(to: encoder)
            }
        }

        /// One line of NDJSON: the frame's JSON object followed by `\n`.
        public func encodeLine(encoder: JSONEncoder = JSONEncoder()) throws -> Data {
            var data = try encoder.encode(self)
            data.append(0x0A)
            return data
        }

        /// A line that failed to decode as a `Frame` — the wire is between
        /// two builds this repo controls, so a bad non-empty line is a bug,
        /// not disk rot to shrug off.
        public struct DecodeError: Error, Sendable, Equatable {
            public let line: String
        }

        /// Splits accumulated bytes on `\n` into whole frames plus the
        /// unconsumed tail (a partial last line, no trailing newline yet).
        /// Empty lines are skipped; any other line that fails to decode
        /// throws rather than being dropped silently.
        public static func decodeLines(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> (frames: [Frame], tail: Data) {
            var frames: [Frame] = []
            var start = data.startIndex
            while let newline = data[start...].firstIndex(of: 0x0A) {
                let line = data[start..<newline]
                if !line.isEmpty {
                    do {
                        frames.append(try decoder.decode(Frame.self, from: Data(line)))
                    } catch {
                        throw DecodeError(line: String(decoding: line, as: UTF8.self))
                    }
                }
                start = data.index(after: newline)
            }
            return (frames, Data(data[start...]))
        }
    }

    // MARK: - Request / reply bodies

    /// `terminalId` is upstream's — every `terminal.open` names the shell it
    /// wants and the SERVER never allocates one (`terminal.ts:33-37`,
    /// `terminalLabels.ts:26-31`). It is optional on this wire only so the
    /// phone's one-terminal build (#513) and every caller written before
    /// several-per-thread keep working: absent means `defaultTerminalId`.
    public struct OpenRequest: Codable, Sendable, Equatable {
        public let cols: Int
        public let rows: Int
        public let terminalId: String?
        public init(cols: Int, rows: Int, terminalId: String? = nil) {
            self.cols = cols; self.rows = rows; self.terminalId = terminalId
        }
        /// The terminal this open names — the id it sent, or the first shell's.
        public var resolvedTerminalId: String { terminalId ?? defaultTerminalId }
        public func validate() -> ValidationError? {
            if let terminalId, T3Terminal.validate(terminalId: terminalId) != nil {
                return .terminalIdInvalid
            }
            return T3Terminal.validate(cols: cols, rows: rows)
        }
    }

    public struct OpenReply: Codable, Sendable, Equatable {
        public let terminalId: String
        public let status: SessionStatus
        public let cwd: String
        public let pid: Int32
        public init(terminalId: String, status: SessionStatus, cwd: String, pid: Int32) {
            self.terminalId = terminalId; self.status = status; self.cwd = cwd; self.pid = pid
        }
    }

    public struct WriteRequest: Codable, Sendable, Equatable {
        public let data: String
        public init(data: String) {
            self.data = data
        }
        public func validate() -> ValidationError? {
            data.utf8.count > maxWriteBytes ? .dataTooLarge : nil
        }
    }

    public struct ResizeRequest: Codable, Sendable, Equatable {
        public let cols: Int
        public let rows: Int
        public init(cols: Int, rows: Int) {
            self.cols = cols; self.rows = rows
        }
        public func validate() -> ValidationError? {
            T3Terminal.validate(cols: cols, rows: rows)
        }
    }

    public enum ValidationError: Error, Sendable, Equatable {
        case colsOutOfRange
        case rowsOutOfRange
        case dataTooLarge
        /// Blank, whitespace-only or over `maxTerminalIdLength`
        /// (`TerminalIdSchema`, `terminal.ts:19`).
        case terminalIdInvalid
        /// The pid already holds `maxTerminalsPerSession` shells.
        case tooManyTerminals
    }

    static func validate(cols: Int, rows: Int) -> ValidationError? {
        guard (minCols...maxCols).contains(cols) else { return .colsOutOfRange }
        guard (minRows...maxRows).contains(rows) else { return .rowsOutOfRange }
        return nil
    }

    /// `TerminalIdSchema` (`terminal.ts:19`): trimmed, non-empty, ≤ 128.
    public static func validate(terminalId: String) -> ValidationError? {
        let trimmed = terminalId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, terminalId.count <= maxTerminalIdLength else {
            return .terminalIdInvalid
        }
        return nil
    }

    // MARK: - Routes

    /// One of the five mirror routes this contract defines, already parsed
    /// out of a request's method, path and query. `id` is the terminal id —
    /// one pid holds several (`defaultTerminalId` is only the first shell's);
    /// `since` is the stream's resume point, absent on a fresh attach.
    public enum Route: Sendable, Equatable {
        case open(pid: Int32)
        case stream(pid: Int32, id: String, since: Int?)
        case write(pid: Int32, id: String)
        case resize(pid: Int32, id: String)
        case close(pid: Int32, id: String)
    }

    public static func terminalPath(pid: Int32) -> String { "/sessions/\(pid)/terminal" }
    public static func terminalStreamPath(pid: Int32, id: String, since: Int? = nil) -> String {
        var path = "/sessions/\(pid)/terminal/\(percentEncoded(id))/stream"
        if let since { path += "?\(sinceQueryName)=\(since)" }
        return path
    }
    public static func terminalWritePath(pid: Int32, id: String) -> String {
        "/sessions/\(pid)/terminal/\(percentEncoded(id))/write"
    }
    public static func terminalResizePath(pid: Int32, id: String) -> String {
        "/sessions/\(pid)/terminal/\(percentEncoded(id))/resize"
    }
    /// `DELETE /sessions/<pid>/terminal/<id>` — no `/close` suffix, per
    /// #507's table (unlike `write`/`resize`, close names the terminal
    /// itself and lets the verb say what happens to it).
    public static func terminalClosePath(pid: Int32, id: String) -> String {
        "/sessions/\(pid)/terminal/\(percentEncoded(id))"
    }

    /// Query parameter carrying the stream's resume point.
    public static let sinceQueryName = "since"

    /// `method` + `request.path`/`request.query` → the route it names, or
    /// `nil` for anything that isn't one of the five. The stream's
    /// `?t=<token>` rides in `request.target` like every other route's
    /// pairing token (`MirrorTransport.tokenQueryName`) and is read there,
    /// not here — this parser only extracts what the route itself needs.
    public static func parse(method: String, request: MirrorTransport.Request) -> Route? {
        let parts = request.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3, parts[0] == "sessions", parts[2] == "terminal", let pid = Int32(parts[1]) else {
            return nil
        }
        if parts.count == 3 {
            return method == "POST" ? .open(pid: pid) : nil
        }
        if parts.count == 4, method == "DELETE", let id = percentDecoded(parts[3]) {
            return .close(pid: pid, id: id)
        }
        guard parts.count == 5, let id = percentDecoded(parts[3]) else { return nil }
        switch (method, parts[4]) {
        case ("GET", "stream"):
            let since = request.query(sinceQueryName).flatMap(Int.init)
            return .stream(pid: pid, id: id, since: since)
        case ("POST", "write"):
            return .write(pid: pid, id: id)
        case ("POST", "resize"):
            return .resize(pid: pid, id: id)
        default:
            return nil
        }
    }

    private static func percentEncoded(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }
    private static func percentDecoded(_ component: String) -> String? {
        let decoded = component.removingPercentEncoding ?? component
        return decoded.isEmpty ? nil : decoded
    }

    // MARK: - Masked request description (#507 review ruling 7)

    /// `request.description`'s stand-in for logging: everything but the
    /// pairing token, which must never land in a log line (the stream's
    /// `t=<token>` rides in the query because `URLSession.bytes` can't set
    /// a header per chunk — acceptable only because it's never printed).
    public static func maskedDescription(method: String, target: String) -> String {
        guard let mark = target.firstIndex(of: "?") else { return "\(method) \(target)" }
        let path = target[target.startIndex..<mark]
        let masked = target[target.index(after: mark)...].split(separator: "&").map { pair -> String in
            let halves = pair.split(separator: "=", maxSplits: 1)
            guard halves.first.map(String.init) == MirrorTransport.tokenQueryName else { return String(pair) }
            return "\(MirrorTransport.tokenQueryName)=***"
        }.joined(separator: "&")
        return "\(method) \(path)?\(masked)"
    }

    // MARK: - History chunking (#507 review: upstream's `MAX_HISTORY_CHUNK_LENGTH`)

    /// Splits `history` into pieces no larger than `chunkLength` UTF-8
    /// bytes, cut only on Unicode scalar boundaries so a multi-byte
    /// character is never split across two chunks. `chunks.joined() ==
    /// history` always.
    public static func historyChunks(_ history: String, chunkLength: Int = historyChunkLength) -> [String] {
        guard !history.isEmpty else { return [] }
        var chunks: [String] = []
        var current = String.UnicodeScalarView()
        var currentBytes = 0
        for scalar in history.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            if currentBytes + scalarBytes > chunkLength, !current.isEmpty {
                chunks.append(String(current))
                current = String.UnicodeScalarView()
                currentBytes = 0
            }
            current.append(scalar)
            currentBytes += scalarBytes
        }
        if !current.isEmpty { chunks.append(String(current)) }
        return chunks
    }

    /// The initial attach's `snapshot` frame(s): `history` cut into
    /// `historyChunkLength`-sized pieces, each carrying a `sequence` that
    /// is the cumulative byte offset from `ringStart` through that piece —
    /// the last frame's `sequence` equals `ringStart + history.utf8.count`.
    /// `status`/`exitCode`/`exitSignal` describe the terminal as a whole
    /// and repeat on every frame; a client cares about them once it has
    /// applied the last one.
    public static func snapshotFrames(history: String, ringStart: Int, status: SessionStatus,
                                      exitCode: Int? = nil, exitSignal: Int? = nil,
                                      chunkLength: Int = historyChunkLength) -> [SnapshotPayload] {
        let chunks = historyChunks(history, chunkLength: chunkLength)
        guard !chunks.isEmpty else {
            return [SnapshotPayload(history: "", status: status, sequence: ringStart,
                                    exitCode: exitCode, exitSignal: exitSignal)]
        }
        var offset = ringStart
        return chunks.map { chunk in
            offset += chunk.utf8.count
            return SnapshotPayload(history: chunk, status: status, sequence: offset,
                                   exitCode: exitCode, exitSignal: exitSignal)
        }
    }

    // MARK: - Resume (#507 review ruling 1)

    public enum ResumePlan: Sendable, Equatable {
        /// The ring no longer holds `since` (or there was none to begin
        /// with) — answer with a fresh full snapshot, never a gap.
        case snapshot
        /// The ring still holds everything from `seq` on — replay `output`
        /// frames starting there.
        case outputFrom(Int)
    }

    /// `since` is a byte offset the client claims to have already seen;
    /// `ringStart`/`ringEnd` bound what the host's ring currently holds.
    /// Anything outside `[ringStart, ringEnd]` (no `since`, an evicted
    /// offset, or one further ahead than the host has ever emitted) falls
    /// back to a fresh snapshot.
    public static func resumePlan(since: Int?, ringStart: Int, ringEnd: Int) -> ResumePlan {
        guard let since, since >= ringStart, since <= ringEnd else { return .snapshot }
        return .outputFrom(since)
    }
}

extension MirrorTransport.Request {
    /// This request's method + masked target, safe to log — the pairing
    /// token (header or `?t=`) never appears (#507 review ruling 7).
    public func maskedDescription(method: String) -> String {
        T3Terminal.maskedDescription(method: method, target: target)
    }
}
