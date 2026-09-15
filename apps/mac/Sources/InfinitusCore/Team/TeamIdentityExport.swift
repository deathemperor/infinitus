import Foundation
import Crypto

/// Spec §2.1: the identity secret sealed with a passphrase — PBKDF2-HMAC-
/// SHA256 (600k rounds by default) → ChaChaPoly, the header (version,
/// kdf, rounds, salt, nonce) authenticated as associated data so no field
/// can be lowered or swapped. Same bytes on every platform.
public enum TeamIdentityExport {
    public struct File: Codable, Equatable, Sendable {
        public var v: Int
        public var kdf: String
        public var rounds: Int
        /// base64, 16 bytes
        public var salt: String
        /// base64, 12 bytes
        public var nonce: String
        /// base64, ciphertext ‖ tag (empty while the header is authenticated)
        public var box: String
    }

    public enum ExportError: Error, Equatable { case badSecret, badPassphrase, malformed }

    public static let defaultRounds = 600_000
    public static let kdf = "pbkdf2-hmac-sha256"
    static let minRounds = 1_000
    static let maxRounds = 10_000_000

    public static func export(secret: Data, passphrase: String, rounds: Int = defaultRounds) throws -> Data {
        guard secret.count == 32 else { throw ExportError.badSecret }
        guard (minRounds...maxRounds).contains(rounds) else { throw ExportError.malformed }
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let nonce = ChaChaPoly.Nonce()
        var file = File(v: 1, kdf: kdf, rounds: rounds, salt: salt.base64EncodedString(),
                        nonce: Data(nonce).base64EncodedString(), box: "")
        let key = SymmetricKey(data: PBKDF2.sha256(password: Data(passphrase.utf8), salt: salt, rounds: rounds, length: 32))
        let sealed = try ChaChaPoly.seal(secret, using: key, nonce: nonce, authenticating: try CanonicalJSON.encode(file))
        file.box = (sealed.ciphertext + sealed.tag).base64EncodedString()
        return try CanonicalJSON.encode(file)
    }

    public static func `import`(_ data: Data, passphrase: String) throws -> Data {
        guard var file = try? CanonicalJSON.decode(File.self, from: data), file.v == 1, file.kdf == kdf,
              (minRounds...maxRounds).contains(file.rounds),
              let salt = Data(base64Encoded: file.salt), salt.count == 16,
              let nonceData = Data(base64Encoded: file.nonce), nonceData.count == 12,
              let box = Data(base64Encoded: file.box), box.count == 32 + 16 else { throw ExportError.malformed }
        file.box = ""
        let key = SymmetricKey(data: PBKDF2.sha256(password: Data(passphrase.utf8), salt: salt, rounds: file.rounds, length: 32))
        let sealed = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonceData), ciphertext: box.prefix(32), tag: box.suffix(16))
        do {
            return try ChaChaPoly.open(sealed, using: key, authenticating: try CanonicalJSON.encode(file))
        } catch {
            throw ExportError.badPassphrase
        }
    }
}

extension TeamIdentityExport {
    public enum WriteError: Error, Equatable { case exists, failed(Int32) }

    /// The export file lands 0600 from its first byte and never replaces
    /// (or follows a symlink at) an existing path: `O_EXCL` on a fresh
    /// descriptor, not write-then-chmod.
    public static func write(_ data: Data, to url: URL) throws {
        #if os(Windows)
        // No O_CLOEXEC or POSIX modes on Windows (#203); Foundation's
        // `.withoutOverwriting` is the same never-replace guarantee.
        do { try data.write(to: url, options: .withoutOverwriting) }
        catch let error as CocoaError where error.code == .fileWriteFileExists { throw WriteError.exists }
        catch { throw WriteError.failed(-1) }
        #else
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw errno == EEXIST ? WriteError.exists : WriteError.failed(errno) }
        defer { close(fd) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        #endif
    }
}
