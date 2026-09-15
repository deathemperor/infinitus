import Foundation

/// Spec §2.1 local path: the 32-byte identity secret as base32 in 8
/// dashed groups (52 chars → 7,7,7,7,6,6,6,6), shown once with "keep
/// this offline" and re-showable after unlock. Typing it back yields the
/// same identity (same kid) on any machine.
public enum RecoveryKey {
    static let groups = [7, 7, 7, 7, 6, 6, 6, 6]

    public static func encode(_ secret: Data) -> String {
        precondition(secret.count == 32)
        var rest = Substring(Base32.encode(secret))
        var out: [String] = []
        for n in groups {
            out.append(String(rest.prefix(n)))
            rest = rest.dropFirst(n)
        }
        return out.joined(separator: "-")
    }

    /// Dashes, spaces and case are cosmetic. nil unless exactly 32 bytes come back.
    public static func decode(_ text: String) -> Data? {
        let compact = text.filter { !$0.isWhitespace && $0 != "-" }
        guard compact.count == 52, let data = Base32.decode(compact), data.count == 32 else { return nil }
        return data
    }
}
