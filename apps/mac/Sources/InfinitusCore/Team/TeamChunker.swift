import Foundation

/// Spec §7 transcripts: append-only chunks of at most `maxChunkBytes` of
/// NEW complete lines since the last chunk, each line redacted before
/// it is counted. Ciphertext never delta-compresses, so chunks are
/// what keeps the store's growth linear in what was actually written.
public enum TeamChunker {
    public static let maxChunkBytes = 1 << 20
    /// Bytes read per call: a first publish of a hundreds-of-MB
    /// transcript proceeds in slices, one per publish.
    public static let readCap = 64 << 20
    private static let newline = UInt8(ascii: "\n")

    /// Chunks of the complete lines after byte `offset`, handed to `sink`
    /// one at a time and dropped, and the offset just past the last line
    /// consumed. A line without its newline waits for the next call; a
    /// line above `maxBytes` is its own chunk. Streaming (rather than
    /// returning them all) is what keeps a publish holding ONE chunk
    /// instead of a whole `readCap` slice of them.
    @discardableResult
    public static func stream(of url: URL, from offset: Int, maxBytes: Int = maxChunkBytes,
                              readCap: Int = readCap, redact: (String) -> String,
                              sink: (Data) throws -> Void) throws -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return offset }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: readCap), let lastNewline = data.lastIndex(of: newline) else {
            return offset
        }
        let complete = data[data.startIndex...lastNewline]
        var current = Data()
        var start = complete.startIndex
        while start < complete.endIndex {
            let end = complete[start...].firstIndex(of: newline) ?? complete.endIndex
            // The redactor's regex passes hand back autoreleased strings
            // sized like the line, several per line: drain per line.
            var line = drainingPool { Data(redact(String(decoding: complete[start..<end], as: UTF8.self)).utf8) }
            line.append(newline)
            if !current.isEmpty, current.count + line.count > maxBytes {
                try sink(current)
                current = Data()
            }
            current.append(line)
            start = end + 1
        }
        if !current.isEmpty { try sink(current) }
        return offset + complete.count
    }

    /// `stream`, collected — the shape the tests and any one-shot caller want.
    public static func chunks(of url: URL, from offset: Int, maxBytes: Int = maxChunkBytes,
                              readCap: Int = readCap, redact: (String) -> String) throws -> (chunks: [Data], offset: Int) {
        var out: [Data] = []
        let end = try stream(of: url, from: offset, maxBytes: maxBytes, readCap: readCap, redact: redact) { out.append($0) }
        return (out, end)
    }
}
