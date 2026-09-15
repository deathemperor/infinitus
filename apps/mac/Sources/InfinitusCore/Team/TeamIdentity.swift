import Foundation
import Crypto

/// A member's public keys as they appear in rosters, requests and codes.
public struct TeamKeys: Codable, Equatable, Sendable {
    public var kid: String
    /// base64 raw X25519 public key.
    public var enc: String
    /// base64 raw Ed25519 public key.
    public var sig: String

    public init(kid: String, enc: String, sig: String) {
        self.kid = kid; self.enc = enc; self.sig = sig
    }

    private enum CodingKeys: String, CodingKey { case kid, enc, sig }

    /// Every set of keys that arrives from the store — a roster member, a
    /// join request, a team code — comes through here, so `kid` is always
    /// the one its own encryption key derives: nobody can wear another
    /// member's kid over their own keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kid = try c.decode(String.self, forKey: .kid)
        let enc = try c.decode(String.self, forKey: .enc)
        let sig = try c.decode(String.self, forKey: .sig)
        guard let encRaw = Data(base64Encoded: enc), let sigRaw = Data(base64Encoded: sig),
              Self.kid(forEncryptionKey: encRaw, signingKey: sigRaw) == kid else {
            throw KeyError.badKey
        }
        self.init(kid: kid, enc: enc, sig: sig)
    }

    public enum KeyError: Error { case badKey }

    public func encryptionKey() throws -> Curve25519.KeyAgreement.PublicKey {
        guard let raw = Data(base64Encoded: enc) else { throw KeyError.badKey }
        return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
    }

    public func signingKey() throws -> Curve25519.Signing.PublicKey {
        guard let raw = Data(base64Encoded: sig) else { throw KeyError.badKey }
        return try Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    /// `kid` = base32 of the first 16 bytes of SHA-256 over the raw X25519
    /// public key followed by the raw Ed25519 public key (spec §1): both
    /// keys are bound, so a request cannot pair a victim's encryption key
    /// with an attacker's signing key (#57, user 2026-09-05: "both").
    public static func kid(forEncryptionKey enc: Data, signingKey sig: Data) -> String {
        Base32.encode(Data(Crypto.SHA256.hash(data: enc + sig)).prefix(16))
    }
}

/// One installation's identity: a 32-byte secret (from a passkey PRF or
/// the OS credential store, spec §2.1) that derives an X25519 key for
/// envelopes and an Ed25519 key for signatures.
public struct TeamIdentity: Sendable {
    public let secret: Data
    public let encryption: Curve25519.KeyAgreement.PrivateKey
    public let signing: Curve25519.Signing.PrivateKey
    public let keys: TeamKeys
    public var kid: String { keys.kid }

    public enum IdentityError: Error { case badSecret }

    private static let salt = Data("infinitus-team-v1".utf8)

    public init(secret: Data) throws {
        guard secret.count == 32 else { throw IdentityError.badSecret }
        let ikm = SymmetricKey(data: secret)
        let encKey = HKDF<Crypto.SHA256>.deriveKey(inputKeyMaterial: ikm, salt: Self.salt,
                                                    info: Data("x25519".utf8), outputByteCount: 32)
        let sigKey = HKDF<Crypto.SHA256>.deriveKey(inputKeyMaterial: ikm, salt: Self.salt,
                                                    info: Data("ed25519".utf8), outputByteCount: 32)
        let encryption = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: encKey.withUnsafeBytes { Data($0) })
        let signing = try Curve25519.Signing.PrivateKey(
            rawRepresentation: sigKey.withUnsafeBytes { Data($0) })
        self.secret = secret
        self.encryption = encryption
        self.signing = signing
        let encRaw = encryption.publicKey.rawRepresentation
        let sigRaw = signing.publicKey.rawRepresentation
        self.keys = TeamKeys(kid: TeamKeys.kid(forEncryptionKey: encRaw, signingKey: sigRaw),
                             enc: encRaw.base64EncodedString(),
                             sig: signing.publicKey.rawRepresentation.base64EncodedString())
    }

    public static func random() -> TeamIdentity {
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        // 32 random bytes always satisfy `init`.
        return try! TeamIdentity(secret: secret)
    }

    public func sign(_ data: Data) throws -> Data {
        try signing.signature(for: data)
    }
}
