import Foundation

/// RFC 4648 base32, lowercase, unpadded — the alphabet a `kid` is written
/// in (26 chars for 16 bytes). `decode` below is the inverse, used by
/// recovery keys.
public enum Base32 {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    public static func encode(_ data: Data) -> String {
        var out = ""
        out.reserveCapacity((data.count * 8 + 4) / 5)
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(buffer >> bits) & 31])
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    /// RFC 4648 base32, case-insensitive, no padding (the inverse of
    /// `encode`). nil on a character outside the alphabet or a length
    /// that carries no whole byte (1, 3 or 6 chars mod 8).
    public static func decode(_ text: String) -> Data? {
        let lower = text.lowercased()
        guard ![1, 3, 6].contains(lower.count % 8) else { return nil }
        var out = Data(), buffer: UInt32 = 0, bits = 0
        for ch in lower {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            buffer = (buffer << 5) | UInt32(idx)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt32(bits)) & 0xff))
            }
        }
        return out
    }
}
