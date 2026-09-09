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
    private(set) var entries: [[String: Any]] = []
    private var sizes: [Int] = []
    private var bytesHeld = 0
    /// The head's opening prompt, read once it exists (the head never changes).
    private var headGoal: String?

    public init(url: URL, maxBytes: Int = 512 * 1024) {
        self.url = url
        self.maxBytes = maxBytes
    }

    /// Reads the bytes appended since the last call. True when entries
    /// changed (or the file shrank and was reread). A trailing partial
    /// line waits for its newline.
    public mutating func advance() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return false }
        var moved = false
        if size < offset {
            entries = []; sizes = []; bytesHeld = 0; offset = 0; headGoal = nil
            moved = true
        }
        guard size > offset else { return moved }
        var start = offset
        if entries.isEmpty, offset == 0, size > UInt64(maxBytes) { start = size - UInt64(maxBytes) }
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd(),
              let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return moved }
        let complete = data[data.startIndex...lastNewline]
        offset = start + UInt64(complete.count)
        for line in complete.split(separator: UInt8(ascii: "\n")) {
            guard line.first == UInt8(ascii: "{"),
                  let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            entries.append(entry)
            sizes.append(line.count + 1)
            bytesHeld += line.count + 1
            moved = true
        }
        while bytesHeld > maxBytes, entries.count > 1 {
            bytesHeld -= sizes.removeFirst()
            entries.removeFirst()
        }
        if headGoal == nil { headGoal = SessionProgress.readGoal(at: url) }
        return moved
    }

    public func progress(name: String? = nil, now: Date = Date()) -> SessionProgress {
        SessionProgress.assemble(entries: entries, headGoal: headGoal, transcript: url, name: name, now: now)
    }
}
