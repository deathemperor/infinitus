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
    private var inode: ino_t?
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
    /// An agent tail's own lapsed-sign-in reading, computed when it moves —
    /// the detector runs `contains` over every recent tool result, and 18
    /// agents re-detected on every move of the parent were most of what
    /// was left of a progress read (#346).
    private var need: SessionProgress.LoginNeeds = (nil, nil)

    public init(url: URL, maxBytes: Int = 512 * 1024) {
        self.init(url: url, maxBytes: maxBytes, scansAgents: true)
    }

    private init(url: URL, maxBytes: Int, scansAgents: Bool) {
        self.url = url
        self.maxBytes = maxBytes
        self.scansAgents = scansAgents
    }

    /// Reads the bytes appended since the last call, to this transcript
    /// and to its recent sub-agents'. True when entries changed (or a
    /// file shrank and was reread, or an agent aged out). A trailing
    /// partial line waits for its newline.
    public mutating func advance(now: Date = Date()) -> Bool {
        var moved = advanceOwn()
        guard scansAgents else { return moved }
        let dir = url.deletingPathExtension().appendingPathComponent("subagents")
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
        var st = stat()
        let id: ino_t? = fstat(handle.fileDescriptor, &st) == 0 ? st.st_ino : nil
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
            entries.append(entry)
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

    public func progress(name: String? = nil, now: Date = Date()) -> SessionProgress {
        SessionProgress.assemble(entries: entries, headGoal: headGoal, transcript: url, name: name, now: now,
                                 subagents: SessionProgress.newest(agents.values.map(\.need)))
    }
}
