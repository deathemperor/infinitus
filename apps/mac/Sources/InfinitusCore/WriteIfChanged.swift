import Foundation

/// A disk write skipped when its bytes are what was last written (#1310):
/// the snapshot cache was rewritten atomically on every refresh pass —
/// 1,440 temp-file-and-rename writes a day, nearly all of identical
/// bytes. `take` answers whether `data` differs from the last bytes
/// taken and remembers them; the first take always answers true, so a
/// fresh process writes once.
public struct WriteIfChanged: Sendable {
    private var last: Data?

    public init() {}

    public mutating func take(_ data: Data) -> Bool {
        if last == data { return false }
        last = data
        return true
    }
}
