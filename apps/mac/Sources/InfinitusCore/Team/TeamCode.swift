import Foundation

/// The team code / invite payload (spec §6.2, §6.3): everything a joiner
/// needs, signed by the leader whose keys it carries, so the joiner
/// encrypts to the right leader whoever controls the remote. Travels as
/// `infinitus://join/<base64url JSON of Signed<TeamCode>>`.
public struct TeamCode: Codable, Equatable, Sendable {
    public var v: Int
    public var team: String
    public var name: String
    public var remote: String
    /// Store write credential; nil for remotes that need none (file://,
    /// SSH with the joiner's own key).
    public var token: String?
    public var leader: TeamKeys
    /// Unix seconds.
    public var expires: Int
    /// One-time invite nonce; nil for a team code.
    public var nonce: String?

    public static let prefix = "infinitus://join/"

    public enum CodeError: Error, Equatable { case malformed, expired, badSignature }

    public init(team: String, name: String, remote: String, token: String?, leader: TeamKeys,
                expires: Int, nonce: String? = nil) {
        self.v = 1
        self.team = team; self.name = name; self.remote = remote; self.token = token
        self.leader = leader; self.expires = expires; self.nonce = nonce
    }

    public func encoded(by leader: TeamIdentity) throws -> String {
        let json = try CanonicalJSON.encode(try Signed.make(self, by: leader))
        let b64 = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self.prefix + b64
    }

    public static func decode(_ text: String, now: Int = Int(Date().timeIntervalSince1970)) throws -> TeamCode {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix(prefix) { body = String(body.dropFirst(prefix.count)) }
        var b64 = body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let json = Data(base64Encoded: b64),
              let signed = try? CanonicalJSON.decode(Signed<TeamCode>.self, from: json),
              signed.doc.v == 1 else { throw CodeError.malformed }
        do { try signed.verify(with: signed.doc.leader) } catch { throw CodeError.badSignature }
        guard now < signed.doc.expires else { throw CodeError.expired }
        return signed.doc
    }
}
