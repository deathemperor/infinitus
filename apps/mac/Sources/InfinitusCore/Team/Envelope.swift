import Foundation
import Crypto

/// The team file format (spec §3): one canonical-JSON header line, `\n`,
/// then ChaCha20-Poly1305 ciphertext of the deflated plaintext. The file
/// key is fresh per envelope and wrapped once per recipient through an
/// ephemeral X25519 agreement; the header is the AEAD's associated data
/// and the sender's Ed25519 signature covers header-without-sig +
/// ciphertext, so a store that can't read anything also can't forge.
public enum Envelope {
    public struct Recipient: Codable, Equatable, Sendable {
        public var kid: String
        /// base64 ChaChaPoly `combined` box of the 32-byte file key.
        public var wrap: String
    }

    public struct Header: Codable, Equatable, Sendable {
        public var v: Int
        public var kind: String
        public var from: String
        /// base64 raw ephemeral X25519 public key.
        public var eph: String
        public var to: [Recipient]
        /// Unix seconds when sealed.
        public var at: Int
        /// base64 12-byte AEAD nonce.
        public var nonce: String
        /// base64 Ed25519 signature; nil only while being computed.
        public var sig: String?
    }

    public enum EnvelopeError: Error, Equatable {
        case malformed, notARecipient, badSignature, unknownSender, badVersion
    }

    public static let version = 1
    private static let newline = UInt8(ascii: "\n")

    // MARK: seal

    public static func seal(_ plaintext: Data, kind: String, from sender: TeamIdentity,
                            to recipients: [TeamKeys],
                            at: Int = Int(Date().timeIntervalSince1970)) throws -> Data {
        let fileKey = SymmetricKey(size: .bits256)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let nonce = ChaChaPoly.Nonce()
        let nonceData = Data(nonce)
        // The sender always reads its own files back.
        var everyone = recipients.filter { $0.kid != sender.kid }
        everyone.append(sender.keys)
        everyone.sort { $0.kid < $1.kid }
        let wrapped = try everyone.map { reader -> Recipient in
            let wrapKey = try wrapKey(private: ephemeral, public: reader.encryptionKey(),
                                      nonce: nonceData, sender: sender.kid, reader: reader.kid)
            let box = try ChaChaPoly.seal(fileKey.withUnsafeBytes { Data($0) }, using: wrapKey,
                                          nonce: ChaChaPoly.Nonce(data: Data(repeating: 0, count: 12)))
            return Recipient(kid: reader.kid, wrap: box.combined.base64EncodedString())
        }
        var header = Header(v: version, kind: kind, from: sender.kid,
                            eph: ephemeral.publicKey.rawRepresentation.base64EncodedString(),
                            to: wrapped, at: at, nonce: nonceData.base64EncodedString(), sig: nil)
        let unsigned = try CanonicalJSON.encode(header)
        let box = try ChaChaPoly.seal(try Deflate.compress(plaintext), using: fileKey,
                                      nonce: nonce, authenticating: unsigned)
        // `combined` = nonce ‖ ciphertext ‖ tag; the nonce is also in the
        // header, so only ciphertext ‖ tag goes to disk.
        let body = box.ciphertext + box.tag
        header.sig = try sender.sign(unsigned + body).base64EncodedString()
        return try CanonicalJSON.encode(header) + Data([newline]) + body
    }

    // MARK: read

    public static func header(of file: Data) throws -> Header {
        guard let split = file.firstIndex(of: newline) else { throw EnvelopeError.malformed }
        do {
            return try CanonicalJSON.decode(Header.self, from: file[file.startIndex..<split])
        } catch {
            throw EnvelopeError.malformed
        }
    }

    /// `senderKey` resolves the sender's kid to the roster's keys; nil
    /// means "not in the roster", which rejects the file before any
    /// decryption.
    public static func open(_ file: Data, as me: TeamIdentity,
                            senderKey: (String) -> TeamKeys?) throws -> (Header, Data) {
        let header = try header(of: file)
        guard header.v == version else { throw EnvelopeError.badVersion }
        guard let split = file.firstIndex(of: newline) else { throw EnvelopeError.malformed }
        let body = file[(split + 1)...]
        guard let sender = senderKey(header.from) else { throw EnvelopeError.unknownSender }
        guard let sigData = header.sig.flatMap({ Data(base64Encoded: $0) }) else { throw EnvelopeError.malformed }
        var unsignedHeader = header
        unsignedHeader.sig = nil
        let unsigned = try CanonicalJSON.encode(unsignedHeader)
        guard try sender.signingKey().isValidSignature(sigData, for: unsigned + body) else {
            throw EnvelopeError.badSignature
        }
        guard let mine = header.to.first(where: { $0.kid == me.kid }),
              let wrap = Data(base64Encoded: mine.wrap) else { throw EnvelopeError.notARecipient }
        guard let ephRaw = Data(base64Encoded: header.eph),
              let nonceData = Data(base64Encoded: header.nonce), nonceData.count == 12,
              body.count >= 16 else { throw EnvelopeError.malformed }
        let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephRaw)
        let wrapKey = try wrapKey(private: me.encryption, public: ephemeral,
                                  nonce: nonceData, sender: header.from, reader: me.kid)
        let fileKeyData = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: wrap), using: wrapKey)
        let fileKey = SymmetricKey(data: fileKeyData)
        let ciphertext = body.prefix(body.count - 16)
        let tag = body.suffix(16)
        let box = try ChaChaPoly.SealedBox(combined: nonceData + ciphertext + tag)
        let packed = try ChaChaPoly.open(box, using: fileKey, authenticating: unsigned)
        return (header, try Deflate.decompress(packed))
    }

    // MARK: key wrap

    /// X25519 agreement between the envelope's ephemeral key and one
    /// reader, stretched with the envelope nonce and both kids so every
    /// (envelope, reader) pair has its own wrap key — which is why the
    /// wrap box can use a fixed zero nonce.
    private static func wrapKey(private priv: Curve25519.KeyAgreement.PrivateKey,
                                public pub: Curve25519.KeyAgreement.PublicKey,
                                nonce: Data, sender: String, reader: String) throws -> SymmetricKey {
        let shared = try priv.sharedSecretFromKeyAgreement(with: pub)
        return shared.hkdfDerivedSymmetricKey(using: Crypto.SHA256.self, salt: nonce,
                                              sharedInfo: Data("infinitus-wrap-v1|\(sender)|\(reader)".utf8),
                                              outputByteCount: 32)
    }
}
