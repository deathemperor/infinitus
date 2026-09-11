import Foundation
import Crypto

/// PBKDF2-HMAC-SHA256 (RFC 8018 §5.2) over swift-crypto's HMAC, so the
/// identity export (spec §2.1) derives the same key on macOS, Linux and
/// Windows. Blocks are XORed as byte arrays: 600k rounds × 32 bytes
/// through `Data` subscripts would take seconds.
public enum PBKDF2 {
    public static func sha256(password: Data, salt: Data, rounds: Int, length: Int) -> Data {
        precondition(rounds >= 1 && length >= 1)
        let key = SymmetricKey(data: password)
        var out: [UInt8] = []
        out.reserveCapacity(length)
        var block: UInt32 = 1
        while out.count < length {
            var u = [UInt8](HMAC<Crypto.SHA256>.authenticationCode(for: salt + block.bigEndianBytes, using: key))
            var t = u
            for _ in 1..<rounds {
                u = [UInt8](HMAC<Crypto.SHA256>.authenticationCode(for: u, using: key))
                for i in 0..<t.count { t[i] ^= u[i] }
            }
            out += t
            block += 1
        }
        return Data(out.prefix(length))
    }
}

private extension UInt32 {
    var bigEndianBytes: Data { withUnsafeBytes(of: bigEndian) { Data($0) } }
}
