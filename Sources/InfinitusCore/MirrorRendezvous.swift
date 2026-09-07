import Foundation

/// The pairing rendezvous on infinitus.run (#9 remote access, user
/// 2026-09-03 "can the domain be reused for other users?" → yes, this
/// way): a Mac on the free quick tunnel gets a fresh *.trycloudflare.com
/// URL every start, so it PUTs the current one under a key only it and
/// its paired phones can derive — SHA-256 of the pairing token — and a
/// phone whose saved tunnel URL stopped answering GETs the new one. The
/// URL alone opens nothing (every mirror request still carries the
/// bearer token) and the key is unguessable, so the service holds no
/// accounts. site/src/worker.js is the other half.
public enum MirrorRendezvous {
    public static let defaultBase = "https://infinitus.run/rendezvous"

    /// Lower-case hex SHA-256 of the normalized token. Nil for an empty
    /// token — there is nothing to look up.
    public static func key(token: String) -> String? {
        let normalized = MirrorPairing.normalize(token)
        guard !normalized.isEmpty else { return nil }
        return SHA256.hex(Array(normalized.utf8))
    }

    public static func url(token: String, base: String = defaultBase) -> URL? {
        guard let key = key(token: token) else { return nil }
        return url(key: key, base: base)
    }

    /// A slot addressed by an already-derived key (the team control key,
    /// `TeamControl.rendezvousKey`): 64 lower-case hex or nothing.
    public static func url(key: String, base: String = defaultBase) -> URL? {
        guard key.count == 64, key.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return URL(string: "\(base)/\(key)")
    }

    /// The only endpoints the rendezvous replaces: quick-tunnel URLs.
    public static func isEphemeral(_ endpoint: String) -> Bool {
        endpoint.lowercased().contains(".trycloudflare.com")
    }

    /// The Mac's side: `{"url": …}` for the PUT.
    public static func publishBody(url: String) -> Data {
        (try? JSONEncoder().encode(["url": url])) ?? Data()
    }

    /// The phone's side: the URL a GET answered with, if any.
    public static func parseLookup(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = object["url"] as? String, isEphemeral(url) else { return nil }
        return url
    }
}

/// FIPS 180-4 SHA-256, plain Swift so the key is the same bytes on the
/// Mac, the phone and the Linux tray (CryptoKit is Apple-only; pulling
/// swift-crypto in for one hash isn't worth a dependency).
enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hex(_ message: [UInt8]) -> String {
        digest(message).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                           0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var bytes = message
        let bitLength = UInt64(message.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((bitLength >> UInt64(shift)) & 0xff)) }
        @inline(__always) func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: bytes.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(bytes[j]) << 24 | UInt32(bytes[j + 1]) << 16 | UInt32(bytes[j + 2]) << 8 | UInt32(bytes[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { [UInt8($0 >> 24), UInt8(($0 >> 16) & 0xff), UInt8(($0 >> 8) & 0xff), UInt8($0 & 0xff)] }
    }
}
