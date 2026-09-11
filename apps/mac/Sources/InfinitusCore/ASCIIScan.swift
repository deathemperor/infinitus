import Foundation

/// Byte-level text matching for the hot scans over transcript tool
/// results (#346): Foundation's `String.contains` runs a locale-aware
/// search (~50× a byte loop over the same haystack), and `lowercased()`
/// copies the whole text through Unicode case mapping — for a signature
/// that is plain ASCII, folding the bytes is enough.
enum ASCIIScan {
    /// The text's UTF-8 with ASCII letters folded to lowercase; every
    /// other byte passes through, so a needle that is ASCII matches
    /// exactly where `text.lowercased().contains(needle)` would.
    static func lowered(_ text: String) -> [UInt8] {
        var bytes = Array(text.utf8)
        for i in bytes.indices where bytes[i] >= 65 && bytes[i] <= 90 { bytes[i] |= 0x20 }
        return bytes
    }

    static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        let first = needle[0]
        var i = 0
        let last = hay.count - needle.count
        while i <= last {
            if hay[i] == first {
                var j = 1
                while j < needle.count, hay[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    /// Whether any (non-empty) line of the text opens with one of the
    /// prefixes — `text.split("\n").contains { line in prefixes.contains
    /// { line.hasPrefix($0) } }` without splitting.
    static func anyLineStarts(_ hay: [UInt8], with prefixes: [[UInt8]]) -> Bool {
        var start = 0
        while start < hay.count {
            if hay[start] == UInt8(ascii: "\n") { start += 1; continue }
            for prefix in prefixes where hay.count - start >= prefix.count {
                var j = 0
                while j < prefix.count, hay[start + j] == prefix[j] { j += 1 }
                if j == prefix.count { return true }
            }
            while start < hay.count, hay[start] != UInt8(ascii: "\n") { start += 1 }
        }
        return false
    }
}
