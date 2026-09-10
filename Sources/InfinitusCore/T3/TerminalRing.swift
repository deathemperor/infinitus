import Foundation

/// The terminal host's history ring (#507 step 3): raw pty bytes in, whole
/// UTF-8 text out, `T3Terminal.ringBytes` of scrollback kept. A value type
/// in Core so the byte bookkeeping the wire depends on is tested without a
/// PTY — `TerminalHost` (Sources/Infinitus) owns one per terminal.
///
/// `end` is the wire's `sequence` (cumulative UTF-8 bytes this terminal has
/// ever emitted) and `start` how far back the ring still reaches: exactly
/// the pair `T3Terminal.resumePlan` wants.
///
/// Two places a naive byte ring would hand the phone U+FFFD instead of the
/// character the shell printed, both handled here:
/// - a read from a pty splits wherever the kernel felt like it, so a
///   multi-byte scalar can straddle two chunks — the tail of an incomplete
///   sequence is held back until the rest arrives (`flushPending` gives it
///   up when the terminal dies mid-character);
/// - eviction would leave the ring starting on a continuation byte — whole
///   scalars are dropped instead, which only moves `start` a byte or three.
public struct TerminalRing: Sendable, Equatable {
    /// How much scrollback the ring keeps. Trimming happens in batches
    /// (a quarter of this over) rather than on every append: at full tilt
    /// a pty hands over a chunk every few milliseconds, and a 256 KB
    /// memmove per chunk is idle CPU the perf gate would see.
    public let capacity: Int
    private var buffer: Data
    private var pending: Data
    /// Cumulative UTF-8 bytes emitted so far — the wire's `sequence`.
    public private(set) var end: Int

    public init(capacity: Int = T3Terminal.ringBytes) {
        self.capacity = max(1, capacity)
        self.buffer = Data()
        self.pending = Data()
        self.end = 0
    }

    /// The oldest sequence the ring can still replay from.
    public var start: Int { end - buffer.count }

    /// Everything the ring holds, as text — the `snapshot` frame's history.
    public var history: String { String(decoding: buffer, as: UTF8.self) }

    /// Bytes held back as the start of a scalar whose rest hasn't arrived.
    public var pendingBytes: Int { pending.count }

    /// Appends one pty read. The text that became emittable and the
    /// `sequence` at the end of it, or `nil` when the chunk was nothing
    /// but the first bytes of a scalar still in flight.
    public mutating func append(_ data: Data) -> (text: String, sequence: Int)? {
        var incoming = pending
        incoming.append(data)
        pending = Data()
        let hold = Self.incompleteTailLength(incoming)
        if hold > 0 {
            pending = Data(incoming.suffix(hold))
            incoming = Data(incoming.prefix(incoming.count - hold))
        }
        guard !incoming.isEmpty else { return nil }
        buffer.append(incoming)
        end += incoming.count
        trim()
        return (String(decoding: incoming, as: UTF8.self), end)
    }

    /// Gives up a held-back partial scalar — the shell died mid-character,
    /// so those bytes are never completed and the phone gets the
    /// replacement character rather than silence.
    public mutating func flushPending() -> (text: String, sequence: Int)? {
        guard !pending.isEmpty else { return nil }
        let tail = pending
        pending = Data()
        buffer.append(tail)
        end += tail.count
        trim()
        return (String(decoding: tail, as: UTF8.self), end)
    }

    /// The ring's text from `sequence` on — a resume's replay. `nil` when
    /// the ring no longer reaches that far back (or `sequence` is ahead of
    /// what was ever emitted); `T3Terminal.resumePlan` decides that first,
    /// this is the safety net.
    public func slice(from sequence: Int) -> String? {
        guard sequence >= start, sequence <= end else { return nil }
        return String(decoding: buffer.dropFirst(sequence - start), as: UTF8.self)
    }

    private mutating func trim() {
        guard buffer.count > capacity + capacity / 4 else { return }
        var drop = buffer.count - capacity
        // Never leave the ring starting mid-scalar.
        while drop < buffer.count, buffer[buffer.startIndex + drop] & 0xC0 == 0x80 { drop += 1 }
        buffer = Data(buffer.dropFirst(drop))
    }

    /// How many trailing bytes are the start of a UTF-8 scalar whose
    /// continuation bytes haven't arrived yet — 0 for a clean boundary
    /// (invalid bytes count as clean: they are the shell's problem, and
    /// holding them back forever would stall the stream).
    static func incompleteTailLength(_ data: Data) -> Int {
        let bytes = [UInt8](data.suffix(4))
        var index = bytes.count - 1
        var continuations = 0
        while index >= 0, bytes[index] & 0xC0 == 0x80, continuations < 3 {
            continuations += 1
            index -= 1
        }
        guard index >= 0 else { return 0 }
        let lead = bytes[index]
        let need: Int
        if lead & 0x80 == 0 { need = 1 }
        else if lead & 0xE0 == 0xC0 { need = 2 }
        else if lead & 0xF0 == 0xE0 { need = 3 }
        else if lead & 0xF8 == 0xF0 { need = 4 }
        else { return 0 }
        let have = continuations + 1
        return have < need ? have : 0
    }
}
