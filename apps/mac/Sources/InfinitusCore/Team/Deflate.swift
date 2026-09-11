import Foundation
import CZlib

/// zlib-wrapped deflate (RFC 1950), the compression inside every team
/// envelope (spec §3). Ciphertext never delta-compresses in git, so the
/// plaintext shrinks before it is sealed.
public enum Deflate {
    public enum DeflateError: Error, Equatable { case zlib(Int32), tooLarge }

    public static func compress(_ data: Data) throws -> Data {
        var destLen = compressBound(uLong(data.count))
        var out = Data(count: Int(destLen))
        let rc = out.withUnsafeMutableBytes { dst -> Int32 in
            data.withUnsafeBytes { src -> Int32 in
                compress2(dst.baseAddress!.assumingMemoryBound(to: Bytef.self), &destLen,
                          src.baseAddress?.assumingMemoryBound(to: Bytef.self), uLong(data.count),
                          Z_BEST_COMPRESSION)
            }
        }
        guard rc == Z_OK else { throw DeflateError.zlib(rc) }
        out.count = Int(destLen)
        return out
    }

    /// Grows the output buffer until zlib stops reporting Z_BUF_ERROR,
    /// capped at `maxBytes` so a hostile envelope can't balloon memory.
    public static func decompress(_ data: Data, maxBytes: Int = 64 << 20) throws -> Data {
        var capacity = min(maxBytes, max(1024, data.count * 4))
        while true {
            var destLen = uLong(capacity)
            var out = Data(count: capacity)
            let rc = out.withUnsafeMutableBytes { dst -> Int32 in
                data.withUnsafeBytes { src -> Int32 in
                    uncompress(dst.baseAddress!.assumingMemoryBound(to: Bytef.self), &destLen,
                               src.baseAddress?.assumingMemoryBound(to: Bytef.self), uLong(data.count))
                }
            }
            if rc == Z_OK {
                out.count = Int(destLen)
                return out
            }
            guard rc == Z_BUF_ERROR else { throw DeflateError.zlib(rc) }
            guard capacity < maxBytes else { throw DeflateError.tooLarge }
            capacity = min(maxBytes, capacity * 4)
        }
    }
}
