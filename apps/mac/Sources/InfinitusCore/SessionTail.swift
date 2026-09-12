import Foundation

/// One session transcript read incrementally (#346). The first `advance`
/// takes the last `maxBytes`, as `SessionProgress.read` always did; each
/// later one reads only what the file gained, keeps the window at
/// `maxBytes` by dropping the oldest entries, and says whether anything
/// moved — a streaming session appends every second and the transcript
/// watcher re-reads on each, so re-parsing the whole window each time
/// was the busy pop-out's idle floor. A file that shrank starts over.
public struct SessionTail: @unchecked Sendable {
    public let url: URL
    public let maxBytes: Int
    /// The first byte not yet consumed — the end of the last complete line.
    public private(set) var offset: UInt64 = 0
    /// The file's identity: a transcript replaced under the same path (an
    /// atomic write-and-rename) starts over even when the new file is no
    /// shorter — appending its lines onto the old ones would be silently wrong.
    private var inode: UInt64?
    private(set) var entries: [[String: Any]] = []
    private var sizes: [Int] = []
    private var bytesHeld = 0
    /// The head's opening prompt, read once it exists (the head never changes).
    private var headGoal: String?
    /// The session's sub-agent transcripts touched within the login
    /// window, each read the same way — a parent with 18 recent agents
    /// re-read 2.3 MB of their tails on every move of its own (#346).
    private var agents: [String: SessionTail] = [:]
    private let scansAgents: Bool
    /// The sub-agent folder is listed (and every recent agent file
    /// stat'd and read) only when the folder's mtime moved — a new or
    /// removed file — or `agentWalkInterval` has passed: a session with
    /// 1,900 agent files listed them on every refresh of every tail once
    /// the walk stopped riding the parent's own size+mtime stamp (#346).
    private var agentsDirMtime: Date?
    private var agentWalkAt: Date?
    static let agentWalkInterval: TimeInterval = 30
    /// An agent tail's own lapsed-sign-in reading, computed when it moves —
    /// the detector runs `contains` over every recent tool result, and 18
    /// agents re-detected on every move of the parent were most of what
    /// was left of a progress read (#346).
    private var need: SessionProgress.LoginNeeds = (nil, nil)

    /// A progress tail keeps of each entry only what `SessionProgress.parse`
    /// reads (`slim`, #499): decoded whole, a 512 KB window held ~1.25 MB
    /// of dictionaries and strings per tracked session, four fifths of it
    /// thinking blocks, signatures, attachments and bookkeeping the parser
    /// never looks at. The feed reader's window renders the timeline and
    /// keeps its entries whole.
    private let slims: Bool

    public init(url: URL, maxBytes: Int = 512 * 1024) {
        self.init(url: url, maxBytes: maxBytes, scansAgents: true)
    }

    /// `scansAgents: false` reads this one file and nothing else — a
    /// sub-agent's tail, or the feed reader's incremental window
    /// (`slims: false`).
    init(url: URL, maxBytes: Int, scansAgents: Bool, slims: Bool = true) {
        self.url = url
        self.maxBytes = maxBytes
        self.scansAgents = scansAgents
        self.slims = slims
    }

    /// Reads the bytes appended since the last call, to this transcript
    /// and to its recent sub-agents'. True when entries changed (or a
    /// file shrank and was reread, or an agent aged out). A trailing
    /// partial line waits for its newline.
    public mutating func advance(now: Date = Date()) -> Bool {
        var moved = advanceOwn()
        guard scansAgents else { return moved }
        let dir = url.deletingPathExtension().appendingPathComponent("subagents")
        let dirMtime = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let due = dirMtime != agentsDirMtime
            || agentWalkAt.map { now.timeIntervalSince($0) >= Self.agentWalkInterval } ?? true
        guard due else { return moved }
        agentsDirMtime = dirMtime
        agentWalkAt = now
        var kept: [String: SessionTail] = [:]
        for file in Transcript.agentFiles(under: dir) {
            guard let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate),
                  now.timeIntervalSince(mtime) <= SessionProgress.subagentAwsLoginWindow else { continue }
            var tail = agents[file.path] ?? SessionTail(url: file, maxBytes: SessionProgress.subagentTailBytes, scansAgents: false)
            if tail.advanceOwn() {
                moved = true
                tail.need = SessionProgress.loginNeeds(entries: tail.entries)
            }
            kept[file.path] = tail
        }
        if Set(kept.keys) != Set(agents.keys) { moved = true }
        agents = kept
        return moved
    }

    private mutating func advanceOwn() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return false }
        var moved = false
        #if os(Windows)
        // No `fileDescriptor` on Windows Foundation: the file index by path.
        let id = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? UInt64
        #else
        var st = stat()
        let id: UInt64? = fstat(handle.fileDescriptor, &st) == 0 ? UInt64(st.st_ino) : nil
        #endif
        if size < offset || (inode != nil && id != inode) {
            entries = []; sizes = []; bytesHeld = 0; offset = 0; headGoal = nil
            moved = true
        }
        inode = id
        guard size > offset else { return moved }
        var start = offset
        if entries.isEmpty, offset == 0, size > UInt64(maxBytes) { start = size - UInt64(maxBytes) }
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd(),
              let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return moved }
        let complete = data[data.startIndex...lastNewline]
        offset = start + UInt64(complete.count)
        for line in SessionFeedReader.lines(of: Data(complete)) {
            guard line.utf8.first == UInt8(ascii: "{"),
                  let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            entries.append(slims ? Self.slim(entry) : entry)
            sizes.append(line.utf8.count + 1)
            bytesHeld += line.utf8.count + 1
            moved = true
        }
        while bytesHeld > maxBytes, entries.count > 1 {
            bytesHeld -= sizes.removeFirst()
            entries.removeFirst()
        }
        if scansAgents, headGoal == nil { headGoal = SessionProgress.readGoal(at: url) }
        return moved
    }

    /// The entry reduced to the keys `SessionProgress.parse` and its
    /// helpers read — `describe`/`classify` (tool name, command, path,
    /// pattern), the todos, `goal`/`nowDoing` (a text's head), the token
    /// usage, model, branch, retry flag, summary, and `loginNeed` (tool
    /// result text, kept whole: the sign-in detectors regex over it).
    /// A parser that starts reading a new key adds it here;
    /// `SessionTailSlimTests` compares the slimmed and the whole parse.
    static func slim(_ entry: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in ["type", "timestamp", "gitBranch", "isApiErrorMessage", "summary", "subtype"] {
            if let value = entry[key] { out[key] = value }
        }
        guard let message = entry["message"] as? [String: Any] else { return out }
        var slimMessage: [String: Any] = [:]
        if let model = message["model"] { slimMessage["model"] = model }
        if let tokens = (message["usage"] as? [String: Any])?["output_tokens"] {
            slimMessage["usage"] = ["output_tokens": tokens]
        }
        if let text = message["content"] as? String {
            slimMessage["content"] = head(of: text)
        } else if let blocks = message["content"] as? [[String: Any]] {
            slimMessage["content"] = blocks.map(slim(block:))
        }
        out["message"] = slimMessage
        return out
    }

    private static func slim(block: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        let type = block["type"] as? String
        if let type { out["type"] = type }
        switch type {
        case "tool_use":
            if let name = block["name"] { out["name"] = name }
            if let id = block["id"] { out["id"] = id }
            if let input = block["input"] as? [String: Any] {
                var kept: [String: Any] = [:]
                for key in ["command", "file_path", "pattern"] {
                    if let value = input[key] { kept[key] = value }
                }
                if let todos = input["todos"] as? [[String: Any]] {
                    kept["todos"] = todos.map { todo -> [String: Any] in
                        var item: [String: Any] = [:]
                        if let status = todo["status"] { item["status"] = status }
                        if let active = todo["activeForm"] { item["activeForm"] = active }
                        return item
                    }
                }
                out["input"] = kept
            }
        case "tool_result":
            if let id = block["tool_use_id"] { out["tool_use_id"] = id }
            if let text = block["content"] as? String {
                out["content"] = text
            } else if let parts = block["content"] as? [[String: Any]] {
                out["content"] = parts.map { part -> [String: Any] in
                    part["text"].map { ["text": $0] } ?? [:]
                }
            }
        default:
            if let text = block["text"] as? String { out["text"] = head(of: text) }
        }
        return out
    }

    /// What `goal` and `nowDoing` can read of a text: they take the first
    /// line after any leading whitespace and at most 100 characters of it.
    private static func head(of text: String) -> String {
        let leading = text.prefix(while: \.isWhitespace).count
        return String(text.prefix(leading + 200))
    }

    public func progress(name: String? = nil, now: Date = Date()) -> SessionProgress {
        SessionProgress.assemble(entries: entries, headGoal: headGoal, transcript: url, name: name, now: now,
                                 subagents: SessionProgress.newest(agents.values.map(\.need)))
    }
}
