import Foundation

/// A document plus the kid that signed its canonical JSON. Rosters,
/// requests and team codes are all `Signed<…>` so anyone holding the
/// signer's public key can check them without decrypting anything.
public struct Signed<T: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var doc: T
    public var by: String
    /// base64 Ed25519 signature over `CanonicalJSON.encode(doc)`.
    public var sig: String

    public enum SignedError: Error, Equatable { case badSignature, wrongSigner }

    public init(doc: T, by: String, sig: String) {
        self.doc = doc; self.by = by; self.sig = sig
    }

    public static func make(_ doc: T, by identity: TeamIdentity) throws -> Signed<T> {
        let bytes = try CanonicalJSON.encode(doc)
        return Signed(doc: doc, by: identity.kid, sig: try identity.sign(bytes).base64EncodedString())
    }

    /// `keys` must be the signer's — the caller decides who is allowed
    /// to have signed (a leader for rosters, the requester for requests).
    public func verify(with keys: TeamKeys) throws {
        guard keys.kid == by else { throw SignedError.wrongSigner }
        // Garbled key bytes surface as `badSignature` too, not as a
        // `TeamKeys.KeyError` the caller never expects here (#55).
        guard let sigData = Data(base64Encoded: sig), let key = try? keys.signingKey(),
              key.isValidSignature(sigData, for: try CanonicalJSON.encode(doc))
        else { throw SignedError.badSignature }
    }
}
